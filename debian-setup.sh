#!/usr/bin/env bash
set -euo pipefail

# Fixes Debian Stretch APT repositories after upstream mirror retirement.
# Usage:
#   ./debian-setup.sh

log() {
  printf '[debian-setup] %s\n' "$*"
}

warn() {
  printf '[debian-setup] WARN: %s\n' "$*" >&2
}

die() {
  printf '[debian-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  if [ -n "${SUDO:-}" ]; then
    "${SUDO}" "$@"
  else
    "$@"
  fi
}

write_root_file() {
  local target="$1"
  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}"
  run install -m 0644 "${tmp}" "${target}"
  rm -f "${tmp}"
}

if ! command -v apt-get >/dev/null 2>&1; then
  die "apt-get not found. This script is intended for Debian systems."
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    die "run as root or install sudo."
  fi
fi

TIMESTAMP="$(date +%F-%H%M%S)"
BACKUP_PATH="/root/apt-backup-${TIMESTAMP}"

log "Backing up /etc/apt to ${BACKUP_PATH}"
run cp -a /etc/apt "${BACKUP_PATH}"

log "Disabling existing APT source entries"
if [ -f /etc/apt/sources.list ]; then
  run mv /etc/apt/sources.list "/etc/apt/sources.list.disabled.${TIMESTAMP}"
fi

run mkdir -p /etc/apt/sources.list.d
for src in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  if [ -e "${src}" ]; then
    run mv "${src}" "${src}.disabled.${TIMESTAMP}"
  fi
done

log "Writing Stretch archive source list"
write_root_file /etc/apt/sources.list.d/stretch-archive.list <<'EOF'
deb [check-valid-until=no] http://archive.debian.org/debian stretch main contrib non-free
deb [check-valid-until=no] http://archive.debian.org/debian-security stretch/updates main contrib non-free
EOF

log "Writing archive validity override"
write_root_file /etc/apt/apt.conf.d/99archive-no-valid-until <<'EOF'
Acquire::Check-Valid-Until "false";
EOF

log "Forcing APT to use IPv4"
write_root_file /etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF

log "Clearing stale APT index files"
run rm -rf /var/lib/apt/lists/*

log "Updating package index"
if ! run apt-get update; then
  warn "apt-get update failed. Check /etc/apt/sources.list.d/stretch-archive.list and network connectivity."
  exit 1
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

log "Installing Codex runtime packages: ${PKGS[*]}"
run apt-get install -y "${PKGS[@]}"

log "APT repository setup complete."
