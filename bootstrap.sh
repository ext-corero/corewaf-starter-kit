#!/usr/bin/env bash
# CoreWAF Starter Kit — curl-pipe bootstrap.
#
# Verifies prereqs, fetches (or refreshes) the kit, hands off to
# scripts/install.sh.
#
# Usage (process substitution — env stays left of bash, no pipe):
#   TOKEN=v1.eyJ... bash <(curl -fsSL <bootstrap-url>)
#
# Why not `TOKEN=… curl … | bash`? Shell semantics: env-prefix on a
# pipeline applies only to the FIRST command (curl), not to bash on
# the right side of the pipe. Process substitution makes `TOKEN=…`
# apply to bash directly, so install.sh actually sees TOKEN.
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

step() { printf '\n── %s ──\n' "$*"; }
note() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

step "CoreWAF Starter Kit — bootstrap"

# ── prereqs ───────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || fail "git is required"
command -v docker >/dev/null 2>&1 || fail "docker is required"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin (v2) is required"

# ── fetch the kit ─────────────────────────────────────────────────────
if [ -d "${TARGET_DIR}/.git" ]; then
    note "Refreshing existing clone at ${TARGET_DIR} (ref=${REPO_REF})"
    cd "${TARGET_DIR}"
    git fetch --quiet origin "${REPO_REF}"
    git checkout --quiet "${REPO_REF}"
    git pull --quiet --ff-only origin "${REPO_REF}"
    cd - >/dev/null
elif [ -e "${TARGET_DIR}" ]; then
    fail "${TARGET_DIR} exists but isn't a git checkout. Move it aside or set COREWAF_DIR."
else
    note "Cloning ${REPO_URL} → ${TARGET_DIR} (ref=${REPO_REF})"
    git clone --quiet --branch "${REPO_REF}" --single-branch "${REPO_URL}" "${TARGET_DIR}"
fi

# ── hand off to the installer ─────────────────────────────────────────
cd "${TARGET_DIR}"

INSTALL_ARGS=()
[ "${NO_UP:-0}" = "1" ] && INSTALL_ARGS+=("--no-up")

exec ./scripts/install.sh "${INSTALL_ARGS[@]}"
