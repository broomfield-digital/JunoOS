#!/usr/bin/env bash
#
# Automated Debian setup for TS-7800-V2 boards.
# This script is designed to be idempotent: running it multiple times should
# converge the machine to the same configuration.
#
# Usage (run as root on the target board):
#   DISCORDIA_SSH_PUBKEY="ssh-ed25519 AAAA... comment" ./discordia-setup.sh
# or:
#   DISCORDIA_SSH_KEY_FILE=/root/discordia.pub ./discordia-setup.sh
#
# Optional environment overrides:
#   DISCORDIA_CONFIGURE_SSH=0
#   APP_SHARE_MEDIA=1
#   APP_DATA_LABEL=APPDATA
#   APP_LOGS_LABEL=APPLOGS

set -euo pipefail

LOG_PREFIX="discordia-setup"
FSTAB_BEGIN="# BEGIN DISCORDIA MANAGED BLOCK"
FSTAB_END="# END DISCORDIA MANAGED BLOCK"

DISCORDIA_USER="${DISCORDIA_USER:-discordia}"
DISCORDIA_SSH_PUBKEY="${DISCORDIA_SSH_PUBKEY:-}"
DISCORDIA_SSH_KEY_FILE="${DISCORDIA_SSH_KEY_FILE:-}"
DISCORDIA_CONFIGURE_SSH="${DISCORDIA_CONFIGURE_SSH:-0}"

APP_DATA_LABEL="${APP_DATA_LABEL:-APPDATA}"
APP_LOGS_LABEL="${APP_LOGS_LABEL:-APPLOGS}"
APP_SHARE_MEDIA="${APP_SHARE_MEDIA:-1}"

timestamp() {
	date -Iseconds
}

log() {
	printf '[%s] %s: %s\n' "$(timestamp)" "$LOG_PREFIX" "$*"
}

warn() {
	printf '[%s] %s: WARN: %s\n' "$(timestamp)" "$LOG_PREFIX" "$*" >&2
}

die() {
	printf '[%s] %s: ERROR: %s\n' "$(timestamp)" "$LOG_PREFIX" "$*" >&2
	exit 1
}

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		die "must run as root"
	fi
}

write_if_changed() {
	local target="$1"
	local tmp
	tmp="$(mktemp)"
	cat >"$tmp"
	if ! cmp -s "$tmp" "$target" 2>/dev/null; then
		install -m 0644 "$tmp" "$target"
		log "updated $target"
	else
		log "already up-to-date: $target"
	fi
	rm -f "$tmp"
}

ensure_user() {
	local user="$1"
	local shell="$2"
	local home="$3"
	local extra_group="${4:-}"

	if id -u "$user" >/dev/null 2>&1; then
		log "user exists: $user"
	else
		useradd -m -s "$shell" -d "$home" "$user"
		log "created user: $user"
	fi

	if [ -n "$extra_group" ] && getent group "$extra_group" >/dev/null 2>&1; then
		if ! id -nG "$user" | tr ' ' '\n' | grep -qx "$extra_group"; then
			usermod -aG "$extra_group" "$user"
			log "added $user to group $extra_group"
		else
			log "user $user already in group $extra_group"
		fi
	fi
}

get_discordia_pubkey() {
	local key=""

	if [ -n "$DISCORDIA_SSH_PUBKEY" ]; then
		key="$DISCORDIA_SSH_PUBKEY"
	elif [ -n "$DISCORDIA_SSH_KEY_FILE" ]; then
		[ -f "$DISCORDIA_SSH_KEY_FILE" ] || die "DISCORDIA_SSH_KEY_FILE not found: $DISCORDIA_SSH_KEY_FILE"
		key="$(awk '
			/^[[:space:]]*#/ { next }
			/^[[:space:]]*$/ { next }
			{ print; exit }
		' "$DISCORDIA_SSH_KEY_FILE")"
	else
		return 1
	fi

	# Reject empty/whitespace-only key material.
	if [ -z "$(printf '%s' "$key" | tr -d '[:space:]')" ]; then
		return 1
	fi

	printf '%s\n' "$key"
}

ensure_authorized_key() {
	local user="$1"
	local key="$2"
	local home
	local ssh_dir
	local auth_file

	[ -n "$(printf '%s' "$key" | tr -d '[:space:]')" ] || die "refusing to install empty SSH key for user $user"

	home="$(getent passwd "$user" | cut -d: -f6)"
	[ -n "$home" ] || die "unable to determine home directory for user $user"
	ssh_dir="$home/.ssh"
	auth_file="$ssh_dir/authorized_keys"

	install -d -m 0700 -o "$user" -g "$user" "$ssh_dir"
	touch "$auth_file"
	chown "$user:$user" "$auth_file"
	chmod 0600 "$auth_file"

	if grep -qxF "$key" "$auth_file"; then
		log "authorized key already present for $user"
	else
		printf '%s\n' "$key" >>"$auth_file"
		log "installed authorized key for $user"
	fi
}

is_key_present_for_user() {
	local user="$1"
	local home
	local auth_file

	home="$(getent passwd "$user" | cut -d: -f6 || true)"
	[ -n "$home" ] || return 1
	auth_file="$home/.ssh/authorized_keys"
	[ -f "$auth_file" ] || return 1
	grep -Eq '^[[:space:]]*[^#[:space:]]' "$auth_file"
}

ensure_pkg_install() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get install -y \
		ca-certificates \
		curl \
		git \
		htop \
		jq \
		mosquitto-clients \
		openssh-server \
		python3 \
		python3-pip \
		python3-venv \
		sudo \
		tmux
	log "package install complete"
}

ensure_sshd_config() {
	local password_auth="yes"
	local permit_root="yes"

	if is_key_present_for_user root || is_key_present_for_user "$DISCORDIA_USER"; then
		password_auth="no"
		permit_root="prohibit-password"
	else
		warn "no SSH authorized key found for root or $DISCORDIA_USER; keeping password auth enabled to avoid lockout"
	fi

	install -d -m 0755 /etc/ssh/sshd_config.d
	write_if_changed /etc/ssh/sshd_config.d/hardened.conf <<EOF
PermitRootLogin ${permit_root}
PasswordAuthentication ${password_auth}
PubkeyAuthentication yes
X11Forwarding no
EOF

	sshd -t
	if systemctl list-unit-files | awk '{print $1}' | grep -qx 'ssh.service'; then
		systemctl enable ssh
		systemctl restart ssh
	else
		systemctl enable sshd
		systemctl restart sshd
	fi
	log "ssh configuration applied"
}

should_configure_ssh() {
	case "${DISCORDIA_CONFIGURE_SSH}" in
		1|true|TRUE|yes|YES|on|ON)
			return 0
			;;
		0|false|FALSE|no|NO|off|OFF|"")
			return 1
			;;
		*)
			die "invalid DISCORDIA_CONFIGURE_SSH value: ${DISCORDIA_CONFIGURE_SSH} (expected 0/1/true/false)"
			;;
	esac
}

should_share_media() {
	case "${APP_SHARE_MEDIA}" in
		1|true|TRUE|yes|YES|on|ON)
			return 0
			;;
		0|false|FALSE|no|NO|off|OFF|"")
			return 1
			;;
		*)
			die "invalid APP_SHARE_MEDIA value: ${APP_SHARE_MEDIA} (expected 0/1/true/false)"
			;;
	esac
}

ensure_journald_volatile() {
	install -d -m 0755 /etc/systemd/journald.conf.d
	write_if_changed /etc/systemd/journald.conf.d/volatile.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
EOF

	systemctl restart systemd-journald
	log "journald volatile storage configured"
}

disable_timers() {
	local unit
	for unit in apt-daily.timer apt-daily-upgrade.timer man-db.timer; do
		systemctl disable "$unit" >/dev/null 2>&1 || true
		systemctl stop "$unit" >/dev/null 2>&1 || true
		log "disabled/stopped $unit"
	done
}

blacklist_wilc() {
	local conf="/etc/modprobe.d/no-wilc.conf"
	write_if_changed "$conf" <<'EOF'
# Prevent WILC SPI driver from auto-loading at boot.
# The driver is unstable (see WIFI-HELL.md) and wifi-setup.sh
# will modprobe it on demand when WiFi is explicitly requested.
blacklist wilc-spi
blacklist wilc_spi
EOF
	log "WILC driver blacklisted (load on demand via wifi-setup.sh)"
}

remove_fstab_mountpoint() {
	local mountpoint="$1"
	local tmp

	tmp="$(mktemp)"
	awk -v mp="$mountpoint" '
		($0 ~ /^[[:space:]]*#/ || NF < 2 || $2 != mp) { print }
	' /etc/fstab >"$tmp"

	if ! cmp -s /etc/fstab "$tmp"; then
		cat "$tmp" >/etc/fstab
		log "removed existing /etc/fstab entries for mountpoint $mountpoint"
	fi
	rm -f "$tmp"
}

remove_fstab_swaps() {
	local tmp

	tmp="$(mktemp)"
	awk '
		$0 ~ /^[[:space:]]*#/ { print; next }
		NF >= 3 && $3 == "swap" { next }
		{ print }
	' /etc/fstab >"$tmp"

	if ! cmp -s /etc/fstab "$tmp"; then
		cat "$tmp" >/etc/fstab
		log "removed swap entries from /etc/fstab"
	fi
	rm -f "$tmp"
}

ensure_fstab_opts() {
	local mountpoint="$1"
	local opts="$2"
	local tmp
	local rc=0

	tmp="$(mktemp)"
	if awk -v mp="$mountpoint" -v add="$opts" '
		function has_opt(existing, want, n, a, i) {
			n = split(existing, a, ",")
			for (i = 1; i <= n; i++) {
				if (a[i] == want) return 1
			}
			return 0
		}
		function merge_opts(existing, add, n, a, i) {
			n = split(add, a, ",")
			for (i = 1; i <= n; i++) {
				if (!has_opt(existing, a[i])) {
					existing = existing "," a[i]
				}
			}
			return existing
		}
		BEGIN { found = 0; changed = 0 }
		{
			if ($0 ~ /^[[:space:]]*#/ || NF < 4) {
				print
				next
			}
			if ($2 == mp) {
				found = 1
				newopts = merge_opts($4, add)
				if (newopts != $4) {
					$4 = newopts
					changed = 1
				}
			}
			print
		}
		END {
			if (!found) exit 2
			if (changed) exit 10
			exit 0
		}
	' /etc/fstab >"$tmp"; then
		log "fstab mount $mountpoint already contains opts: $opts"
	else
		rc=$?
		case "$rc" in
			2)
				warn "mountpoint $mountpoint not found in /etc/fstab; skipping option update ($opts)"
				;;
			10)
				cat "$tmp" >/etc/fstab
				log "updated /etc/fstab mount $mountpoint with opts: $opts"
				;;
			*)
				rm -f "$tmp"
				die "failed to update /etc/fstab for mountpoint $mountpoint (awk exit $rc)"
				;;
		esac
	fi
	rm -f "$tmp"
}

strip_managed_fstab_block() {
	local tmp

	tmp="$(mktemp)"
	awk -v begin="$FSTAB_BEGIN" -v end="$FSTAB_END" '
		$0 == begin { in_block = 1; next }
		$0 == end { in_block = 0; next }
		!in_block { print }
	' /etc/fstab >"$tmp"

	if ! cmp -s /etc/fstab "$tmp"; then
		cat "$tmp" >/etc/fstab
		log "removed existing managed fstab block"
	fi
	rm -f "$tmp"
}

ensure_managed_fstab_block() {
	if should_share_media; then
		cat >>/etc/fstab <<EOF

${FSTAB_BEGIN}
# Temporary filesystems in RAM
tmpfs  /tmp      tmpfs  defaults,noatime,nosuid,nodev,size=64M  0  0
tmpfs  /var/tmp  tmpfs  defaults,noatime,nosuid,nodev,size=32M  0  0

# External storage for persistent application data/logs (shared partition mode)
LABEL=${APP_DATA_LABEL}  /mnt/data  ext4  defaults,noatime,nofail  0  2
/mnt/data               /mnt/logs  none  bind,nofail               0  0
${FSTAB_END}
EOF
		log "wrote managed fstab block (shared media enabled)"
	else
		cat >>/etc/fstab <<EOF

${FSTAB_BEGIN}
# Temporary filesystems in RAM
tmpfs  /tmp      tmpfs  defaults,noatime,nosuid,nodev,size=64M  0  0
tmpfs  /var/tmp  tmpfs  defaults,noatime,nosuid,nodev,size=32M  0  0

# External storage for persistent application data/logs
LABEL=${APP_DATA_LABEL}  /mnt/data  ext4  defaults,noatime,nofail  0  2
LABEL=${APP_LOGS_LABEL}  /mnt/logs  ext4  defaults,noatime,nofail  0  2
${FSTAB_END}
EOF
		log "wrote managed fstab block"
	fi
}

log_external_mount_status() {
	local mountpoint="$1"
	local expected="$2"
	local source

	source="$(awk -v mp="$mountpoint" '
		$2 == mp { print $1; exit }
	' /proc/mounts)"

	if [ -n "$source" ]; then
		log "mount active: ${mountpoint} <- ${source}"
	else
		warn "mount missing: ${mountpoint} (expected ${expected}); using rootfs fallback until media is mounted"
	fi
}

configure_fstab() {
	[ -f /etc/fstab ] || die "/etc/fstab not found"

	ensure_fstab_opts "/" "noatime,nodiratime,commit=60"
	ensure_fstab_opts "/boot" "noatime,nodiratime"

	remove_fstab_swaps
	remove_fstab_mountpoint "/tmp"
	remove_fstab_mountpoint "/var/tmp"
	remove_fstab_mountpoint "/mnt/data"
	remove_fstab_mountpoint "/mnt/logs"
	strip_managed_fstab_block
	ensure_managed_fstab_block

	swapoff -a >/dev/null 2>&1 || true

	# Mountpoints must exist before mount -a on first setup run.
	install -d -m 0755 /mnt/data /mnt/logs

	# LABEL mounts may not exist yet; nofail in fstab allows this.
	if should_share_media; then
		mount -a >/dev/null 2>&1 || warn "mount -a reported errors; verify APPDATA label if expected (shared mode)"
		log_external_mount_status "/mnt/data" "LABEL=${APP_DATA_LABEL}"
		log_external_mount_status "/mnt/logs" "bind mount from /mnt/data"
	else
		mount -a >/dev/null 2>&1 || warn "mount -a reported errors; verify APPDATA/APPLOGS labels if expected"
		log_external_mount_status "/mnt/data" "LABEL=${APP_DATA_LABEL}"
		log_external_mount_status "/mnt/logs" "LABEL=${APP_LOGS_LABEL}"
	fi
}

ensure_data_layout() {
	install -d -m 0755 /mnt/data /mnt/logs
	install -d -m 0755 /mnt/data/powercon /mnt/data/powercon/transcripts /mnt/data/powercon/config /mnt/logs/powercon
	install -d -m 0755 /root/bin
	log "data directory layout ensured"
}

main() {
	local discordia_key=""

	require_root
	log "starting setup"

	ensure_pkg_install

	ensure_user "${DISCORDIA_USER}" "/bin/bash" "/home/${DISCORDIA_USER}" "sudo"
	if discordia_key="$(get_discordia_pubkey 2>/dev/null)"; then
		ensure_authorized_key "${DISCORDIA_USER}" "${discordia_key}"
		passwd -l "${DISCORDIA_USER}" >/dev/null 2>&1 || true
		log "password locked for user ${DISCORDIA_USER}"
	else
		warn "DISCORDIA_SSH_PUBKEY / DISCORDIA_SSH_KEY_FILE not provided; skipped discordia key install"
	fi

	if should_configure_ssh; then
		ensure_sshd_config
	else
		log "skipping SSH config in discordia-setup (DISCORDIA_CONFIGURE_SSH=${DISCORDIA_CONFIGURE_SSH}); use ./ssh-setup.sh"
	fi
	ensure_journald_volatile
	disable_timers
	blacklist_wilc
	configure_fstab
	ensure_data_layout

	log "setup complete"
	log "re-run anytime; script is designed to be idempotent"
}

main "$@"
