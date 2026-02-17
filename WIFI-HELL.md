# WiFi on the TS-7800-v2: A Descent Through the Circles

*"Abandon all throughput, ye who enter here."*

Dante Alighieri mapped nine circles of Hell, each worse than the last, each a punishment exquisitely fitted to the sin. The WILC3000 WiFi module on the TS-7800-v2 offers a similar taxonomy. We have descended through several circles. We document them here as a warning to those who follow.

## The Hardware

The TS-7800-v2 includes a **Microchip WILC3000** WiFi/BT module connected via SPI. In theory, this provides 802.11 b/g/n connectivity. In practice, it provides a structured curriculum in suffering.

---

## First Circle: Limbo (The Boot Spam)

*"Here sighs, lamentations and loud wailings resounded through the starless air."*

Before you even attempt WiFi, the WILC driver punishes you for its mere existence. On a stock Debian image, the kernel auto-loads `wilc_spi` via device tree binding at every boot, vomiting initialization messages across the serial console:

```
[   17.020082] BT initialize timeout
[   17.130082] Device already up. request source is Wifi
[   17.135155] WILC_SPI spi0.3 wlan0: INFO [wilc_init_host_int]Host[ede28000][ede29500]
[   17.150087] WILC_SPI spi0.3 wlan0: INFO [wilc_mac_open]*** re-init ***
[   17.174878] WILC_SPI spi0.3 wlan0: INFO [init_chip]Bootrom sts = c
[   17.234066] wilc_handle_isr,>> UNKNOWN_INTERRUPT - 0x00000000
```

This wall of text arrives precisely as the login prompt appears, clobbering whatever you're trying to type. You enter your username. Half of it lands in the login field; the other half is swallowed by kernel messages scrolling past. You type your password blind, hoping the interrupt storm has subsided. It hasn't. Login fails. You try again. More WILC messages. The module isn't even being *used* — it's just announcing its existence, loudly, to no one.

The standard `blacklist` directive in `/etc/modprobe.d/` does not help. The device tree binding bypasses modprobe's alias matching. Only the `install` override is strong enough:

```bash
# /etc/modprobe.d/no-wilc.conf
install wilc-spi /bin/true
install wilc_spi /bin/true
```

This tells modprobe to run `/bin/true` (a no-op) instead of loading the driver, regardless of what triggers the load. `discordia-setup.sh` writes this automatically. When WiFi is actually wanted, `wifi-setup.sh` uses `modprobe --ignore-install` to bypass the override.

Dante placed virtuous pagans in Limbo — souls guilty of no sin except being born in the wrong place. The WILC module commits no sin except existing in the device tree. Its punishment is to be silenced at boot, forever calling out to an audience that has stopped listening.

---

## Second Circle: The Unicast Tempest

*"The hellish storm, which never rests, sweeps the spirits along with its rapine."*

You have silenced the boot spam. You have typed your credentials at the login prompt unmolested. You have summoned the courage to actually use WiFi. The WILC SPI driver (`wilc-spi`) rewards your optimism with deeply unsettling behavior:

1. **Association succeeds** - The module happily associates with your AP, completes WPA2 handshake, and obtains a DHCP lease via broadcast. Everything looks perfect in `wpa_cli status`.

2. **Unicast traffic fails** - Immediately after, unicast packets vanish into the void. ARP requests go unanswered. Pings return "Destination Host Unreachable". Your SSH session freezes mid-keystroke.

3. **DHCP worked though** - The maddening part: DHCP (broadcast) worked fine. The module *can* transmit. It just... doesn't, for unicast. Sometimes. Until you cycle the connection.

4. **The "fix"** - Running `wifi-setup.sh` again (which kills wpa_supplicant, removes the control socket, and reconnects) *sometimes* restores connectivity. For a while. Until it freezes again.

5. **Power save is a lie** - Disabling power save (`iw wlan0 set power_save off`) helps slightly but doesn't solve the fundamental instability.

6. **Boot is hopeless** - Attempts to make this work automatically at boot (systemd services, timers, delayed fixups, reconnect cycles) all failed. The driver seems allergic to systemd.

## Third Circle: The Futile Rites

*"In the third circle I arrive, of rain eternal, cursed, cold, and heavy."*

We tried everything. Each attempt worked once, then never again, like prayers answered only to prove they were heard and denied:

- Disabling power management before connection
- Disabling power management after connection
- Reassociating after DHCP
- Full reconnect cycles at boot
- Delayed fixup timers 30 seconds after boot
- Praying (see above)

---

## Fourth Circle: The Sisyphean Connection

*"Here I saw people, more than elsewhere, on both sides, howling, rolling weights by force of chest."*

After boot, connect to the board via **serial console** and run:

```bash
~/DiscordiaOS/wifi-setup.sh Marmot WhiteFox
```

This establishes a WiFi connection that works *for a while*. Expect:
- ~15-25ms latency when working
- Occasional 50% packet loss
- Random freezes requiring reconnection
- Git operations to corrupt repos mid-transfer (see `OS-HELL.md`, First Circle)

---

## Recommendations

1. **Use ethernet when possible** - The OptConnect cellular gateway on eth0 is reliable. The WILC is not.

2. **Consider a USB WiFi dongle** - See below for recommended adapters.

3. **Keep expectations low** - This is development/debug access only. Do not rely on WILC for anything important.

4. **Have serial console ready** - You will need it.

## Recommended USB WiFi Adapters

If you need reliable WiFi on the TS-7800-v2, bypass the WILC entirely with a USB adapter. Look for these chipsets with mature Linux drivers:

### Atheros (ath9k_htc) - Best Choice

The `ath9k_htc` driver is mainline, stable, and battle-tested. Look for:

- **TP-Link TL-WN722N v1** (not v2/v3 - those use different chips)
- **Atheros AR9271** based adapters

```bash
# Check if detected
lsusb | grep -i atheros
dmesg | grep ath9k
```

### Ralink/MediaTek (rt2800usb)

Another solid mainline driver:

- **TP-Link TL-WN727N**
- **Ralink RT5370** based adapters (cheap, common)

```bash
# Check if detected
lsusb | grep -i ralink
dmesg | grep rt2800
```

### Realtek (rtl8192cu) - Acceptable

Works but Realtek's Linux support is historically mediocre:

- **TP-Link TL-WN823N**
- **Realtek RTL8192CU** based adapters

```bash
# Check if detected
lsusb | grep -i realtek
dmesg | grep rtl8192
```

### What to Avoid

- **Realtek RTL8188** - Driver issues, avoid
- **Any adapter requiring out-of-tree drivers** - If it doesn't work with mainline kernel, it's a maintenance nightmare
- **WiFi 6 (802.11ax) adapters** - Overkill, and driver support is immature
- **Anything without clear Linux chipset info** - "Works with Linux" marketing is often lies

### Installation

Most USB adapters with the above chipsets should "just work" on Debian Stretch:

```bash
# Plug in adapter, then:
ip link show  # Should see wlan1 or similar
iwconfig      # Should show the new interface
```

Then configure with wpa_supplicant as usual, substituting the USB interface name for `wlan0`.

## Boot Services (Disabled — Escaped from the Sixth Circle)

The following services exist but are disabled because they don't work reliably:

```bash
# These are OFF by default now
systemctl disable discordia-wifi-ensure.service
systemctl disable discordia-wifi-fixup.timer
```

## Fifth Circle: Root Cause Analysis

*"Within these tombs are heretics, with all their followers."*

**Is the driver flaky because it can't handle modern routers?**

Unlikely. The symptoms don't fit:

- **Association works** - Modern router protocols are fine
- **WPA2 handshake completes** - Encryption negotiation succeeds
- **DHCP works** - Broadcast packets flow both directions
- **Unicast fails** - Only direct device-to-device packets break

If it were router incompatibility, association or WPA2 would fail. This looks like a **driver bug in the unicast TX/RX path** - the code that handles "send this packet to this specific MAC address" vs "broadcast to everyone."

More likely culprits:

1. **SPI timing issues** - The WILC3000 connects via SPI, which is timing-sensitive. Marginal signals cause data corruption or missed packets.

2. **Interrupt handling** - We observed `UNKNOWN_INTERRUPT - 0x00000000` in dmesg. The driver is receiving interrupts it doesn't recognize. This is not confidence-inspiring.

3. **Firmware bugs** - The WILC3000 runs internal firmware (`wilc3000_wifi_firmware`). Microchip's embedded firmware quality is... variable.

4. **Power management lies** - Even with power_save "off" at the Linux level, the chip may be doing its own internal power management. The driver's power management hooks may not fully control chip behavior.

5. **Driver immaturity** - The WILC driver originated in the kernel staging tree circa 2019 and never fully graduated to mainline. Staging drivers are explicitly "not ready for production." This one proves it.

## The Verdict

*"Through me you enter into the city of woes. Through me you enter into eternal pain. Through me you enter among the lost."*

The WILC3000 driver is not ready for production use. The hardware may be fine; the Linux driver is not. This module should be treated as decorative until Microchip improves driver quality.

Dante eventually climbed out of Hell and saw the stars again. We use ethernet.

---

## Glossary for Software Engineers

**AP (Access Point)** - The WiFi router/base station that wireless clients connect to. Your home router is an AP.

**ARP (Address Resolution Protocol)** - How devices on a local network discover each other's MAC addresses. When your device wants to talk to 10.0.0.1, it broadcasts "who has 10.0.0.1?" and the router replies with its MAC address. If ARP fails, no communication is possible even with a valid IP.

**BSSID** - The MAC address of the access point. Used to uniquely identify an AP (since multiple APs can share the same SSID).

**DHCP (Dynamic Host Configuration Protocol)** - How devices automatically get an IP address when joining a network. Your device broadcasts "I need an IP!" and the router responds with an address, subnet mask, gateway, and DNS servers.

**Broadcast vs Unicast** - Broadcast sends packets to everyone on the network (like shouting in a room). Unicast sends to one specific device (like a phone call). DHCP uses broadcast; SSH uses unicast. Our WILC driver handles broadcast fine but chokes on unicast.

**MAC Address** - A hardware address burned into every network interface (like `9e:95:6e:d1:ba:c4`). Used for local network communication. Unlike IP addresses, MAC addresses don't change.

**Power Save** - WiFi chips can sleep between transmissions to save battery. On embedded boards with flaky drivers, this can cause connectivity issues. Disable it with `iw wlan0 set power_save off`.

**SPI (Serial Peripheral Interface)** - A hardware bus for connecting chips on a circuit board. The WILC3000 WiFi module connects to the CPU via SPI rather than USB or PCIe. SPI is simple but the drivers are often less mature.

**SSID (Service Set Identifier)** - The name of a WiFi network (like "Marmot"). What you see when scanning for networks.

**wpa_supplicant** - The Linux daemon that handles WiFi authentication and connection. It negotiates with the AP, handles WPA2 encryption, and maintains the connection. Configured via `/etc/wpa_supplicant/wpa_supplicant-*.conf`.

**WPA/WPA2/WPA3 (WiFi Protected Access)** - Encryption standards for WiFi. WPA2-PSK (Pre-Shared Key) is the common "password-protected WiFi" most people use. The WILC driver supports WPA2.

**wpa_cli** - Command-line tool to interact with wpa_supplicant. Useful commands:
  - `wpa_cli -i wlan0 status` - Show connection state
  - `wpa_cli -i wlan0 reassociate` - Force reconnection
  - `wpa_cli -i wlan0 scan_results` - Show nearby networks

**iw** - Low-level WiFi configuration tool. Unlike `ifconfig` (which handles IP), `iw` handles WiFi-specific settings like power management, channel, signal strength.

**ifup/ifdown** - Traditional Debian commands to bring network interfaces up or down, reading config from `/etc/network/interfaces`.

**NetworkManager (nmcli)** - A higher-level network management daemon common on desktop Linux. Handles WiFi, VPN, etc. with automatic connection management. The TS-7800-v2 doesn't use it; we fall back to wpa_supplicant directly.
