# Deployment & Runtime Configuration

Post-build configuration, pool setup, runtime management, and troubleshooting for the
odo-miner Cyclone V board.

> **Init system: BusyBox**, not systemd. `systemctl` / `supervisorctl` are not
> available. Services are `/etc/init.d/Sxx` scripts started by BusyBox init. Do not
> follow any systemd recipes below — they are from a superseded design.

---

## SD Card Layout

```
mmcblk0p1  FAT32  256 MiB   /mnt/fat — zImage, socfpga_cyclone5_qmtech_odo.dtb,
                              boot.scr, fpga.rbf
mmcblk0p2  ext4   ~8 GiB    rootfs (mounted as /)
mmcblk0p3  0xA2   16 MiB    u-boot-with-spl.sfp (raw, no filesystem)
```

U-Boot reads `fpga.rbf` from the FAT partition, programs the FPGA, enables HPS↔FPGA
bridges, then boots Linux. **Never copy the bitstream to the ext4 partition** — U-Boot
cannot reach it.

---

## Services (BusyBox init)

Init scripts in `/etc/init.d/`, started in alphabetical order:

| Script | What it does |
|---|---|
| `S45wifi` | Brings up wlan0 via wpa_supplicant + BusyBox `udhcpc` (if `/etc/wpa_supplicant.conf` exists) |
| `S50sshd` | Starts OpenSSH daemon |
| `S90odod` | Starts the miner daemon — see below |
| `S91epochcron` | Cron job that calls `epoch-update.sh` every hour to check for a staged epoch `.rbf` |
| `S95odoui` | Starts `odo-ui` (framebuffer touch dashboard) |
| `S96odowebd` | Starts `odo-webd` (local web dashboard on port 80) |

To restart a service manually:

```bash
/etc/init.d/S90odod stop
/etc/init.d/S90odod start
```

---

## Miner Daemon (`S90odod`)

The init script reads `/etc/odod.conf` (sourced as `KEY=value`), then launches
`/usr/bin/odo-miner-pipe-uio` (UIO/IRQ backend) with fallback to
`/usr/bin/odo-miner-pipe` if the UIO device is not present.

### `/etc/odod.conf` format

```sh
# Mining pool
ODOD_POOL_HOST=pool.example.com
ODOD_POOL_PORT=3333
ODOD_WORKER=your_dgb_address.worker_name
ODOD_PASSWORD=x

# Optional second pool (failover)
ODOD_POOL_HOST2=pool2.example.com
ODOD_POOL_PORT2=3333

# Optional tuning
ODOD_WATCHDOG=1          # set to 1 to enable reboot-on-hang watchdog
```

**Never put a real wallet address in the repo.** Keep `/etc/odod.conf` on the board
only.

### Runtime status

The daemon writes `/run/odod/status.json` every ~5 s:

```bash
cat /run/odod/status.json
# {
#   "hashrate_mhs": 26.0,
#   "shares_accepted": 42,
#   "shares_rejected": 0,
#   "epoch": 1782432000,
#   "uptime_s": 3600,
#   "temp_c": 45.2,
#   "fan_duty_pct": 50,
#   "backend": "uio",
#   ...
# }
```

`backend: "uio"` confirms interrupt-driven found-nonce handoff is active.

---

## Pool Configuration

Point the miner at a DGB OdoCrypt pool by editing `/etc/odod.conf`:

```sh
ODOD_POOL_HOST=<pool_host>
ODOD_POOL_PORT=<port>
ODOD_WORKER=<your_dgb_address>.<worker_label>
ODOD_PASSWORD=x
```

Restart the daemon after any change:

```bash
/etc/init.d/S90odod stop && /etc/init.d/S90odod start
```

For testnet validation (1-day epochs — fastest way to verify the full epoch-roll path):

```sh
ODOD_POOL_HOST=<testnet_pool>
ODOD_POOL_PORT=<testnet_port>
ODOD_WORKER=<testnet_address>.<worker>
```

---

## WiFi Setup

The board uses a USB RTL8xxx WiFi adapter (rtl8xxxu kernel module). USB autosuspend
is disabled at boot to prevent the adapter from dropping.

Configure via the web dashboard (recommended — handles wpa_supplicant correctly) or
manually:

```bash
# Manual: wpa_supplicant ctrl socket is /tmp/wpa_supplicant (NOT /var/run)
wpa_passphrase "YourSSID" "YourPassword" > /etc/wpa_supplicant.conf

# Restart the wifi init script to apply
/etc/init.d/S45wifi stop
/etc/init.d/S45wifi start
```

Verify:

```bash
ip addr show wlan0          # should have an inet address
ping -c3 8.8.8.8 -I wlan0  # basic connectivity
```

---

## SSH Access

SSH daemon starts at boot (`S50sshd`). Key-based login is configured in
`linux/overlay/root/.ssh/authorized_keys` — this file ships as an empty template; add
your public key before building the image, or copy it over after first boot:

```bash
# From the build machine (after first Ethernet boot):
ssh-copy-id root@<board-ip>
```

Default credentials: `root` / `odo-miner`. **Change the password on first boot:**

```bash
passwd
```

---

## FPGA Epoch Updates

The pipelined core bakes the OdoCrypt epoch key into FPGA LUTs at compile time.
Epoch changes (~every 10 days) require a new bitstream. The automated flow:

1. **Off-board** (Windows): `scripts/epoch_build_deploy.ps1 -EpochKey <new_key>`
   compiles and stages the new `.rbf` on the board's FAT partition as
   `fpga_staged.rbf`.
2. **On-board**: `epoch-update.sh` (run hourly by `S91epochcron`) detects the staged
   file, verifies the epoch is close enough to apply, copies it to `fpga.rbf`, and
   reboots.

Manual apply (if automated staging fails):

```bash
# On the board — mount FAT, copy new bitstream, reboot
mount /dev/mmcblk0p1 /mnt/fat
cp /tmp/new_epoch.rbf /mnt/fat/fpga.rbf
sync && umount /mnt/fat && reboot
```

**Do NOT use `/sys/class/fpga_manager/fpga0/firmware` to reload at runtime** — the
kernel bridge driver (`fpga_bridge`) is not compiled into this image. Runtime reload
does not work; reboot is the only supported mechanism.

---

## Web Dashboard (`odo-webd`)

`odo-webd` serves a monitoring dashboard on port 80. Auth is **off by default**
(trusted LAN model). To enable password protection:

```bash
# On the board
echo "PASSWORD=your_password_here" >> /etc/odo-web.conf
/etc/init.d/S96odowebd stop && /etc/init.d/S96odowebd start
```

Features: live hashrate, share counters, pool/failover status, temperature + fan
speed, fan boost button, reset stats, pool failover indicator.

---

## Fan & Temperature

`odo-webd` and `odo-ui` surface temperature and fan duty automatically from
`status.json`. The thermal control loop is in the daemon:

- < 38 °C: minimum duty (40%)
- 38–48 °C: proportional
- > 48 °C: full speed

Fan boost (temporary 100%) is available from both the web dashboard and the touch UI.

If the DS18B20 read fails (sensor disconnect), the daemon falls back to full fan
speed to avoid thermal runaway.

---

## Serial Console (Recovery)

If SSH/network is unavailable, connect a USB-to-TTL adapter to the UART header:

- **115200 baud, 8N1**, no flow control
- U-Boot output begins ~1 s after power-on; Linux login prompt at ~30 s
- Login: `root` / `odo-miner`

Windows: use [serial-console.ps1](../scripts/serial-console.ps1) or PuTTY on the
COM port assigned to the CH340 adapter.

---

## Watchdog

Set `ODOD_WATCHDOG=1` in `/etc/odod.conf` to enable the daemon's dead-pool watchdog.
After the soak period (≥ 24 h clean operation), this is recommended for autonomous
deployment — it reboots the board if the daemon cannot reach either pool for an
extended period.

---

## Deployment Checklist

- [ ] `/etc/odod.conf` has correct pool host/port/worker (no placeholder addresses)
- [ ] Root password changed from `odo-miner` (`passwd`)
- [ ] SSH key added to `/root/.ssh/authorized_keys`
- [ ] WiFi configured and tested (if wireless deployment)
- [ ] `shares_accepted > 0` in `status.json` after 10 min
- [ ] Temperature reading is plausible in `status.json`
- [ ] Fan is spinning (audible; tach RPM in `status.json`)
- [ ] `backend: "uio"` in `status.json` (interrupt-driven handoff active)
- [ ] Epoch renewal tested: stage a known `.rbf`, confirm `epoch-update.sh` applies it
- [ ] `ODOD_WATCHDOG=1` set after 24 h clean soak

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `shares_rejected: N` / 0 accepted | Wrong pool, bad worker addr, algorithm mismatch | Verify `/etc/odod.conf` worker is a valid DGB address; check pool logs |
| FPGA registers read 0xFFFFFFFF | Bitstream not loaded / bridges not enabled | U-Boot log (serial) should show `fpga load` success; verify `fpga.rbf` is on FAT p1 |
| `backend: "poll"` in status.json | `/dev/uio0` missing (DTS or kernel config) | Check `dmesg | grep uio`; UIO requires the device-tree `generic-uio` node |
| Hashrate zero, no errors | Epoch key mismatch (ODOKEY in RTL ≠ current epoch) | Check `epoch` field in `status.json`; rebuild bitstream with correct ODOKEY |
| WiFi drops every ~10 s | USB autosuspend not disabled | Check `dmesg | grep autosuspend`; `S45wifi` should disable it; verify overlay is current |
| Fan not spinning | Thermal PIO not wired or binary mismatch | Check `fan_duty_pct` in `status.json`; verify bitstream includes `pwm_fan` instance |
| Board reboots repeatedly | Watchdog firing | Disable `ODOD_WATCHDOG` temporarily; check `/run/odod/status.json` for pool connectivity |
| No serial output | Wrong COM port or baud | Try each COM port at 115200 8N1; CH340 driver required on Windows |
