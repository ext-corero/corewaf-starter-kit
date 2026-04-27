#!/usr/bin/env bash
# CoreWAF Starter Kit — curl-pipe bootstrap.
#
# Pipe-to-bash entry point. Verifies the host is ready, fetches the kit
# (or refreshes a clone), tries to surface a `gum`-styled UI for the rest
# of the install, then hands off to scripts/install.sh.
#
# Usage (process substitution — env stays left of bash, no pipe):
#   TOKEN=v1.eyJ... bash <(curl -fsSL <bootstrap-url>)
#
# Why not `TOKEN=… curl … | bash`? Shell semantics: env-prefix on a
# pipeline applies only to the FIRST command (curl), not to bash on the
# right side of the pipe. Process substitution makes `TOKEN=…` apply to
# bash directly, so install.sh actually sees TOKEN.
#
# Required:
#   TOKEN              Provisioning token issued by the operator.
#                      Alias: COREWAF_TOKEN. Either works.
#
# Optional environment overrides:
#   COREWAF_REPO       Git URL of the kit (default: github.com/ext-corero/corewaf-starter-kit)
#   COREWAF_REF        Branch/tag (default: main)
#   COREWAF_DIR        Where to clone (default: ./corewaf-starter-kit)
#   INSTANCE_COMMENT   Free-form instance label (alias: COREWAF_INSTANCE_COMMENT)
#   NO_UP=1            Don't run `docker compose up` after writing config.ini

set -euo pipefail

REPO_URL="${COREWAF_REPO:-https://github.com/ext-corero/corewaf-starter-kit.git}"
REPO_REF="${COREWAF_REF:-main}"
TARGET_DIR="${COREWAF_DIR:-corewaf-starter-kit}"

# ---------------------------------------------------------------------------
# Best-effort UI: prefer gum if installed; fall back to plain echo otherwise.
# install.sh uses the same convention, so the experience stays consistent.
# ---------------------------------------------------------------------------
HAS_GUM=0
if command -v gum >/dev/null 2>&1; then
    HAS_GUM=1
fi

banner() {
    if [ "${HAS_GUM}" = "1" ]; then
        gum style --bold --foreground 212 --border rounded --padding "0 1" --margin "1 0" "$1"
    else
        printf '\n=== %s ===\n' "$1"
    fi
}

note() {
    if [ "${HAS_GUM}" = "1" ]; then
        gum style --foreground 245 "$1"
    else
        printf '%s\n' "$1"
    fi
}

run_step() {
    # $1: title    $2..: command
    local title="$1"; shift
    if [ "${HAS_GUM}" = "1" ]; then
        gum spin --spinner dot --title "${title}" --show-output -- "$@"
    else
        printf '… %s\n' "${title}"
        "$@"
    fi
}

fail() {
    if [ "${HAS_GUM}" = "1" ]; then
        gum style --foreground 196 --bold "$1" >&2
    else
        printf 'ERROR: %s\n' "$1" >&2
    fi
    exit 1
}

# ---------------------------------------------------------------------------
# Welcome
# ---------------------------------------------------------------------------
banner "CoreWAF Starter Kit"
note "Bootstrap: clone the kit and walk through the installer."

if [ "${HAS_GUM}" = "0" ]; then
    note ""
    note "(Tip: install 'gum' for a friendlier UI — https://github.com/charmbracelet/gum)"
    note ""
fi

# ---------------------------------------------------------------------------
# Prereqs
# ---------------------------------------------------------------------------
command -v git >/dev/null 2>&1 || fail "git is required"
command -v docker >/dev/null 2>&1 || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin (v2) is required"

# ---------------------------------------------------------------------------
# Fetch the kit
# ---------------------------------------------------------------------------
if [ -d "${TARGET_DIR}/.git" ]; then
    note "Refreshing existing clone at ${TARGET_DIR}"
    run_step "git fetch + checkout ${REPO_REF}" \
        bash -c "cd '${TARGET_DIR}' && git fetch --quiet origin '${REPO_REF}' && git checkout --quiet '${REPO_REF}' && git pull --quiet --ff-only origin '${REPO_REF}'"
elif [ -e "${TARGET_DIR}" ]; then
    fail "${TARGET_DIR} exists but isn't a git checkout. Move it aside or set COREWAF_DIR."
else
    run_step "Cloning ${REPO_URL} → ${TARGET_DIR}" \
        git clone --quiet --branch "${REPO_REF}" --single-branch "${REPO_URL}" "${TARGET_DIR}"
fi

# ---------------------------------------------------------------------------
# Hand off to the installer
# ---------------------------------------------------------------------------
banner "Running installer"
cd "${TARGET_DIR}"

INSTALL_ARGS=()
[ "${NO_UP:-0}" = "1" ] && INSTALL_ARGS+=("--no-up")

exec ./scripts/install.sh "${INSTALL_ARGS[@]}"
