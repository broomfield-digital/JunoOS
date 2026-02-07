# DiscordiaOS

Setup scripts for TS-7800-v2 boards running Debian Stretch, designed for deployment with an OptConnect neo2 cellular gateway.

## Bootstrap

Connect the TS-7800-v2 to the OptConnect neo2 via ethernet, open a serial console, and run:

```bash
curl -fsSL https://raw.githubusercontent.com/broomfield-digital/DiscordiaOS/main/bootstrap.sh | bash
```

Or with wget:

```bash
wget -qO- https://raw.githubusercontent.com/broomfield-digital/DiscordiaOS/main/bootstrap.sh | bash
```

This single command will:

1. Bring up eth0 with a temporary DHCP lease
2. Fix DNS resolution if needed
3. Clone this repo to `/root/DiscordiaOS`
4. Fix APT sources for Debian Stretch (archived mirrors)
5. Run full system setup (packages, users, fstab, journald, timers)
6. Configure static eth0 for the OptConnect (`192.168.1.11/24` via `192.168.1.90`)
7. Enable SSH

After bootstrap completes, look up the VPN-routable IP on the OptConnect Summit portal and connect via SSH.

## Scripts

| Script | Purpose |
|--------|---------|
| `bootstrap.sh` | One-command setup orchestrator (the curl target) |
| `debian-setup.sh` | Fixes Debian Stretch APT repos to use `archive.debian.org` |
| `discordia-setup.sh` | Full system setup: packages, users, fstab, journald, timers, data directories |
| `ssh-setup.sh` | Enables and configures sshd |
| `wifi-setup.sh` | Wi-Fi configuration (for local network access when needed) |
| `codex-setup.sh` | Installs runtime dependencies for ARMv7 Codex binaries |

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
