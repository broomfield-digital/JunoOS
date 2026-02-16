#!/usr/bin/env bash
set -euo pipefail

# Joins the board to a WPA/WPA2 Wi-Fi network and persists config.
# Usage:
#   ./wifi-setup.sh
#   ./wifi-setup.sh -s "MySSID" -p "MyPassword" -i wlan0
#
# Environment overrides:
#   WIFI_SSID       (required, or use -s)
#   WIFI_PASSWORD   (required, or use -p)
#   WIFI_INTERFACE  (default: wlan0)
#   WIFI_COUNTRY    (default: US)
#   WIFI_DNS_SERVERS (default: 1.1.1.1 8.8.8.8)
#   WIFI_INSTALL_BOOT_SERVICE (default: 1)

WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_INTERFACE="${WIFI_INTERFACE:-wlan0}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
WIFI_DNS_SERVERS="${WIFI_DNS_SERVERS:-1.1.1.1 8.8.8.8}"
WIFI_INSTALL_BOOT_SERVICE="${WIFI_INSTALL_BOOT_SERVICE:-1}"
SUDO=""

log() {
  printf '[wifi-setup] %s\n' "$*"
}

warn() {
  printf '[wifi-setup] WARN: %s\n' "$*" >&2
}

die() {
  printf '[wifi-setup] ERROR: %s\n' "$*" >&2
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
  ./wifi-setup.sh SSID PASSWORD
  ./wifi-setup.sh -s SSID -p PASSWORD [options]

Options:
  -s SSID       Wi-Fi network name
  -p PASSWORD   Wi-Fi password
  -i IFACE      Wireless interface (default: wlan0)
  -c COUNTRY    Wi-Fi country code (default: US)
  -d DNS_LIST   Fallback DNS servers (space/comma-separated, default: 1.1.1.1 8.8.8.8)
  -B            Skip installing boot-time Wi-Fi recovery service
  -h, --help    Show this help
EOF
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

nmcli_running() {
  if ! command -v nmcli >/dev/null 2>&1; then
    return 1
  fi
  [ "$(nmcli -t -f RUNNING general 2>/dev/null || true)" = "running" ]
}

nmcli_has_wifi_interface() {
  nmcli -t -f DEVICE,TYPE device status | grep -q "^${WIFI_INTERFACE}:wifi$"
}

connect_with_nmcli() {
  log "configuring Wi-Fi through NetworkManager"
  run nmcli radio wifi on

  if nmcli -t -f NAME connection show | grep -Fxq "${WIFI_SSID}"; then
    log "updating existing NetworkManager profile: ${WIFI_SSID}"
  else
    run nmcli connection add type wifi ifname "${WIFI_INTERFACE}" con-name "${WIFI_SSID}" ssid "${WIFI_SSID}"
    log "created NetworkManager profile: ${WIFI_SSID}"
  fi

  run nmcli connection modify "${WIFI_SSID}" \
    connection.interface-name "${WIFI_INTERFACE}" \
    connection.autoconnect yes \
    802-11-wireless.ssid "${WIFI_SSID}" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "${WIFI_PASSWORD}"

  run nmcli connection up id "${WIFI_SSID}" ifname "${WIFI_INTERFACE}"
}

ensure_interfaces_include() {
  if [ ! -f /etc/network/interfaces ]; then
    write_root_file /etc/network/interfaces 0644 <<'EOF'
# Managed by wifi-setup.sh
source-directory /etc/network/interfaces.d
EOF
    return
  fi

  if grep -Eq '^[[:space:]]*source-directory[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces; then
    return
  fi
  if grep -Eq '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' /etc/network/interfaces; then
    return
  fi

  printf '\nsource-directory /etc/network/interfaces.d\n' | run tee -a /etc/network/interfaces >/dev/null
  log "added interfaces.d include to /etc/network/interfaces"
}

connect_with_wpa_supplicant() {
  local wpa_conf="/etc/wpa_supplicant/wpa_supplicant-${WIFI_INTERFACE}.conf"
  local iface_cfg="/etc/network/interfaces.d/${WIFI_INTERFACE}.cfg"
  local ifup_output

  command -v wpa_passphrase >/dev/null 2>&1 || die "wpa_passphrase not found; install wpasupplicant"

  log "configuring Wi-Fi through wpa_supplicant/ifupdown"

  write_root_file "${wpa_conf}" 0600 <<EOF
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY}
$(wpa_passphrase "${WIFI_SSID}" "${WIFI_PASSWORD}" | sed '/^[[:space:]]*#psk=/d')
EOF

  ensure_interfaces_include

  write_root_file "${iface_cfg}" 0644 <<EOF
auto ${WIFI_INTERFACE}
allow-hotplug ${WIFI_INTERFACE}
iface ${WIFI_INTERFACE} inet dhcp
    wpa-conf ${wpa_conf}
EOF

  if command -v ifup >/dev/null 2>&1 && command -v ifdown >/dev/null 2>&1; then
    run ifdown "${WIFI_INTERFACE}" >/dev/null 2>&1 || true
    if ifup_output="$(run ifup "${WIFI_INTERFACE}" 2>&1)"; then
      if [ -n "${ifup_output}" ]; then
        log "${ifup_output}"
      fi
      return
    fi
    warn "ifup failed on ${WIFI_INTERFACE}; falling back to direct wpa_supplicant/DHCP"
    if [ -n "${ifup_output}" ]; then
      warn "${ifup_output}"
    fi
  else
    warn "ifup/ifdown not found; starting wpa_supplicant and requesting DHCP directly"
  fi

  # Kill any existing wpa_supplicant for this interface
  run pkill -f "wpa_supplicant.*${WIFI_INTERFACE}" 2>/dev/null || true
  run rm -f "/run/wpa_supplicant/${WIFI_INTERFACE}" 2>/dev/null || true
  sleep 1

  run ip link set "${WIFI_INTERFACE}" up || true
  run wpa_supplicant -B -i "${WIFI_INTERFACE}" -c "${wpa_conf}"
  if command -v dhclient >/dev/null 2>&1; then
    run dhclient -v "${WIFI_INTERFACE}" || warn "dhclient failed on ${WIFI_INTERFACE}"
  elif command -v udhcpc >/dev/null 2>&1; then
    run udhcpc -i "${WIFI_INTERFACE}" -q -n || warn "udhcpc failed on ${WIFI_INTERFACE}"
  else
    warn "no DHCP client found (dhclient/udhcpc); assign IP manually"
  fi
}

show_ip_status() {
  local ip_addr
  ip_addr="$(ip -4 -o addr show dev "${WIFI_INTERFACE}" | awk '{print $4}' | head -n1 || true)"
  if [ -n "${ip_addr}" ]; then
    log "connected: ${WIFI_INTERFACE} has ${ip_addr}"
  else
    warn "no IPv4 address on ${WIFI_INTERFACE} yet"
  fi
}

can_resolve_dns() {
  local host="${1:-github.com}"
  if command -v getent >/dev/null 2>&1; then
    getent hosts "${host}" >/dev/null 2>&1
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "${host}" >/dev/null 2>&1
  else
    return 1
  fi
}

has_nameserver_config() {
  grep -Eq '^[[:space:]]*nameserver[[:space:]]+[[:graph:]]+' /etc/resolv.conf 2>/dev/null
}

write_fallback_dns() {
  local tmp
  local dns
  tmp="$(mktemp)"

  cat >"${tmp}" <<EOF
# Managed by wifi-setup.sh fallback DNS
EOF
  for dns in ${WIFI_DNS_SERVERS}; do
    printf 'nameserver %s\n' "${dns}" >>"${tmp}"
  done

  if [ -L /etc/resolv.conf ]; then
    warn "/etc/resolv.conf is a symlink; skipping fallback DNS write"
    rm -f "${tmp}"
    return 1
  fi

  run install -m 0644 "${tmp}" /etc/resolv.conf
  rm -f "${tmp}"
  log "applied fallback DNS to /etc/resolv.conf: ${WIFI_DNS_SERVERS}"
}

ensure_dns_resolution() {
  if [ -z "${WIFI_DNS_SERVERS}" ]; then
    warn "fallback DNS list is empty; skipping DNS repair checks"
    return
  fi

  if can_resolve_dns github.com; then
    log "DNS resolution is working"
    return
  fi

  if has_nameserver_config; then
    warn "DNS lookup failed despite configured nameservers; applying fallback DNS"
  else
    warn "no nameservers configured; applying fallback DNS"
  fi

  if write_fallback_dns && ! can_resolve_dns github.com; then
    warn "DNS still failing after fallback; verify gateway and upstream DNS reachability"
  fi
}

install_boot_wifi_service() {
  local boot_script="/usr/local/sbin/discordia-wifi-ensure.sh"
  local env_file="/etc/default/discordia-wifi"
  local service_file="/etc/systemd/system/discordia-wifi-ensure.service"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; skipping boot-time Wi-Fi service install"
    return
  fi

  write_root_file "${boot_script}" 0755 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

WIFI_INTERFACE="${WIFI_INTERFACE:-wlan0}"
WIFI_DNS_SERVERS="${WIFI_DNS_SERVERS:-1.1.1.1 8.8.8.8}"

log() {
  printf '[discordia-wifi-ensure] %s\n' "$*"
}

warn() {
  printf '[discordia-wifi-ensure] WARN: %s\n' "$*" >&2
}

has_ipv4() {
  ip -4 -o addr show dev "${WIFI_INTERFACE}" | grep -q 'inet '
}

wait_for_ipv4() {
  local max_wait="${1:-20}"
  local i=0
  while [ "${i}" -lt "${max_wait}" ]; do
    if has_ipv4; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

can_resolve_dns() {
  local host="${1:-github.com}"
  if command -v getent >/dev/null 2>&1; then
    getent hosts "${host}" >/dev/null 2>&1
  elif command -v nslookup >/dev/null 2>&1; then
    nslookup "${host}" >/dev/null 2>&1
  else
    return 1
  fi
}

has_nameserver_config() {
  grep -Eq '^[[:space:]]*nameserver[[:space:]]+[[:graph:]]+' /etc/resolv.conf 2>/dev/null
}

write_fallback_dns() {
  local tmp
  local dns
  tmp="$(mktemp)"

  cat >"${tmp}" <<EOF_DNS
# Managed by discordia-wifi-ensure fallback DNS
EOF_DNS
  for dns in ${WIFI_DNS_SERVERS}; do
    printf 'nameserver %s\n' "${dns}" >>"${tmp}"
  done

  if [ -L /etc/resolv.conf ]; then
    warn "/etc/resolv.conf is a symlink; skipping fallback DNS write"
    rm -f "${tmp}"
    return 1
  fi

  install -m 0644 "${tmp}" /etc/resolv.conf
  rm -f "${tmp}"
  log "applied fallback DNS to /etc/resolv.conf: ${WIFI_DNS_SERVERS}"
}

ensure_dns_resolution() {
  if [ -z "${WIFI_DNS_SERVERS}" ]; then
    return
  fi

  if can_resolve_dns github.com; then
    return
  fi

  if has_nameserver_config; then
    warn "DNS lookup failed despite configured nameservers; applying fallback DNS"
  else
    warn "no nameservers configured; applying fallback DNS"
  fi

  if write_fallback_dns && ! can_resolve_dns github.com; then
    warn "DNS still failing after fallback; verify gateway and upstream DNS reachability"
  fi
}

nmcli_running() {
  if ! command -v nmcli >/dev/null 2>&1; then
    return 1
  fi
  [ "$(nmcli -t -f RUNNING general 2>/dev/null || true)" = "running" ]
}

nmcli_has_wifi_interface() {
  nmcli -t -f DEVICE,TYPE device status | grep -q "^${WIFI_INTERFACE}:wifi$"
}

try_nmcli() {
  nmcli_running || return 1
  nmcli_has_wifi_interface || return 1

  nmcli radio wifi on || true
  nmcli device set "${WIFI_INTERFACE}" managed yes || true
  nmcli device connect "${WIFI_INTERFACE}" || true
}

try_ifup() {
  if command -v ifup >/dev/null 2>&1 && [ -f "/etc/network/interfaces.d/${WIFI_INTERFACE}.cfg" ]; then
    ifup "${WIFI_INTERFACE}" || true
    return 0
  fi
  return 1
}

try_wpa_supplicant() {
  local wpa_conf="/etc/wpa_supplicant/wpa_supplicant-${WIFI_INTERFACE}.conf"

  if [ ! -f "${wpa_conf}" ]; then
    return 1
  fi

  if ! command -v wpa_supplicant >/dev/null 2>&1; then
    return 1
  fi

  pkill -f "wpa_supplicant.*${WIFI_INTERFACE}" >/dev/null 2>&1 || true
  rm -f "/run/wpa_supplicant/${WIFI_INTERFACE}" 2>/dev/null || true
  sleep 1
  wpa_supplicant -B -i "${WIFI_INTERFACE}" -c "${wpa_conf}" || true

  if command -v dhclient >/dev/null 2>&1; then
    dhclient -v "${WIFI_INTERFACE}" || true
  elif command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i "${WIFI_INTERFACE}" -q -n || true
  fi

  # WILC driver workaround: full reconnect cycle to fix unicast traffic
  log "applying WILC workaround: reconnect cycle"
  sleep 2
  pkill -f "wpa_supplicant.*${WIFI_INTERFACE}" >/dev/null 2>&1 || true
  rm -f "/run/wpa_supplicant/${WIFI_INTERFACE}" 2>/dev/null || true
  sleep 1
  wpa_supplicant -B -i "${WIFI_INTERFACE}" -c "${wpa_conf}" || true
  sleep 3
  if command -v dhclient >/dev/null 2>&1; then
    dhclient -v "${WIFI_INTERFACE}" || true
  elif command -v udhcpc >/dev/null 2>&1; then
    udhcpc -i "${WIFI_INTERFACE}" -q -n || true
  fi
}

main() {
  # Load WiFi driver if needed (WILC SPI for TS-7800-v2)
  if ! ip link show "${WIFI_INTERFACE}" >/dev/null 2>&1; then
    modprobe wilc-spi 2>/dev/null || modprobe wilc_spi 2>/dev/null || true
    sleep 2
  fi

  if ! ip link show "${WIFI_INTERFACE}" >/dev/null 2>&1; then
    warn "interface not found: ${WIFI_INTERFACE}"
    exit 0
  fi

  ip link set "${WIFI_INTERFACE}" up || true

  disable_power_save() {
    if command -v iw >/dev/null 2>&1; then
      iw "${WIFI_INTERFACE}" set power_save off 2>/dev/null || true
    fi
  }

  if has_ipv4; then
    disable_power_save
    ensure_dns_resolution
    log "${WIFI_INTERFACE} already has IPv4"
    exit 0
  fi

  try_nmcli && wait_for_ipv4 20 && {
    disable_power_save
    ensure_dns_resolution
    log "connected via NetworkManager"
    exit 0
  }

  try_ifup && wait_for_ipv4 20 && {
    disable_power_save
    ensure_dns_resolution
    log "connected via ifupdown"
    exit 0
  }

  try_wpa_supplicant && wait_for_ipv4 25 && {
    disable_power_save
    ensure_dns_resolution
    log "connected via direct wpa_supplicant/DHCP"
    exit 0
  }

  warn "unable to obtain IPv4 on ${WIFI_INTERFACE}"
  exit 0
}

main "$@"
EOF

  write_root_file "${env_file}" 0644 <<EOF
# Managed by wifi-setup.sh
WIFI_INTERFACE="${WIFI_INTERFACE}"
WIFI_DNS_SERVERS="${WIFI_DNS_SERVERS}"
EOF

  write_root_file "${service_file}" 0644 <<'EOF'
[Unit]
Description=Ensure Wi-Fi connectivity at boot (Discordia)
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service
ConditionPathExists=/usr/local/sbin/discordia-wifi-ensure.sh

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/discordia-wifi
ExecStart=/usr/local/sbin/discordia-wifi-ensure.sh
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

  # WILC workaround: delayed fixup service that re-runs wifi-setup after boot
  local fixup_service="/etc/systemd/system/discordia-wifi-fixup.service"
  local fixup_timer="/etc/systemd/system/discordia-wifi-fixup.timer"

  write_root_file "${fixup_service}" 0644 <<EOF
[Unit]
Description=WILC Wi-Fi fixup (Discordia)
After=discordia-wifi-ensure.service

[Service]
Type=oneshot
Environment=WIFI_SSID="${WIFI_SSID}"
Environment=WIFI_PASSWORD="${WIFI_PASSWORD}"
Environment=WIFI_INTERFACE="${WIFI_INTERFACE}"
ExecStart=/root/DiscordiaOS/wifi-setup.sh -B
EOF

  write_root_file "${fixup_timer}" 0644 <<'EOF'
[Unit]
Description=WILC Wi-Fi fixup timer (Discordia)

[Timer]
OnBootSec=30s
Unit=discordia-wifi-fixup.service

[Install]
WantedBy=timers.target
EOF

  if run systemctl daemon-reload >/dev/null 2>&1; then
    if run systemctl enable discordia-wifi-ensure.service >/dev/null 2>&1; then
      log "enabled boot-time Wi-Fi service: discordia-wifi-ensure.service"
    else
      warn "failed to enable discordia-wifi-ensure.service; enable manually if needed"
    fi
    if run systemctl enable discordia-wifi-fixup.timer >/dev/null 2>&1; then
      log "enabled Wi-Fi fixup timer: discordia-wifi-fixup.timer (30s after boot)"
    else
      warn "failed to enable discordia-wifi-fixup.timer; enable manually if needed"
    fi
  else
    warn "systemctl daemon-reload failed; skipping service enable"
  fi
}

main() {
  # Handle --help before getopts (which only supports single-dash options)
  for arg in "$@"; do
    case "${arg}" in
      --help)
        usage
        exit 0
        ;;
    esac
  done

  while getopts ":s:p:i:c:d:Bh" opt; do
    case "${opt}" in
      s) WIFI_SSID="${OPTARG}" ;;
      p) WIFI_PASSWORD="${OPTARG}" ;;
      i) WIFI_INTERFACE="${OPTARG}" ;;
      c) WIFI_COUNTRY="${OPTARG}" ;;
      d) WIFI_DNS_SERVERS="${OPTARG}" ;;
      B) WIFI_INSTALL_BOOT_SERVICE="0" ;;
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

  WIFI_DNS_SERVERS="${WIFI_DNS_SERVERS//,/ }"

  # Support positional arguments: SSID [PASSWORD]
  if [ "$#" -ge 1 ] && [ -z "${WIFI_SSID}" ]; then
    WIFI_SSID="$1"
    shift
  fi
  if [ "$#" -ge 1 ] && [ -z "${WIFI_PASSWORD}" ]; then
    WIFI_PASSWORD="$1"
    shift
  fi
  if [ "$#" -gt 0 ]; then
    die "unexpected positional arguments: $*"
  fi

  [ -n "${WIFI_SSID}" ] || die "SSID cannot be empty"
  [ -n "${WIFI_PASSWORD}" ] || die "password cannot be empty"
  [ "${#WIFI_PASSWORD}" -ge 8 ] || warn "password is shorter than 8 characters; WPA may reject it"

  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      die "run as root or install sudo"
    fi
  fi

  # Load WiFi driver if needed (WILC SPI for TS-7800-v2)
  if ! ip link show "${WIFI_INTERFACE}" >/dev/null 2>&1; then
    log "interface ${WIFI_INTERFACE} not found, attempting to load driver"
    modprobe wilc-spi 2>/dev/null || modprobe wilc_spi 2>/dev/null || true
    sleep 2
  fi

  if ! ip link show "${WIFI_INTERFACE}" >/dev/null 2>&1; then
    die "network interface not found: ${WIFI_INTERFACE}"
  fi

  run ip link set "${WIFI_INTERFACE}" up || true

  if nmcli_running && nmcli_has_wifi_interface; then
    connect_with_nmcli
  else
    if nmcli_running; then
      warn "NetworkManager is running but ${WIFI_INTERFACE} is not managed as Wi-Fi; using wpa_supplicant fallback"
    fi
    connect_with_wpa_supplicant
  fi

  # Disable power management after connection (driver re-enables during connect)
  if command -v iw >/dev/null 2>&1; then
    run iw "${WIFI_INTERFACE}" set power_save off 2>/dev/null || true
    log "disabled WiFi power management"
  fi

  ensure_dns_resolution
  if is_true "${WIFI_INSTALL_BOOT_SERVICE}"; then
    install_boot_wifi_service
  else
    log "boot-time Wi-Fi service install skipped"
  fi
  show_ip_status
  log "Wi-Fi setup complete for SSID ${WIFI_SSID}"
}

main "$@"
