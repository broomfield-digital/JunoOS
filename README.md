# DiscordiaOS

Setup scripts for TS-7800-v2 boards running Debian Stretch, designed for deployment with an OptConnect neo2 cellular gateway.

## Bootstrap

Connect the TS-7800-v2 to the OptConnect neo2 via ethernet, open a serial console, and run:

```bash
echo "nameserver 8.8.8.8" > /etc/resolv.conf
curl -fsSL https://raw.githubusercontent.com/broomfield-digital/DiscordiaOS/main/bootstrap.sh | bash
```

The `resolv.conf` line is required on a fresh board (no DNS out of the box). Bootstrap writes a permanent config as part of static eth0 setup.

This single command will:

1. Bring up eth0 with a temporary DHCP lease
2. Fix DNS resolution if needed
3. Clone this repo to `/root/DiscordiaOS`
4. Fix APT sources for Debian Stretch (archived mirrors)
5. Run full system setup (packages, users, fstab, journald, timers)
6. Configure static eth0 for the OptConnect (`192.168.1.11/24` via `192.168.1.90`)
7. Enable SSH

After bootstrap completes, look up the VPN-routable IP on the OptConnect Summit portal and connect via SSH.

## Manual eth0 Setup (Serial Console)

If eth0 is down or the board has lost its network config, use `eth0-setup.sh` from the serial console:

```bash
bash eth0-setup.sh
```

This brings up eth0 with the static OptConnect config (`192.168.1.11/24` via `192.168.1.90`), writes DNS, persists the config for reboot, and verifies connectivity.

If the repo isn't on the board yet, run the commands manually:

```bash
ip link set eth0 up                        # bring up the interface
ip addr add 192.168.1.11/24 dev eth0       # assign static IP
ip route add default via 192.168.1.90      # set gateway
echo "nameserver 8.8.8.8" > /etc/resolv.conf  # set DNS
ping -c 2 192.168.1.90                     # test gateway
ping -c 2 8.8.8.8                          # test internet
```

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `eth0` state is `DOWN` or `NO-CARRIER` | Cable disconnected or bad cable | Check cable, try the correct LAN port on the OptConnect |
| Can't ping `192.168.1.90` | Layer 2 issue — no link to OptConnect | Verify cable, check OptConnect LAN port, power-cycle OptConnect |
| Can ping `192.168.1.90` but not `8.8.8.8` | OptConnect not routing to internet | Check cellular status on Summit portal, power-cycle OptConnect |
| Can ping `8.8.8.8` but DNS fails | Missing `/etc/resolv.conf` | `echo "nameserver 8.8.8.8" > /etc/resolv.conf` |
| SSH connection refused from laptop | Board has no internet, or sshd not running | Fix eth0 first, then `systemctl status sshd` |
| `Network is unreachable` to VPN IP | Board isn't online through OptConnect yet | Fix eth0 + internet first, VPN IP only works once OptConnect is routing |

### Setting a root password (for SSH access)

```bash
echo 'root:root' | chpasswd
```

Change to a real password once you have remote access.

## Scripts

| Script | Purpose |
|--------|---------|
| `bootstrap.sh` | One-command setup orchestrator (the curl target) |
| `eth0-setup.sh` | Standalone eth0 + OptConnect setup for serial console |
| `debian-setup.sh` | Fixes Debian Stretch APT repos to use `archive.debian.org` |
| `discordia-setup.sh` | Full system setup: packages, users, fstab, journald, timers, data directories |
| `ssh-setup.sh` | Enables and configures sshd |
| `wifi-setup.sh` | Wi-Fi configuration (for local network access when needed) |
| `codex-setup.sh` | Installs runtime dependencies for ARMv7 Codex binaries |
| `codex.sh` | Codex execution wrapper with protocol-driven pilot mode |

## Environment Overrides

`bootstrap.sh` accepts these overrides:

| Variable | Default | Description |
|----------|---------|-------------|
| `ETH_IFACE` | `eth0` | Ethernet interface |
| `ETH_ADDRESS` | `192.168.1.11/24` | Static IP for OptConnect link |
| `ETH_GATEWAY` | `192.168.1.90` | OptConnect gateway |
| `ETH_DNS` | `192.168.1.90 8.8.8.8` | DNS servers |
| `DISCORDIA_REPO` | `https://github.com/broomfield-digital/DiscordiaOS.git` | Repo URL |
| `DISCORDIA_DIR` | `/root/DiscordiaOS` | Clone destination |

See individual scripts for additional overrides.

## Codex Pilot Mode

`codex.sh` supports a protocol-driven pilot mode where a single Codex session executes an autonomous control loop. A protocol file defines the operating rules (command interface, safety guardrails, cycle pattern) and the prompt specifies the objective.

```bash
# one-shot (existing behavior)
./codex.sh "Reply with exactly: connected"

# pilot mode: protocol file + objective
./codex.sh -p PROTOCOL.md "Run 3 cycles and report"
./codex.sh -p PROTOCOL.md -f objective.txt
```

The protocol file is read and prepended to the prompt. Codex reads the protocol, executes the objective autonomously, and exits when the objective is complete or on unrecoverable error.

See `PILOT_PROTOCOL_EXAMPLE.md` for a minimal working protocol that exercises the sense-act-verify cycle.
