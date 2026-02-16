# WiFi on the TS-7800-v2: A Cautionary Tale

## The Hardware

The TS-7800-v2 includes a **Microchip WILC3000** WiFi/BT module connected via SPI. In theory, this provides 802.11 b/g/n connectivity. In practice, it provides frustration.

## The Horror

The WILC SPI driver (`wilc-spi`) exhibits deeply unsettling behavior:

1. **Association succeeds** - The module happily associates with your AP, completes WPA2 handshake, and obtains a DHCP lease via broadcast. Everything looks perfect in `wpa_cli status`.

2. **Unicast traffic fails** - Immediately after, unicast packets vanish into the void. ARP requests go unanswered. Pings return "Destination Host Unreachable". Your SSH session freezes mid-keystroke.

3. **DHCP worked though** - The maddening part: DHCP (broadcast) worked fine. The module *can* transmit. It just... doesn't, for unicast. Sometimes. Until you cycle the connection.

4. **The "fix"** - Running `wifi-setup.sh` again (which kills wpa_supplicant, removes the control socket, and reconnects) *sometimes* restores connectivity. For a while. Until it freezes again.

5. **Power save is a lie** - Disabling power save (`iw wlan0 set power_save off`) helps slightly but doesn't solve the fundamental instability.

6. **Boot is hopeless** - Attempts to make this work automatically at boot (systemd services, timers, delayed fixups, reconnect cycles) all failed. The driver seems allergic to systemd.

## What We Tried

- Disabling power management before connection
- Disabling power management after connection
- Reassociating after DHCP
- Full reconnect cycles at boot
- Delayed fixup timers 30 seconds after boot
- Praying

## What "Works"

After boot, connect to the board via **serial console** and run:

```bash
~/DiscordiaOS/wifi-setup.sh Marmot WhiteFox
```

This establishes a WiFi connection that works *for a while*. Expect:
- ~15-25ms latency when working
- Occasional 50% packet loss
- Random freezes requiring reconnection
- Git operations to corrupt repos mid-transfer

## Recommendations

1. **Use ethernet when possible** - The OptConnect cellular gateway on eth0 is rock solid by comparison.

2. **Consider a USB WiFi dongle** - Adapters using `ath9k` or `rtl8192` chipsets are far more reliable on Linux.

3. **Keep expectations low** - This is development/debug access only. Do not rely on WILC for anything important.

4. **Have serial console ready** - You will need it.

## Boot Services (Disabled)

The following services exist but are disabled because they don't work reliably:

```bash
# These are OFF by default now
systemctl disable discordia-wifi-ensure.service
systemctl disable discordia-wifi-fixup.timer
```

## The Verdict

The WILC3000 driver is not ready for production use. The hardware may be fine; the Linux driver is not. This module should be treated as decorative until Microchip improves driver quality.

We remain disturbed.

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
