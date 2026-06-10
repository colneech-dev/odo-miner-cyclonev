# Wireless Options: USB WiFi & ESP32 Integration

> **Update 2026-06-10:** WiFi can now be configured from the web dashboard
> (`odo-webd`, port 80): scan for networks, enter SSID + password, done — no
> shell needed. First-time setup happens over wired Ethernet (or read the IP
> off the TFT). The manual steps below remain valid as the fallback path.
> The ESP32 sections are historical: the display/control role is now filled
> by the SPI touch screen (docs/DISPLAY_WIRING.md) and the web dashboard.

This document covers:
1. **USB WiFi adapters** — Plug-and-play wireless networking
2. **ESP32 module integration** — Advanced setup with display + wireless gateway

---

## Option 1: USB WiFi Adapter (Immediate)

### What You Need
- USB WiFi adapter (Realtek RTL8188, TP-Link, or similar)
- USB port on QMTECH board (or USB hub)
- Linux 6.6 LTS with WiFi drivers (included in Buildroot config)

### How It Works

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

### Configuration File

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

### Systemd Service for Auto-Connect (Optional)

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

### Supported Adapters

Buildroot config includes drivers for:
- ✅ **Realtek RTL8188/RTL8192** (most common, ~$5)
- ✅ **TP-Link Archer T2U** (AC WiFi)
- ✅ **Ralink MT7612U** (optional, enable in config)
- ✅ **Broadcom BCM** (optional, enable in config)

---

## Option 2: ESP32 Module Integration (Advanced)

### Architecture

```
Mining Board (QMTECH Cyclone V)
    │
    ├─→ Ethernet (primary, always on)
    │
    └─→ UART/Serial ←→ ESP32 Module
                          │
                          ├─→ WiFi (secondary, when Ethernet unavailable)
                          └─→ Local Display (status, monitoring)
```

### Components Needed

1. **ESP32 Board** (e.g., ESP32-S3 or ESP32-C3)
2. **WiFi-enabled module** (e.g., Liligo T-Display S3 with WiFi)
3. **Serial cable** (USB-to-UART, or built-in USB on some ESP32 boards)
4. **Display** (optional, for local status monitoring)

### Serial Connection

**Physical wiring:**
```
QMTECH UART TX (pin X) ──→ ESP32 RX
QMTECH UART RX (pin Y) ←── ESP32 TX
QMTECH GND ──────────────→ ESP32 GND
```

**On the QMTECH board** (Linux side):
- Use `/dev/ttyS0` or `/dev/ttyUSB0` (depending on UART)
- Baud: 115200
- Settings: 8 data, 1 stop, no parity

### ESP32 Firmware Structure

The ESP32 acts as a **remote gateway**:

```c
// esp32_firmware.ino (pseudo-code structure)

#include <WiFi.h>
#include <WebServer.h>
#include <TFT_eSPI.h>

const char* SSID = "YourNetwork";
const char* PASSWORD = "YourPassword";
HardwareSerial miningBoard(1);  // Serial1 for UART communication

void setup() {
  miningBoard.begin(115200);
  WiFi.begin(SSID, PASSWORD);
  
  // Display status
  displayStatus("Connecting...");
}

void loop() {
  // Read from mining board via UART
  if (miningBoard.available()) {
    String data = miningBoard.readStringUntil('\n');
    
    // Parse mining stats
    uint32_t hashrate = parseHashrate(data);
    uint32_t shares = parseShares(data);
    
    // Update display
    updateDisplay(hashrate, shares);
    
    // Optionally: send to cloud/monitoring service
    // sendToMonitoring(hashrate, shares);
  }
  
  // Handle web requests (for remote status)
  handleWebRequests();
  
  delay(100);
}

void handleWebRequests() {
  // Serve JSON status to any HTTP client
  // GET /api/status → {"hashrate": 1800000, "shares": 42, ...}
}
```

### Communication Protocol

**Mining board → ESP32** (every 10 seconds):
```json
{
  "type": "status",
  "hashrate_khs": 1850,
  "shares_found": 42,
  "shares_rejected": 1,
  "pool": "pool.example.com:3333",
  "uptime_sec": 86400,
  "temp_c": 35
}
```

**ESP32 → Mining board** (commands):
```json
{
  "type": "command",
  "cmd": "stop"    // or "start", "restart", "reconfig"
}
```

### Web Dashboard (ESP32)

The ESP32 can host a simple HTTP interface:

```html
<!-- ESP32 serves this at http://esp32.local -->
<!DOCTYPE html>
<html>
<head>
  <title>odo-miner Status</title>
  <meta refresh="10">
</head>
<body>
  <h1>Mining Status</h1>
  <p>Hashrate: <span id="hashrate">-</span> KH/s</p>
  <p>Shares: <span id="shares">-</span></p>
  <p>Uptime: <span id="uptime">-</span></p>
  <p>Temperature: <span id="temp">-</span>°C</p>
  
  <button onclick="fetch('/api/cmd?action=stop')">Stop Mining</button>
  <button onclick="fetch('/api/cmd?action=start')">Start Mining</button>
  
  <script>
    fetch('/api/status').then(r => r.json()).then(data => {
      document.getElementById('hashrate').textContent = data.hashrate_khs;
      document.getElementById('shares').textContent = data.shares_found;
      document.getElementById('uptime').textContent = data.uptime_sec;
      document.getElementById('temp').textContent = data.temp_c;
    });
  </script>
</body>
</html>
```

---

## Comparison: USB vs ESP32

| Feature | USB WiFi | ESP32 Module |
|---------|----------|--------------|
| **Cost** | $5-15 | $20-50 |
| **Setup** | Plug-and-play | Requires programming |
| **WiFi** | Yes (standard) | Yes (standard) |
| **Display** | No | Yes (optional) |
| **Remote monitoring** | SSH only | Web dashboard |
| **Time to implement** | 30 min | 2-3 hours |
| **Complexity** | Simple | Moderate |
| **Reliability** | High | High (if coded well) |
| **Best for** | Quick WiFi fallback | Full remote management |

---

## Integration Timeline

### Phase 1 (Immediate): USB WiFi
1. ✅ Add USB WiFi drivers to Buildroot (DONE)
2. Plug in USB adapter after Linux boots
3. Use `wpa_supplicant` to connect
4. Optional: Create systemd service for auto-connect

### Phase 2 (Optional): ESP32 Gateway
1. Source ESP32 module (Liligo T-Display S3 recommended)
2. Write ESP32 firmware (100 lines)
3. Add serial communication library to miner daemon
4. Flash ESP32 and connect via UART
5. Test web dashboard

### Phase 3 (Future): Cloud Monitoring
1. Add WiFi reporting to mining daemon
2. Send stats to monitoring service (Grafana, etc.)
3. Set up alerts for pool disconnects

---

## Getting Started

**For USB WiFi (right now):**
- Just plug in a USB WiFi adapter after the board boots
- Buildroot now includes all drivers
- Use `wpa_supplicant` as shown above

**For ESP32 (later):**
- Order a Liligo T-Display S3 or ESP32-C3 (~$25)
- Use the firmware template above
- Integrate into mining daemon startup

---

## References

- WPA Supplicant: https://w1.fi/wpa_supplicant/
- ESP32 Arduino: https://docs.espressif.com/projects/arduino-esp32/
- Liligo T-Display S3: https://github.com/Xinyuan-LilyGO/T-Display-S3
- WiFi Power Management: https://wiki.archlinux.org/title/Wireless_network_configuration

