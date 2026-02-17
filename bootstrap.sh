#!/usr/bin/env bash
set -euo pipefail

# One-command bootstrap for TS-7800-v2 + OptConnect neo2.
#
# Usage (serial console, as root):
#   echo "nameserver 8.8.8.8" > /etc/resolv.conf
#   curl -fsSL https://raw.githubusercontent.com/broomfield-digital/DiscordiaOS/main/bootstrap.sh | bash
#
# The resolv.conf line is required on a fresh board (no DNS configured).
# bootstrap.sh will write a permanent resolv.conf as part of static eth0 setup.
#
# Environment overrides:
#   DISCORDIA_REPO        (default: https://github.com/broomfield-digital/DiscordiaOS.git)
#   DISCORDIA_DIR         (default: /root/DiscordiaOS)
#   ETH_IFACE        (default: eth0)
#   ETH_ADDRESS      (default: 192.168.1.11/24)
#   ETH_GATEWAY      (default: 192.168.1.90)
#   ETH_DNS          (default: 192.168.1.90 8.8.8.8)

DISCORDIA_REPO="${DISCORDIA_REPO:-https://github.com/broomfield-digital/DiscordiaOS.git}"
DISCORDIA_DIR="${DISCORDIA_DIR:-/root/DiscordiaOS}"
ETH_IFACE="${ETH_IFACE:-eth0}"
ETH_ADDRESS="${ETH_ADDRESS:-192.168.1.11/24}"
ETH_GATEWAY="${ETH_GATEWAY:-192.168.1.90}"
ETH_DNS="${ETH_DNS:-192.168.1.90 8.8.8.8}"

log() {
	printf '[bootstrap] %s\n' "$*"
}

warn() {
	printf '[bootstrap] WARN: %s\n' "$*" >&2
}

die() {
	printf '[bootstrap] ERROR: %s\n' "$*" >&2
	exit 1
}

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		die "must run as root"
	fi
}

can_resolve_dns() {
	local host="${1:-github.com}"
	if command -v getent >/dev/null 2>&1; then
		getent hosts "$host" >/dev/null 2>&1
	elif command -v nslookup >/dev/null 2>&1; then
		nslookup "$host" >/dev/null 2>&1
	else
		return 1
	fi
}

ensure_eth0_temporary() {
	if ip -4 -o addr show dev "$ETH_IFACE" 2>/dev/null | grep -q 'inet '; then
		log "$ETH_IFACE already has an IPv4 address"
		return
	fi

	log "requesting temporary DHCP lease on $ETH_IFACE"
	ip link set "$ETH_IFACE" up || true

	if command -v dhclient >/dev/null 2>&1; then
		dhclient -v "$ETH_IFACE" || warn "dhclient failed on $ETH_IFACE"
	elif command -v udhcpc >/dev/null 2>&1; then
		udhcpc -i "$ETH_IFACE" -q -n || warn "udhcpc failed on $ETH_IFACE"
	else
		warn "no DHCP client found; $ETH_IFACE may need manual IP assignment"
	fi

	if ! ip -4 -o addr show dev "$ETH_IFACE" 2>/dev/null | grep -q 'inet '; then
		die "failed to obtain IPv4 on $ETH_IFACE; check cable and OptConnect"
	fi

	log "$ETH_IFACE has $(ip -4 -o addr show dev "$ETH_IFACE" | awk '{print $4}' | head -n1)"
}

ensure_dns() {
	# Always write resolv.conf.  DNS may appear to work via a temporary
	# DHCP lease, but that config disappears after reboot.  We need our
	# own copy so the rest of bootstrap (and subsequent boots) can resolve.
	if [ -L /etc/resolv.conf ]; then
		rm -f /etc/resolv.conf
	fi

	local dns
	{
		printf '# Managed by bootstrap.sh\n'
		for dns in $ETH_DNS; do
			printf 'nameserver %s\n' "$dns"
		done
	} >/etc/resolv.conf
	log "wrote /etc/resolv.conf: $ETH_DNS"

	if ! can_resolve_dns github.com; then
		die "DNS resolution failed; check connectivity and ETH_DNS ($ETH_DNS)"
	fi

	log "DNS resolution working"
}

clone_or_update_repo() {
	if [ -d "$DISCORDIA_DIR/.git" ]; then
		log "updating existing repo in $DISCORDIA_DIR"
		git -C "$DISCORDIA_DIR" pull --ff-only || warn "git pull failed; using existing checkout"
	elif [ -d "$DISCORDIA_DIR" ] && [ -z "$(ls -A "$DISCORDIA_DIR" 2>/dev/null)" ]; then
		rmdir "$DISCORDIA_DIR"
		git clone "$DISCORDIA_REPO" "$DISCORDIA_DIR"
	elif [ ! -e "$DISCORDIA_DIR" ]; then
		log "cloning $DISCORDIA_REPO to $DISCORDIA_DIR"
		git clone "$DISCORDIA_REPO" "$DISCORDIA_DIR"
	else
		die "$DISCORDIA_DIR exists but is not a git repository; remove it and re-run"
	fi
}

configure_static_eth0() {
	local cfg="/etc/network/interfaces.d/${ETH_IFACE}.cfg"
	local addr="${ETH_ADDRESS%/*}"
	local prefix="${ETH_ADDRESS#*/}"
	local netmask

	case "$prefix" in
		24) netmask="255.255.255.0" ;;
		16) netmask="255.255.0.0" ;;
		8)  netmask="255.0.0.0" ;;
		*)  netmask="255.255.255.0"; warn "unknown prefix /$prefix; defaulting to /24" ;;
	esac

	# Ensure interfaces.d is sourced.
	if [ -f /etc/network/interfaces ]; then
		if ! grep -Eq '^[[:space:]]*source-directory[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces &&
		   ! grep -Eq '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' /etc/network/interfaces; then
			printf '\nsource-directory /etc/network/interfaces.d\n' >>/etc/network/interfaces
			log "added interfaces.d include to /etc/network/interfaces"
		fi
	else
		cat >/etc/network/interfaces <<'EOF'
# Managed by bootstrap.sh
source-directory /etc/network/interfaces.d
EOF
	fi

	mkdir -p /etc/network/interfaces.d

	cat >"$cfg" <<EOF
auto ${ETH_IFACE}
iface ${ETH_IFACE} inet static
    address ${addr}
    netmask ${netmask}
    gateway ${ETH_GATEWAY}
    dns-nameservers ${ETH_DNS}
EOF
	log "wrote static config: $cfg ($addr/$prefix via $ETH_GATEWAY)"

	# Write a persistent /etc/resolv.conf.  The dns-nameservers directive
	# in ifupdown config only takes effect when the resolvconf package is
	# installed, which we don't require.
	if [ -L /etc/resolv.conf ]; then
		rm -f /etc/resolv.conf
	fi
	local dns
	{
		printf '# Managed by bootstrap.sh\n'
		for dns in $ETH_DNS; do
			printf 'nameserver %s\n' "$dns"
		done
	} >/etc/resolv.conf
	log "wrote /etc/resolv.conf: $ETH_DNS"

	# Kill any DHCP client from the temporary lease before switching to static.
	pkill -f "dhclient.*${ETH_IFACE}" >/dev/null 2>&1 || true
	pkill -f "udhcpc.*${ETH_IFACE}" >/dev/null 2>&1 || true

	# Apply the static configuration.
	ifdown "$ETH_IFACE" >/dev/null 2>&1 || true
	ifup "$ETH_IFACE" >/dev/null 2>&1 || warn "ifup $ETH_IFACE failed; config will apply on next boot"

	log "$ETH_IFACE configured: $(ip -4 -o addr show dev "$ETH_IFACE" | awk '{print $4}' | head -n1)"
}

main() {
	require_root
	log "starting bootstrap"

	# Phase 1: temporary connectivity
	ensure_eth0_temporary
	ensure_dns

	# Phase 2: get the repo
	clone_or_update_repo

	# Phase 3: run setup scripts
	log "running debian-setup.sh"
	bash "$DISCORDIA_DIR/debian-setup.sh"

	log "running discordia-setup.sh"
	bash "$DISCORDIA_DIR/discordia-setup.sh"

	# Phase 4: permanent static eth0 for OptConnect
	log "configuring static eth0 for OptConnect"
	configure_static_eth0

	# Phase 5: enable SSH
	log "running ssh-setup.sh"
	bash "$DISCORDIA_DIR/ssh-setup.sh"

	log "bootstrap complete"
	log "local eth0 address: ${ETH_ADDRESS%/*} (OptConnect link only)"
	log "look up the VPN-routable IP on the OptConnect Summit portal, then:"
	log "  ssh root@<VPN-IP>"
}

main "$@"
