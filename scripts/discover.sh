#!/bin/sh
# Stage 1 entrypoint — runs inside the orchestrator container as a privileged
# one-shot. Three jobs:
#
#   1. Sanity-check the host for required prerequisites (git, docker socket).
#   2. Capture the full discovery snapshot for the bridge (discovery.json).
#   3. Compose the bootstrap file the templates stage will consume —
#      customer's config.ini concatenated with discovery-derived host facts.
#
# Failures in (1) halt the boot sequence loudly. (2) and (3) are then
# guaranteed to produce well-formed inputs for the rest of the stack.
#
# The orchestrator binary is the entrypoint of this image; this script is
# launched via `entrypoint: ["/bin/sh", "-c", "..."]` in compose.yml. We
# call the binary by its absolute path so the entrypoint override doesn't
# matter.

set -eu

ORCH=/usr/local/bin/orchestrator
HWINFO_DIR=/var/lib/hwinfo
WORKSPACE=/workspace
CONFIG_INI=${WORKSPACE}/config.ini
BOOTSTRAP_OUT=${HWINFO_DIR}/bootstrap
DISCOVERY_OUT=${HWINFO_DIR}/discovery.json

mkdir -p "${HWINFO_DIR}"

log() { echo "[discover] $*" >&2; }
fail() { echo "[discover] FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Sanity check
# ---------------------------------------------------------------------------

[ -f "${CONFIG_INI}" ] || fail "config.ini not found at ${CONFIG_INI} — copy config.ini.example and fill it in"

# Customer must set org_scope_id. Required field.
if ! grep -E "^org_scope_id=.+" "${CONFIG_INI}" >/dev/null 2>&1; then
    fail "org_scope_id is empty in config.ini — set it before bringing the stack up"
fi

# Docker socket must be reachable (otherwise the rest of the stack can't run).
[ -S /var/run/docker.sock ] || fail "/var/run/docker.sock is not mounted into this container"

# Eventually: git presence on the host (today: customer must already have
# git to have cloned this repo, so this is informational).

# ---------------------------------------------------------------------------
# 2. Full discovery snapshot
# ---------------------------------------------------------------------------

log "writing ${DISCOVERY_OUT}"
"${ORCH}" discover > "${DISCOVERY_OUT}"

# ---------------------------------------------------------------------------
# 3. Compose bootstrap = config.ini + discovery facts
# ---------------------------------------------------------------------------

log "writing ${BOOTSTRAP_OUT}"
{
    # Customer-supplied first; discovery values follow and win on key collision.
    cat "${CONFIG_INI}"
    echo
    echo "# --- Auto-populated by discover stage ---"
    echo "machine_id=$("${ORCH}" discover machine-id)"
    echo "hardware_fingerprint=$("${ORCH}" discover hardware-fingerprint)"
    echo "hostname=$("${ORCH}" discover hostname)"
    echo "instance_name=$("${ORCH}" discover instance-name)"
} > "${BOOTSTRAP_OUT}"

log "discovery complete"
