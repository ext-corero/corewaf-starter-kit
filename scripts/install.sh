#!/usr/bin/env bash
# CoreWAF Starter Kit — interactive installer.
#
# v0 (feature/tunnel-v0): the kit is token-driven. The customer pastes
# a single self-locating provisioning_token (issued by the operator via
# the GUI / API) and the rest — api gateway URL, observability
# endpoints, zero-trust API key, WG tunnel config — arrives on first
# boot via the redemption response. No more entering URLs by hand.
#
# Uses `gum` for the TUI when available; falls back to plain `read` so
# the script works on any POSIX host.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve repo root regardless of where the script is invoked from.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_INI="${REPO_ROOT}/config.ini"
EXAMPLE_INI="${REPO_ROOT}/config.ini.example"

DO_UP=1
for arg in "$@"; do
    case "$arg" in
        --no-up) DO_UP=0 ;;
        -h|--help)
            cat <<EOF
Usage: ./scripts/install.sh [--no-up]

Interactive installer. Writes config.ini in the repo root from your
answers, then runs 'docker compose up -d' (skip with --no-up).
EOF
            exit 0
            ;;
    esac
done

# ---------------------------------------------------------------------------
# UI helpers — gum if present, plain read otherwise.
#
# If gum isn't on PATH we try to grab a static binary from charmbracelet's
# GitHub release tarball into ${REPO_ROOT}/.bin/gum (gitignored). The
# customer's host stays untouched; .bin lives with the kit checkout.
# Cached across runs.
# ---------------------------------------------------------------------------

ensure_gum() {
    # Already on PATH? Nothing to do.
    if command -v gum >/dev/null 2>&1; then
        return 0
    fi
    # Already cached locally from a prior run?
    if [ -x "${REPO_ROOT}/.bin/gum" ]; then
        export PATH="${REPO_ROOT}/.bin:${PATH}"
        return 0
    fi

    local version="0.16.0"
    local os arch
    os=$(uname -s)
    arch=$(uname -m)
    case "${arch}" in
        x86_64|amd64)  arch=x86_64 ;;
        arm64|aarch64) arch=arm64  ;;
        *)
            printf '(gum auto-install: unsupported arch %s — falling back to plain prompts)\n' "${arch}" >&2
            return 0
            ;;
    esac
    case "${os}" in
        Linux|Darwin) ;;
        *)
            printf '(gum auto-install: unsupported OS %s — falling back to plain prompts)\n' "${os}" >&2
            return 0
            ;;
    esac

    local tarball="gum_${version}_${os}_${arch}.tar.gz"
    local url="https://github.com/charmbracelet/gum/releases/download/v${version}/${tarball}"
    local tmp; tmp=$(mktemp -d)

    printf 'Fetching gum %s for %s/%s ...\n' "${version}" "${os}" "${arch}" >&2
    if ! curl -fsSL "${url}" -o "${tmp}/${tarball}"; then
        printf '(gum auto-install: download failed — falling back to plain prompts)\n' >&2
        rm -rf "${tmp}"
        return 0
    fi
    if ! tar -xzf "${tmp}/${tarball}" -C "${tmp}"; then
        printf '(gum auto-install: extract failed — falling back to plain prompts)\n' >&2
        rm -rf "${tmp}"
        return 0
    fi

    mkdir -p "${REPO_ROOT}/.bin"
    # Tarball layout: gum_VER_OS_ARCH/gum (plus README, LICENSE, etc.)
    local extracted="${tmp}/gum_${version}_${os}_${arch}/gum"
    if [ ! -x "${extracted}" ]; then
        printf '(gum auto-install: binary not found in tarball — falling back to plain prompts)\n' >&2
        rm -rf "${tmp}"
        return 0
    fi
    mv "${extracted}" "${REPO_ROOT}/.bin/gum"
    rm -rf "${tmp}"

    export PATH="${REPO_ROOT}/.bin:${PATH}"
}

ensure_gum

HAS_GUM=0
if command -v gum >/dev/null 2>&1; then
    HAS_GUM=1
fi

ui_header() {
    if [ "${HAS_GUM}" = "1" ]; then
        gum style --bold --foreground 212 --margin "1 0" "$1"
    else
        printf '\n=== %s ===\n' "$1"
    fi
}

ui_note() {
    if [ "${HAS_GUM}" = "1" ]; then
        gum style --foreground 245 "$1"
    else
        printf '%s\n' "$1"
    fi
}

ui_input() {
    # $1: prompt   $2: placeholder (optional)
    local prompt="$1"
    local placeholder="${2:-}"
    if [ "${HAS_GUM}" = "1" ]; then
        gum input --prompt "${prompt}> " --placeholder "${placeholder}"
    else
        local answer
        printf '%s ' "${prompt}>" >&2
        IFS= read -r answer
        printf '%s' "${answer}"
    fi
}

ui_confirm() {
    # $1: question. exits 0 (yes) or 1 (no).
    if [ "${HAS_GUM}" = "1" ]; then
        gum confirm "$1"
    else
        local answer
        printf '%s [y/N] ' "$1" >&2
        IFS= read -r answer
        case "${answer}" in
            y|Y|yes|YES) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

ui_run() {
    # $1: spinner title   $2..: command to run
    local title="$1"; shift
    if [ "${HAS_GUM}" = "1" ]; then
        gum spin --spinner dot --title "${title}" --show-output -- "$@"
    else
        printf '… %s\n' "${title}" >&2
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
ui_header "CoreWAF Starter Kit — Installer"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is required but not on PATH" >&2
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: 'docker compose' plugin is required (compose v2)" >&2
    exit 1
fi

if [ "${HAS_GUM}" = "0" ]; then
    ui_note "(gum not installed — using plain prompts. Install gum for a nicer experience: https://github.com/charmbracelet/gum)"
fi

if [ -f "${CONFIG_INI}" ]; then
    if ! ui_confirm "config.ini already exists — overwrite?"; then
        echo "Keeping existing config.ini. Re-run with --no-up if you only want the prompts." >&2
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Token + comment — env-first, prompt fallback (interactive only)
# ---------------------------------------------------------------------------
ui_header "Tell us about this instance"

# Convention: TOKEN= is the customer-facing env var name ("TOKEN=…
# curl … | bash"). COREWAF_TOKEN is kept as an alias so older docs /
# scripts keep working. Same pattern for INSTANCE_COMMENT.
PROVISIONING_TOKEN="${TOKEN:-${COREWAF_TOKEN:-}}"
INSTANCE_COMMENT="${INSTANCE_COMMENT:-${COREWAF_INSTANCE_COMMENT:-}}"

# When the script is run via `curl … | bash`, stdin is the (now-empty)
# bootstrap pipe — `read` would silently EOF and we'd write a blank
# token. Detect non-interactive stdin and fail loudly instead.
if [ -z "${PROVISIONING_TOKEN}" ] && [ ! -t 0 ]; then
    cat <<EOF >&2
ERROR: TOKEN is empty.

  When running via curl, use process substitution so TOKEN reaches bash:

    TOKEN=v1.eyJ... bash <(curl -fsSL <bootstrap-url>)

  (NOT \`TOKEN=… curl … | bash\` — env-prefix on a pipeline applies only
   to curl, not to bash on the right side of the pipe.)

  Or run the installer locally and answer the prompt:

    bash scripts/install.sh
EOF
    exit 1
fi

while [ -z "${PROVISIONING_TOKEN}" ]; do
    PROVISIONING_TOKEN=$(ui_input \
        "Provisioning token (issued by the operator)" \
        "v1.eyJ...")
    case "${PROVISIONING_TOKEN}" in
        "") ui_note "Provisioning token is required." ;;
        v1.*.*) ;;     # well-formed envelope shape
        *)
            ui_note "Token must look like v1.<payload>.<signature>"
            PROVISIONING_TOKEN=""
            ;;
    esac
done

# Validate token shape even when supplied via env (prevents a silently
# garbage token from making it to the redemption call).
case "${PROVISIONING_TOKEN}" in
    v1.*.*) ;;
    *)
        echo "ERROR: TOKEN doesn't look like a v1 envelope (v1.<payload>.<sig>)" >&2
        exit 1
        ;;
esac

[ -z "${INSTANCE_COMMENT}" ] && [ -t 0 ] && \
    INSTANCE_COMMENT=$(ui_input "Instance comment (optional, free-form)" "rack 4, slot 7")

# ---------------------------------------------------------------------------
# Write config.ini
# ---------------------------------------------------------------------------
ui_header "Writing config.ini"

cat > "${CONFIG_INI}" <<EOF
# Generated by scripts/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Re-run the installer to regenerate, or edit by hand.

provisioning_token=${PROVISIONING_TOKEN}
instance_comment=${INSTANCE_COMMENT}

# v0 transitional placeholders — the instance-init image still
# validates these as non-empty. Real values arrive in the redemption
# response and the tunnel-client writes them into runtime/.env after
# init completes. Drop these once instance-init is updated to v0.
org_scope_id=pending-redemption
observability_base_url=pending.redemption.local
api_gateway_url=http://pending.redemption.local
EOF

ui_note "Wrote ${CONFIG_INI}"

# ---------------------------------------------------------------------------
# Bring up the stack
# ---------------------------------------------------------------------------
if [ "${DO_UP}" = "0" ]; then
    ui_note "Skipping 'docker compose up' (--no-up). When ready: cd '${REPO_ROOT}' && docker compose up -d"
    exit 0
fi

ui_header "Bringing up the stack"
cd "${REPO_ROOT}"

# Compose evaluates env_file at container CREATE time, not start time, so
# we run init explicitly first (rendering runtime/.env with the legacy
# baseline values from config.ini). The tunnel container then redeems
# the provisioning token on its first start and overwrites runtime/.env
# with the real api gateway URL, zero-trust API key, etc., before
# caddy-bridge is created (gated by depends_on: tunnel: service_healthy).
mkdir -p runtime
[ -f runtime/.env ] || : > runtime/.env

ui_run "Stage 1: init (privileged — discovery + template render)" \
    docker compose run --rm init

ui_run "Stage 2: tunnel (redeem token + bring up wg100)" \
    docker compose up -d --no-deps tunnel

ui_run "Stage 3: caddy + bridge + alloy + valkey" \
    docker compose up -d caddy caddy-bridge alloy valkey

ui_note ""
ui_note "Stack is up. Tail logs with:"
ui_note "  docker compose logs -f tunnel        # WG bring-up + redemption"
ui_note "  docker compose logs -f caddy-bridge  # bridge registration"
ui_note ""
ui_note "Caddy waits for the CoreWAF backend to provision it before serving traffic;"
ui_note "telemetry starts flowing immediately via Alloy."
