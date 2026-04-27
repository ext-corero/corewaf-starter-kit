#!/usr/bin/env bash
# Healthcheck for the tunnel-client container.
#
# wg0 must exist AND have at least one peer with a recent handshake.
# The "recent" cutoff is generous (3 minutes) so transient packet loss
# doesn't flap the container; WG persistent-keepalive defaults to 25s.

set -euo pipefail

WG_INTERFACE="${WG_INTERFACE:-wg0}"
HANDSHAKE_MAX_AGE="${HANDSHAKE_MAX_AGE:-180}"

ip link show "$WG_INTERFACE" >/dev/null 2>&1 || { echo "no $WG_INTERFACE"; exit 1; }

# `wg show <iface> latest-handshakes` prints "<pubkey>\t<unix-ts>" per peer.
# Pick the most recent handshake; if it's older than HANDSHAKE_MAX_AGE
# seconds (or zero, meaning never), report unhealthy.
latest=$(wg show "$WG_INTERFACE" latest-handshakes | awk '{print $2}' | sort -nr | head -1)
[ -n "${latest:-}" ] && [ "$latest" != "0" ] || {
    # First boot — peer is configured but no handshake yet. We're starting
    # up; kernel will exchange shortly. Report healthy if the interface
    # is up and the peer is at least configured.
    wg show "$WG_INTERFACE" peers | head -1 >/dev/null 2>&1 || { echo "no peer"; exit 1; }
    # Allow ~30 s for the first handshake before flagging unhealthy.
    [ -f /var/lib/tunnel/started_at ] || { date +%s > /var/lib/tunnel/started_at; }
    started=$(cat /var/lib/tunnel/started_at)
    age=$(( $(date +%s) - started ))
    [ "$age" -lt 30 ] && { echo "warming up ($age s)"; exit 0; }
    echo "no handshake within 30s of boot"; exit 1
}

now=$(date +%s)
age=$(( now - latest ))
if [ "$age" -gt "$HANDSHAKE_MAX_AGE" ]; then
    echo "stale handshake: ${age}s old"
    exit 1
fi

echo "ok (handshake ${age}s ago)"
exit 0
