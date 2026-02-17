# Debian Stretch on the TS-7800-v2: A Separate Damnation

*"Through me you enter into the city of woes."*

The WILC3000 WiFi module has its own hell (see `WIFI-HELL.md`). But the operating system itself — Debian 9 "Stretch" on an ARMv5 board with 1GB of RAM — offers its own descent. The OptConnect cellular gateway has served reliably for years on other platforms. The sins documented here belong to this OS alone.

---

## First Circle: The Wrathful Repository

*"Fixed in the slime they say, 'We were sullen in the sweet air.'"*

Git objects are written to disk in a sequence: first the data, then the index. On this board, `git pull` routinely dies partway through writing a packfile or loose object. The result is a `.git/objects` directory containing empty or truncated files:

```
error: object file .git/objects/fc/f65a1f0a10b56cec5f5d35dbd5eb9363c845b0 is empty
fatal: loose object fcf65a1f0a10b56cec5f5d35dbd5eb9363c845b0 (stored in
  .git/objects/fc/f65a1f0a10b56cec5f5d35dbd5eb9363c845b0) is corrupt
```

This is not recoverable. `git fsck` will confirm the corruption; it will not fix it. `git reflog` references objects that no longer exist. The repository is dead. This happens every session. Not sometimes. Every time.

The network is not at fault. The OptConnect cellular link has been reliable for years on other hardware. The corruption happens over ethernet — the same link that serves SSH sessions without issue. Something between the kernel's TCP stack, the filesystem, and git's object-writing path is silently truncating data. Loose objects arrive as zero-byte files. Packfiles end mid-stream. The kernel reports no errors. The filesystem reports no errors. Git discovers the damage only when it tries to read what it thought it wrote.

Likely culprits:

1. **Filesystem write ordering** — The rootfs runs on NAND flash. Write barriers, sync behavior, and the flash translation layer may conspire to report writes as complete before data reaches stable storage. A poorly-timed flush (or lack of one) leaves empty object files.

2. **Memory pressure** — With 1GB of RAM, git's packfile operations can push the system into swap or OOM territory. If the kernel kills a git subprocess mid-write, the partially-written object persists as a corrupt file.

3. **Ancient git** — Debian Stretch ships git 2.11 (2016). Modern git has substantially improved its atomic write paths and fsync behavior. The version on this board predates those fixes.

4. **ARMv5 kernel bugs** — The TS-7800-v2 runs a vendor-patched kernel. Vendor kernels on embedded ARM boards are where filesystem bugs go to retire, undiscovered and unfixed.

You will become intimately familiar with:

```bash
rm -rf ~/DiscordiaOS
git clone https://github.com/broomfield-digital/DiscordiaOS.git ~/DiscordiaOS
```

Shallow clones reduce exposure by minimizing transfer size:

```bash
git clone --depth 1 https://github.com/broomfield-digital/DiscordiaOS.git ~/DiscordiaOS
```

When corruption strikes, don't bother with heroic recovery. Just nuke and re-clone. Accept the cycle. Dante's sinners push their boulders uphill for eternity. You will push your repos.

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
