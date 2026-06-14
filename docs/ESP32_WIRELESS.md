# USB WiFi Setup

> **Update 2026-06-10:** WiFi can now be configured from the web dashboard
> (`odo-webd`, port 80): scan for networks, enter SSID + password, done — no
> shell needed. First-time setup happens over wired Ethernet (or read the IP
> off the TFT). The manual steps below remain valid as the fallback path.

> **Confirmed working (2026-06-11):** RTL8192EU USB adapter confirmed operational
> with the shipped Buildroot image. Board mines standalone over WiFi — boots,
> loads FPGA bitstream, connects to pool, and mines without any wired Ethernet.
> Module loads automatically via `linux-wifi.fragment`; `wpa_supplicant` config
> is written by `odo-webd` or manually at `/etc/wpa_supplicant.conf`.

---

## What You Need

- USB WiFi adapter (Realtek RTL8188/RTL8192, TP-Link, or similar)
- USB port on QMTECH board (or USB hub)
- Linux 6.6 LTS with WiFi drivers (included in Buildroot config)

## How It Works

**After Linux boots:**

```bash
# Check if WiFi device is detected
iwconfig
# or
iw dev

# Scan for networks
sudo wpa_cli scan
sudo wpa_cli scan_results

# Connect to a network
sudo wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf

# Get IP via DHCP
sudo dhclient wlan0

# Verify connection
ping 8.8.8.8
```

## Configuration File

Create `/etc/wpa_supplicant.conf`:

```ini
# WPA2 Personal (most common)
network={
    ssid="YourNetworkName"
    psk="YourPassword"
    key_mgmt=WPA-PSK
}

# WPA Enterprise (corporate)
# network={
#     ssid="EnterpriseSSID"
#     key_mgmt=WPA-EAP
#     eap=PEAP
#     identity="username"
#     password="password"
# }

# Open network (no password)
# network={
#     ssid="OpenNetwork"
#     key_mgmt=NONE
# }
```

## Systemd Service for Auto-Connect (Optional)

Create `/etc/systemd/system/wpa_supplicant.service`:

```ini
[Unit]
Description=WPA Supplicant
After=network-pre.target
Before=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/wpa_supplicant -u -s -O /run/wpa_supplicant
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable wpa_supplicant
sudo systemctl start wpa_supplicant
```

## Supported Adapters

Buildroot config includes drivers for:
- ✅ **Realtek RTL8188/RTL8192** (most common, ~$5) — confirmed working
- ✅ **TP-Link Archer T2U** (AC WiFi)
- ✅ **Ralink MT7612U** (optional, enable in config)
- ✅ **Broadcom BCM** (optional, enable in config)

## References

- WPA Supplicant: https://w1.fi/wpa_supplicant/
- WiFi Power Management: https://wiki.archlinux.org/title/Wireless_network_configuration
