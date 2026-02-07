#!/usr/bin/env bash
set -euo pipefail

# Ensures the SSH daemon is enabled/running and prints a connect command.
# Usage:
#   ./ssh-setup.sh
#   ./ssh-setup.sh -u root -i wlan0
#   ./ssh-setup.sh -s sshd
#   ./ssh-setup.sh -p
#
# Environment overrides:
#   SSH_USER       (default: root)
#   SSH_INTERFACE  (default: auto-detect)
#   SSH_SERVICE    (default: auto)
#   SSH_SET_PASSWORD (default: 0)
#   SSH_DEBIAN_PACKAGES (default: openssh-server openssh-client)

SSH_USER="${SSH_USER:-root}"
SSH_INTERFACE="${SSH_INTERFACE:-}"
SSH_SERVICE="${SSH_SERVICE:-auto}"
SSH_SET_PASSWORD="${SSH_SET_PASSWORD:-0}"
SSH_DEBIAN_PACKAGES="${SSH_DEBIAN_PACKAGES:-openssh-server openssh-client}"
SUDO=""

log() {
  printf '[ssh-setup] %s\n' "$*"
}

warn() {
  printf '[ssh-setup] WARN: %s\n' "$*" >&2
}

die() {
  printf '[ssh-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  if [ -n "${SUDO}" ]; then
    "${SUDO}" "$@"
  else
    "$@"
  fi
}

write_root_file() {
  local target="$1"
  local mode="$2"
  local tmp

  tmp="$(mktemp)"
  cat >"${tmp}"

  if run test -f "${target}" && run cmp -s "${tmp}" "${target}"; then
    log "already up-to-date: ${target}"
  else
    run install -D -m "${mode}" "${tmp}" "${target}"
    log "updated ${target}"
  fi

  rm -f "${tmp}"
}

usage() {
  cat <<'EOF'
Usage:
  ./ssh-setup.sh [options]

Options:
  -u USER       SSH username hint to print (default: root)
  -i IFACE      Interface used to compute the SSH target IP (default: auto)
  -s SERVICE    Service name: ssh, sshd, dropbear, or auto (default: auto)
  -p            Prompt to set root password now (runs passwd root)
  -h            Show this help
EOF
}

sshd_config_paths() {
  local cfg
  printf '%s\n' /etc/ssh/sshd_config
  for cfg in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "${cfg}" ] || continue
    printf '%s\n' "${cfg}"
  done
}

normalize_sshd_option() {
  local key="$1"
  local value="$2"
  local cfg
  local found=0

  while IFS= read -r cfg; do
    run sed -i -E "s|^[[:space:]#]*${key}[[:space:]].*$|${key} ${value}|" "${cfg}"
    if run grep -Eq "^[[:space:]]*${key}[[:space:]]+" "${cfg}"; then
      found=1
    fi
  done < <(sshd_config_paths)

  if [ "${found}" -eq 0 ]; then
    printf '%s %s\n' "${key}" "${value}" | run tee -a /etc/ssh/sshd_config >/dev/null
    log "appended ${key} to /etc/ssh/sshd_config"
  fi
}

verify_effective_sshd_auth() {
  local root_login
  local password_auth

  root_login="$(run sshd -T | awk '$1=="permitrootlogin"{print $2; exit}')"
  password_auth="$(run sshd -T | awk '$1=="passwordauthentication"{print $2; exit}')"

  if [ "${root_login}" != "yes" ]; then
    die "effective sshd setting is permitrootlogin=${root_login}; expected yes"
  fi
  if [ "${password_auth}" != "yes" ]; then
    die "effective sshd setting is passwordauthentication=${password_auth}; expected yes"
  fi
}

ensure_debian_ssh_packages() {
  local normalized
  local -a packages

  if command -v sshd >/dev/null 2>&1; then
    return
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    warn "sshd binary not found and apt-get is unavailable; skipping package install"
    return
  fi

  normalized="${SSH_DEBIAN_PACKAGES//,/ }"
  read -r -a packages <<<"${normalized}"
  if [ "${#packages[@]}" -eq 0 ]; then
    die "SSH_DEBIAN_PACKAGES is empty; cannot install ssh daemon package"
  fi

  log "installing SSH packages: ${packages[*]}"
  run env DEBIAN_FRONTEND=noninteractive apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

  command -v sshd >/dev/null 2>&1 || die "sshd still not found after package install"
  log "SSH package install complete"
}

ensure_openssh_password_auth() {
  if ! command -v sshd >/dev/null 2>&1; then
    warn "sshd binary not found; skipping OpenSSH password-auth config"
    return
  fi

  run install -d -m 0755 /etc/ssh/sshd_config.d
  write_root_file /etc/ssh/sshd_config.d/99-root-pass.conf 0644 <<'EOF'
# Managed by ssh-setup.sh
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

  normalize_sshd_option "PermitRootLogin" "yes"
  normalize_sshd_option "PasswordAuthentication" "yes"

  run sshd -t
  verify_effective_sshd_auth
  log "validated sshd config"
}

check_root_password_state() {
  local state

  if ! command -v passwd >/dev/null 2>&1; then
    warn "passwd command not found; cannot verify root password status"
    return
  fi

  if ! state="$(passwd -S root 2>/dev/null | awk '{print $2}')"; then
    warn "could not read root password state"
    return
  fi

  case "${state}" in
    P|PS)
      log "root account has a usable password"
      ;;
    L|LK|NL|NP)
      warn "root password is locked/unset (${state}); run: passwd root"
      ;;
    *)
      warn "root password state is ${state}; verify with: passwd -S root"
      ;;
  esac
}

service_available_systemd() {
  local svc="$1"
  command -v systemctl >/dev/null 2>&1 || return 1
  run systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${svc}.service"
}

service_available_initd() {
  local svc="$1"
  [ -x "/etc/init.d/${svc}" ]
}

start_service_with_systemd() {
  local svc="$1"
  service_available_systemd "${svc}" || return 1

  run systemctl enable "${svc}" >/dev/null 2>&1 || true
  if run systemctl restart "${svc}" >/dev/null 2>&1; then
    log "enabled and restarted systemd service: ${svc}"
    return 0
  fi
  if run systemctl start "${svc}" >/dev/null 2>&1; then
    log "enabled and started systemd service: ${svc}"
    return 0
  fi
  return 1
}

start_service_with_service_cmd() {
  local svc="$1"
  command -v service >/dev/null 2>&1 || return 1
  service_available_initd "${svc}" || return 1

  if run service "${svc}" restart >/dev/null 2>&1; then
    log "restarted service: ${svc}"
    return 0
  fi
  if run service "${svc}" start >/dev/null 2>&1; then
    log "started service: ${svc}"
    return 0
  fi
  return 1
}

start_service_with_initd() {
  local svc="$1"
  service_available_initd "${svc}" || return 1

  if run "/etc/init.d/${svc}" restart >/dev/null 2>&1; then
    log "restarted init script: ${svc}"
    return 0
  fi
  if run "/etc/init.d/${svc}" start >/dev/null 2>&1; then
    log "started init script: ${svc}"
    return 0
  fi
  return 1
}

start_ssh_service() {
  local svc="$1"
  start_service_with_systemd "${svc}" && return 0
  start_service_with_service_cmd "${svc}" && return 0
  start_service_with_initd "${svc}" && return 0
  return 1
}

get_ip_for_interface() {
  local iface="$1"
  ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

get_first_global_ip() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

print_connect_hint() {
  local ip_addr=""

  if ! command -v ip >/dev/null 2>&1; then
    warn "ip command not found; cannot auto-detect target address"
    return
  fi

  if [ -n "${SSH_INTERFACE}" ]; then
    ip_addr="$(get_ip_for_interface "${SSH_INTERFACE}" || true)"
    [ -n "${ip_addr}" ] || warn "no IPv4 address on ${SSH_INTERFACE}"
  else
    ip_addr="$(get_first_global_ip || true)"
  fi

  if [ -n "${ip_addr}" ]; then
    log "ssh daemon is running; connect from your PC with:"
    printf 'ssh %s@%s\n' "${SSH_USER}" "${ip_addr}"
  else
    warn "ssh daemon started but no IPv4 address was detected yet"
  fi
}

main() {
  while getopts ":u:i:s:ph" opt; do
    case "${opt}" in
      u) SSH_USER="${OPTARG}" ;;
      i) SSH_INTERFACE="${OPTARG}" ;;
      s) SSH_SERVICE="${OPTARG}" ;;
      p) SSH_SET_PASSWORD="1" ;;
      h)
        usage
        exit 0
        ;;
      :)
        die "missing value for -${OPTARG}"
        ;;
      \?)
        die "unknown option: -${OPTARG}"
        ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ "$#" -gt 0 ]; then
    die "unexpected positional arguments: $*"
  fi

  if [ -z "${SSH_USER}" ]; then
    die "SSH user cannot be empty"
  fi

  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      die "run as root or install sudo"
    fi
  fi

  ensure_debian_ssh_packages
  ensure_openssh_password_auth
  if [ "${SSH_SET_PASSWORD}" = "1" ]; then
    run passwd root
  fi
  check_root_password_state

  local -a candidates
  if [ "${SSH_SERVICE}" = "auto" ]; then
    candidates=(ssh sshd dropbear)
  else
    candidates=("${SSH_SERVICE}")
  fi

  local svc
  local -a tried
  tried=()
  for svc in "${candidates[@]}"; do
    tried+=("${svc}")
    if start_ssh_service "${svc}"; then
      print_connect_hint
      log "SSH setup complete using service ${svc}"
      return 0
    fi
  done

  die "could not start SSH service (tried: ${tried[*]})"
}

main "$@"
