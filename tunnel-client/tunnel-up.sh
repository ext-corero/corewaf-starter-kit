#!/usr/bin/env bash
# tunnel-client — bring up the WG tunnel to the CoreWAF backend.
#
# Lifecycle:
#   First boot:
#     1. read provisioning_token from /workspace/config.ini
#     2. decode token envelope to find the gateway URL (self-locating)
#     3. generate a WG keypair, persist private.key in tunnel-state volume
#     4. POST /api/v1/provisioning/redeem  { token, tunnelPubkey }
#     5. parse response → write /etc/wireguard/wg0.conf
#     6. merge zeroTrustApiKey/apiEndpoint/etc. into /workspace/runtime/.env
#     7. wg-quick up wg0
#     8. write /var/lib/tunnel/state.json so future restarts skip 1–7
#
#   Restart (state.json present):
#     - reload wg0.conf, wg-quick up wg0, idle.
#
# After bring-up the script enters a wait loop so the container stays
# alive (k8s/compose semantics). The healthcheck script verifies wg0 is
# up; depends_on: tunnel: { condition: service_healthy } in the kit's
# compose blocks caddy-bridge until the tunnel is established.

set -euo pipefail

CONFIG_INI="${CONFIG_INI:-/workspace/config.ini}"
RUNTIME_ENV="${RUNTIME_ENV:-/workspace/runtime/.env}"
TUNNEL_STATE_DIR="${TUNNEL_STATE_DIR:-/var/lib/tunnel}"
# Interface defaults to `wg100` — chosen specifically so the kit can run
# alongside the rig's wg-server (which owns `wg0` in the host netns) on
# the same machine for end-to-end testing. Override for production.
WG_INTERFACE="${WG_INTERFACE:-wg100}"
WG_CONF="${WG_CONF:-/etc/wireguard/${WG_INTERFACE}.conf}"

mkdir -p "$TUNNEL_STATE_DIR" "$(dirname "$WG_CONF")"
chmod 700 "$TUNNEL_STATE_DIR"

log()  { printf '%s tunnel-client %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
fail() { log "FATAL: $*"; exit 1; }

# ── INI helpers ───────────────────────────────────────────────────────
# Bash-native to avoid awk's $1-mutation gotcha: when you trim $1 with
# `sub`, awk rebuilds $0 using OFS (space) instead of the original FS,
# which then makes `sub(/^[^=]*=/, "")` no-op because there's no `=`
# left in the rebuilt $0.
ini_get() {
    local key="$1" k v
    while IFS='=' read -r k v; do
        # Trim leading/trailing whitespace from k. v is taken verbatim
        # (read -r preserves backslashes; remainder-after-first-= goes
        # into v even if the value contains more `=` signs).
        k="${k#"${k%%[![:space:]]*}"}"
        k="${k%"${k##*[![:space:]]}"}"
        case "$k" in
            \#*|"") continue ;;
            "$key") printf '%s' "$v"; return 0 ;;
        esac
    done < "$CONFIG_INI"
    return 1
}

# Self-locating envelope: v1.<base64url(payload_json)>.<base64url(sig)>.
# Decode the payload segment — signature is verified server-side; the
# client only consumes the URL and namespace fields.
decode_envelope_field() {
    local token="$1" field="$2"
    local payload_b64
    payload_b64=$(printf '%s' "$token" | awk -F. '{print $2}')
    [ -n "$payload_b64" ] || fail "token has no payload segment"

    # base64url → base64 (replace -/_, restore padding)
    local b64
    b64=$(printf '%s' "$payload_b64" | tr '_-' '/+')
    case $(( ${#b64} % 4 )) in
        2) b64="${b64}==" ;;
        3) b64="${b64}=" ;;
    esac
    printf '%s' "$b64" | base64 -d | jq -r ".${field}"
}

# ── enrollment ────────────────────────────────────────────────────────
enroll_and_render() {
    local token="$1"
    local gw_url namespace
    gw_url=$(decode_envelope_field "$token" gw)
    namespace=$(decode_envelope_field "$token" ns)
    [ -n "$gw_url" ] && [ "$gw_url" != "null" ] || fail "no gateway URL in token"
    [ -n "$namespace" ] && [ "$namespace" != "null" ] || fail "no namespace in token"

    log "decoded gateway URL: $gw_url (namespace=$namespace)"

    # Keypair — generate once, persist across restarts. The tunnel-state
    # volume in compose ensures the same kit reuses the same key after
    # `docker compose down/up`. Re-creating the volume forces a new key,
    # which forces a fresh redemption.
    if [ ! -f "$TUNNEL_STATE_DIR/private.key" ]; then
        log "generating WG keypair"
        umask 077
        wg genkey | tee "$TUNNEL_STATE_DIR/private.key" \
                  | wg pubkey > "$TUNNEL_STATE_DIR/public.key"
    fi
    local privkey pubkey
    privkey=$(cat "$TUNNEL_STATE_DIR/private.key")
    pubkey=$(cat "$TUNNEL_STATE_DIR/public.key")

    # Redeem — single call, returns everything we need: server pubkey,
    # endpoint, our allocated client IP + hostname, plus the bridge
    # auth credentials (zeroTrustApiKey, apiEndpoint, etc.).
    log "POSTing redemption to $gw_url/api/v1/provisioning/redeem"
    local req_body resp http_status
    req_body=$(jq -nc --arg t "$token" --arg pk "$pubkey" \
        '{token: $t, tunnelPubkey: $pk}')

    resp=$(mktemp)
    http_status=$(curl -sS -o "$resp" -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -X POST -d "$req_body" \
        "$gw_url/api/v1/provisioning/redeem" || echo "000")

    if [ "$http_status" != "200" ]; then
        log "redemption failed (HTTP $http_status):"
        cat "$resp" >&2 || true
        rm -f "$resp"
        fail "could not redeem provisioning token"
    fi

    # Pull the fields we need.
    local server_pubkey server_endpoint client_ip client_host allowed_ips keepalive
    server_pubkey=$(jq -r .tunnelConfig.serverPubkey "$resp")
    server_endpoint=$(jq -r .tunnelConfig.serverEndpoint "$resp")
    client_ip=$(jq -r .tunnelConfig.clientIP "$resp")
    client_host=$(jq -r .tunnelConfig.clientHostname "$resp")
    allowed_ips=$(jq -r .tunnelConfig.allowedIPs "$resp")
    keepalive=$(jq -r '.tunnelConfig.persistentKeepalive // 25' "$resp")

    # Override knob — useful for single-host loopback testing where the
    # kit and rig wg-server share the host netns. The default
    # (full tunnel CIDR /16) collides with the rig's wg0 route; setting
    # TUNNEL_ALLOWED_IPS to "100.64.0.1/32" makes the kit route only
    # server-bound traffic via wg100. Production: leave unset.
    if [ -n "${TUNNEL_ALLOWED_IPS:-}" ]; then
        log "TUNNEL_ALLOWED_IPS override: '$allowed_ips' -> '$TUNNEL_ALLOWED_IPS'"
        allowed_ips="$TUNNEL_ALLOWED_IPS"
    fi

    [ "$server_pubkey" != "null" ] || fail "redemption response had no tunnelConfig.serverPubkey"

    # Write the WG config.
    log "writing $WG_CONF (interface=$WG_INTERFACE, clientIP=$client_ip, hostname=$client_host)"
    umask 077
    cat > "$WG_CONF" <<EOF
# Auto-generated by tunnel-client on first boot. Do not edit.
[Interface]
PrivateKey = $privkey
Address    = $client_ip

[Peer]
PublicKey           = $server_pubkey
Endpoint            = $server_endpoint
AllowedIPs          = $allowed_ips
PersistentKeepalive = $keepalive
EOF

    # Merge bridge-relevant fields into runtime/.env. The bridge reads
    # this at start-up. We APPEND new keys; if the kit's instance-init
    # already wrote conflicting values, ours win because env_file later
    # entries in compose override earlier ones — but to be safe, replace
    # in place.
    local api_endpoint zt_secret zt_id issuing_carrier
    api_endpoint=$(jq -r '.apiEndpoint // empty' "$resp")
    zt_secret=$(jq -r '.zeroTrustApiKey // empty' "$resp")
    zt_id=$(jq -r '.zeroTrustKeyId // empty' "$resp")
    issuing_carrier=$(jq -r '.issuingCarrier // empty' "$resp")

    mkdir -p "$(dirname "$RUNTIME_ENV")"
    touch "$RUNTIME_ENV"
    _replace_env_var() {
        local key="$1" val="$2" file="$RUNTIME_ENV"
        [ -n "$val" ] || return 0
        if grep -q "^${key}=" "$file" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$file"
        else
            printf '%s=%s\n' "$key" "$val" >> "$file"
        fi
    }
    _replace_env_var API_GATEWAY_URL "$api_endpoint"
    _replace_env_var BRIDGE_SCOPE_ORGID "$issuing_carrier"
    _replace_env_var NAMESPACE "$namespace"
    _replace_env_var TUNNEL_HOSTNAME "$client_host"
    _replace_env_var TUNNEL_CLIENT_IP "${client_ip%/*}"
    _replace_env_var BRIDGE_EXTERNAL_URL "http://${client_host}:8090"
    _replace_env_var ZERO_TRUST_KEY_ID "$zt_id"
    _replace_env_var ZERO_TRUST_API_KEY "$zt_secret"

    # Persist redemption state so restarts skip the API call.
    cp "$resp" "$TUNNEL_STATE_DIR/state.json"
    chmod 600 "$TUNNEL_STATE_DIR/state.json"
    rm -f "$resp"
}

# ── tunnel up ─────────────────────────────────────────────────────────
bring_tunnel_up() {
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        log "$WG_INTERFACE already up — bouncing"
        wg-quick down "$WG_INTERFACE" || true
    fi
    log "bringing up $WG_INTERFACE"
    wg-quick up "$WG_INTERFACE"
    log "tunnel up: $(wg show "$WG_INTERFACE" | head -2 | tail -1)"
}

# ── main ──────────────────────────────────────────────────────────────
main() {
    [ -f "$CONFIG_INI" ] || fail "$CONFIG_INI not found — has stage 1 init run?"

    if [ -f "$TUNNEL_STATE_DIR/state.json" ] && [ -f "$WG_CONF" ]; then
        log "state.json present — skipping enrollment, reusing existing config"
    else
        local token
        token=$(ini_get "provisioning_token")
        [ -n "$token" ] || fail "provisioning_token not set in $CONFIG_INI"
        enroll_and_render "$token"
    fi

    bring_tunnel_up

    log "ready — entering wait loop (signal-driven shutdown via tini)"
    # Block forever. Shutdown happens via SIGTERM → tini → wait returns.
    while true; do sleep 86400; done
}

main "$@"
