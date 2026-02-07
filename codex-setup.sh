#!/usr/bin/env bash
set -euo pipefail

# Installs runtime dependencies required by the ARMv7 Codex binaries on Debian.
# Usage:
#   ./codex-setup.sh [path-to-codex] [path-to-codex-linux-sandbox]
#
# Defaults:
#   codex binary: ./codex
#   sandbox binary: ./codex-linux-sandbox

CODEX_BIN="${1:-./codex}"
SANDBOX_BIN="${2:-./codex-linux-sandbox}"

log() {
  printf '[codex-setup] %s\n' "$*"
}

warn() {
  printf '[codex-setup] WARN: %s\n' "$*" >&2
}

die() {
  printf '[codex-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

if ! command -v apt-get >/dev/null 2>&1; then
  die "apt-get not found. This script is intended for Debian/Ubuntu systems."
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    die "run as root or install sudo."
  fi
  SUDO="sudo"
fi

LIBGCC_PKG="libgcc-s1"
if ! apt-cache show "${LIBGCC_PKG}" >/dev/null 2>&1; then
  LIBGCC_PKG="libgcc1"
fi

PKGS=(
  libc6
  "${LIBGCC_PKG}"
  ca-certificates
)

log "Installing runtime packages: ${PKGS[*]}"
"${SUDO}" apt-get update
"${SUDO}" apt-get install -y "${PKGS[@]}"

check_ldd() {
  local bin_path="$1"
  if [ ! -f "${bin_path}" ]; then
    warn "Binary not found, skipping check: ${bin_path}"
    return 0
  fi
  if [ ! -x "${bin_path}" ]; then
    warn "Binary is not executable, skipping check: ${bin_path}"
    return 0
  fi

  log "Checking shared library resolution: ${bin_path}"
  local ldd_output
  ldd_output="$(ldd "${bin_path}" || true)"
  printf '%s\n' "${ldd_output}"

  if printf '%s\n' "${ldd_output}" | grep -q 'not found'; then
    die "Missing shared libraries detected for ${bin_path}"
  fi
}

check_ldd "${CODEX_BIN}"
check_ldd "${SANDBOX_BIN}"

log "Dependency setup complete."
