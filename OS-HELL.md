# Debian Stretch on the TS-7800-v2: A Separate Damnation

*"Through me you enter into the city of woes."*

The WILC3000 WiFi module has its own hell (see `WIFI-HELL.md`). But the operating system itself — Debian 9 "Stretch" on an ARMv5 board with 1GB of RAM — offers its own descent. The OptConnect cellular gateway has served reliably for years on other platforms. The sins documented here belong to this OS alone.

---

## First Circle: The Wrathful Repository

*"Fixed in the slime they say, 'We were sullen in the sweet air.'"*

Every session, `git pull` leaves behind empty object files. The repository is dead on arrival:

```
error: object file .git/objects/fc/f65a1f0a10b56cec5f5d35dbd5eb9363c845b0 is empty
fatal: loose object fcf65a1f0a10b56cec5f5d35dbd5eb9363c845b0 (stored in
  .git/objects/fc/f65a1f0a10b56cec5f5d35dbd5eb9363c845b0) is corrupt
```

Not recoverable. `git fsck` confirms the damage; it does not repair it. Nuke and re-clone. Every time.

### The Root Cause

We found it. The rootfs is ext4 on a 3.59 GiB eMMC (`mmcblk0p1`). The setup scripts were mounting it with `commit=60` — telling ext4 to defer metadata sync for up to **60 seconds**. Meanwhile, Debian Stretch ships git 2.11 (2016), which does not fsync object writes. Modern git (2.36+) added `core.fsync` to force data to disk; git 2.11 trusts the kernel to flush when it's ready.

The sequence of destruction:

1. `git pull` receives objects and writes them to `.git/objects/`
2. Git creates each file and writes compressed object data
3. The kernel accepts the write into its page cache — the data exists only in RAM
4. Git exits, satisfied. The data has not reached the eMMC.
5. Up to 60 seconds may pass before ext4 flushes to disk
6. Anything that interrupts the flush — a reboot, a power glitch, a kernel hiccup from a WILC driver firing `UNKNOWN_INTERRUPT` — kills the buffered data
7. On next boot, ext4 journal recovery preserves the **inodes** (the files exist) but the **data blocks** were never written (the files are empty)

The `dmesg` on every boot confirmed the damage:

```
EXT4-fs (mmcblk0p1): recovery complete
```

Journal recovery. Every boot. The filesystem was never cleanly unmounted because writes were always in flight, lazily deferred by a 60-second commit window.

### The Fix

Drop `commit=60` from the rootfs mount options. The ext4 default is `commit=5`, which is fine for eMMC — the wear concern that motivated the longer interval was misplaced. eMMC has its own wear-leveling controller; it is not raw NAND. Five-second commit intervals do not meaningfully reduce eMMC lifespan. Sixty-second commit intervals destroy git repositories.

`discordia-setup.sh` no longer sets `commit=60`. To apply immediately without rebooting:

```bash
mount -o remount,commit=5 /
```

### Until the Fix is Verified

You will remain intimately familiar with:

```bash
rm -rf ~/DiscordiaOS
git clone https://github.com/broomfield-digital/DiscordiaOS.git ~/DiscordiaOS
```

Shallow clones reduce exposure by minimizing transfer size:

```bash
git clone --depth 1 https://github.com/broomfield-digital/DiscordiaOS.git ~/DiscordiaOS
```

Dante's sinners push their boulders uphill for eternity. We push our repos. Perhaps now, the boulder stays.

---

## Second Circle: The IPv6 Void

*"Into the eternal darkness, into fire and into ice."*

Debian Stretch's APT prefers IPv6 when AAAA DNS records exist. `archive.debian.org` publishes AAAA records. The OptConnect cellular gateway does not route IPv6. The result: `apt-get update` opens a connection to an IPv6 address, waits for a response that will never come, and hangs indefinitely. No timeout. No fallback. Just silence.

```
0% [Connecting to archive.debian.org (2a04:4e42:200::644)]
```

Forever.

The fix is simple but must be applied before any apt operation:

```bash
# /etc/apt/apt.conf.d/99force-ipv4
Acquire::ForceIPv4 "true";
```

`debian-setup.sh` and `discordia-setup.sh` both write this automatically. But if you're bootstrapping a fresh board by hand and forget — you'll stare at that `0% [Connecting]` line, wondering if the archive is slow, if your network is down, if the mirror is overloaded. It is none of those things. It is IPv6. It is always IPv6.

---

## Third Circle: The Missing Resolver

*"A great storm of putrefaction falls incessantly on the ground."*

Fresh Debian Stretch boards boot with an empty `/etc/resolv.conf`. No nameservers. No DNS. The board obtains an IP via DHCP, but the `dns-nameservers` directive in `/etc/network/interfaces` only populates `/etc/resolv.conf` if the `resolvconf` package is installed. It isn't.

Every network operation that requires a hostname — `curl`, `git clone`, `apt-get update`, `ping github.com` — fails silently or with an opaque error:

```
curl: (6) Could not resolve host: raw.githubusercontent.com
```

You have an IP address. You have a default route. You can ping `8.8.8.8`. But you cannot reach anything by name. The board is connected to the internet and simultaneously cut off from it.

The bootstrap requires DNS to fetch the bootstrap. The bootstrap is what fixes DNS. This is the ouroboros of embedded provisioning. The only escape is a manual incantation before anything else:

```bash
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

`bootstrap.sh` writes a permanent `/etc/resolv.conf` as part of static eth0 configuration. But someone has to type that first line, on a serial console, from memory, on a board that offers no hints about what's wrong.

---

## Fourth Circle: The Locale Purgatory

*"Here I saw people, more than elsewhere, howling."*

The default locale on Debian Stretch is `ANSI_X3.4-1968`. This is not UTF-8. `tmux` refuses to start:

```
tmux: need UTF-8 locale (LC_CTYPE) but have ANSI_X3.4-1968
```

`tmux` is the only way to get multiple shells over a single serial console connection. Without it, you have one terminal. One. You cannot run a long operation and check something else. You cannot tail a log while editing a file. You are trapped in a single pane of glass, watching `apt-get` crawl, unable to do anything but wait.

The fix:

```bash
export LC_ALL=C.UTF-8
```

`discordia-setup.sh` adds this to `/root/.bashrc`. But it only takes effect on the next login. On the current session — the one where you just discovered the problem — you must type it yourself, from memory, knowing that `C.UTF-8` is the magic string and not `en_US.UTF-8` (which doesn't exist on this board) or `utf8` (which isn't a valid locale name).

---

*We have not yet reached the bottom.*
