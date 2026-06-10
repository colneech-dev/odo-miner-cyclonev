# Deployment & Runtime Configuration

This guide covers post-build configuration, security hardening, and runtime setup for the odo-miner Cyclone V system.

---

## Serial Console Access

The kernel is configured with explicit serial console output:

```
console=ttyS0,115200n8 earlycon=uart,mmio32,0xffc02000
```

**Setup:**
1. Connect a USB-to-TTL serial adapter to the QMTECH board's UART header (typically pins 1-4)
2. Set terminal to 115200 baud, 8N1
3. Power on the board and watch bootloader/kernel output
4. You'll see U-Boot SPL → U-Boot → Linux kernel → login prompt

**Example (minicom):**
```bash
minicom -D /dev/ttyUSB0 -b 115200
```

This serial console is essential for:
- Troubleshooting boot failures
- Accessing the system if Ethernet/SSH fails
- Monitoring early kernel panics
- Changing root password at first boot

---

## Root Password Management

### Lab/Testing (Initial Build)

Default credentials (from defconfig):
```
Username: root
Password: odo-miner
```

Suitable for development and lab testing on isolated networks.

### Production/Deployment

**Never deploy with hardcoded passwords on an internet-connected appliance.** Choose one:

#### Option A: Manual Password Change at First Boot

After first serial login:

```bash
login: root
Password: odo-miner

# Change password
root@odo-miner:~# passwd
Enter new UNIX password: <new_password>
Retype new UNIX password: <confirm>
passwd: password updated successfully
```

Store the new password securely (e.g., in a password manager or deployment docs).

#### Option B: Disable Root SSH, Create Non-Root User

Edit `linux/buildroot_cyclonev_defconfig`:

```
# Security: disable root login via SSH
BR2_PACKAGE_OPENSSH_DISABLE_ROOT_LOGIN=y
BR2_PACKAGE_SUDO=y

# Add non-root user for mining operations
# (Handled in post-build script or rootfs overlay)
```

Then add a post-build script that creates the non-root user:

```bash
#!/bin/bash
# scripts/create-miner-user.sh

ROOTFS=$1

# Create 'miner' user in rootfs
mkdir -p ${ROOTFS}/home/miner
cat >> ${ROOTFS}/etc/passwd <<'EOF'
miner:x:1000:1000:Mining User:/home/miner:/bin/sh
EOF

cat >> ${ROOTFS}/etc/shadow <<'EOF'
miner:$6$<hashed_password>:19000:0:99999:7:::
EOF

# Allow 'miner' to run critical commands via sudo
mkdir -p ${ROOTFS}/etc/sudoers.d
cat > ${ROOTFS}/etc/sudoers.d/miner <<'EOF'
miner ALL=(ALL) NOPASSWD: /usr/sbin/watchdog
miner ALL=(ALL) NOPASSWD: /usr/sbin/supervisord
EOF

chmod 0440 ${ROOTFS}/etc/sudoers.d/miner
```

Then SSH as `miner` user and use `sudo` for privileged operations.

#### Option C: Prompt for Password at First Boot (Systemd Service)

Create a first-boot systemd service:

```ini
# /etc/systemd/system/firstboot-password.service
[Unit]
Description=First-boot root password prompt
After=network-online.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/firstboot-password-prompt.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Script (`/usr/local/bin/firstboot-password-prompt.sh`):

```bash
#!/bin/bash
# Prompt for new root password at first boot

FLAG_FILE="/root/.password-changed"

if [ ! -f "$FLAG_FILE" ]; then
  echo "=========================================="
  echo "First boot: Set root password"
  echo "=========================================="
  passwd root
  touch "$FLAG_FILE"
  echo "Password set. Disable this service:"
  echo "  systemctl disable firstboot-password.service"
fi
```

---

## System Time (NTP)

ntpd is included in the rootfs but requires `/etc/ntp.conf`.

### Basic Setup (Recommended)

Create `/etc/ntp.conf` before deploying:

```bash
# scripts/create-ntp-config.sh
cat > /tmp/rootfs-mount/etc/ntp.conf <<'EOF'
# NTP configuration for autonomous mining
# Use public NTP pools as primary source

# Public NTP servers
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server 3.pool.ntp.org iburst

# Drift file (stores long-term clock offset)
driftfile /var/lib/ntp/drift

# Statistics directory
statsdir /var/log/ntpstats/

# Restrict access to localhost only
restrict 127.0.0.1
restrict -6 ::1

# Basic access control (allow local network)
restrict default limited kod nomodify nopeer noquery notrap
EOF

chmod 644 /tmp/rootfs-mount/etc/ntp.conf
mkdir -p /tmp/rootfs-mount/var/lib/ntp
```

### Pool-Provided NTP (Optional)

If your mining pool provides an NTP server, add it to `/etc/ntp.conf`:

```
server mining-pool.example.com iburst prefer
server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
```

The `prefer` flag prioritizes the pool's NTP.

### Enable ntpd at Boot

```bash
systemctl enable ntpd.service
systemctl start ntpd.service
```

Verify:

```bash
ntpq -p
# Should show pool.ntp.org servers with refid asterisks (*) when synced
```

**Why NTP matters for mining:**
- OdoCrypt epochs are time-based; clock skew = invalid shares
- Stratum protocol uses timestamps for authentication
- Long-term drift without NTP = mining downtime for recalibration

---

## Watchdog Timer (Autonomous Reboot on Hang)

The watchdog daemon uses the ARM Cortex-A9 built-in watchdog timer. If the system hangs (e.g., `odod` infinite loop), the watchdog fires and reboots automatically.

### Enable at Boot

```bash
# Add to systemd startup
systemctl enable watchdog.service
systemctl start watchdog.service
```

Or add to init script:

```bash
# /etc/init.d/S95watchdog
#!/bin/sh
/usr/sbin/watchdog &
```

### Watchdog Configuration

Default timeout is ~10 seconds. Tune via `/etc/watchdog.conf` if needed:

```ini
[watchdog]
watchdog-device = /dev/watchdog
watchdog-timeout = 10
# Temperature check (optional, if board has temp sensor)
# max-temperature = 85
```

**Critical for mining:** A hung `odod` daemon will automatically trigger a reboot, minimizing lost mining time.

---

## Supervisor Process Management

supervisor auto-restarts the `odod` daemon if it crashes. Configure post-build:

```bash
# scripts/setup-supervisor.sh
mkdir -p /tmp/rootfs-mount/etc/supervisor/conf.d

cat > /tmp/rootfs-mount/etc/supervisor/conf.d/odod.conf <<'EOF'
[program:odod]
command=/usr/local/bin/odod %(ENV_POOL_SERVER)s %(ENV_POOL_PORT)s
autostart=true
autorestart=true
stdout_logfile=/var/log/odod.log
stderr_logfile=/var/log/odod-err.log
startsecs=2
stopasgroup=true
environment=PATH="/usr/local/bin:/usr/bin:/bin",POOL_SERVER="mining-pool.example.com",POOL_PORT="3333"
EOF
```

Then start supervisor at boot:

```bash
systemctl enable supervisord.service
systemctl start supervisord.service
```

Verify:

```bash
supervisorctl status
# Should show: odod                           RUNNING
```

---

## Logrotate (Prevent Disk Fullness)

logrotate prevents log files from consuming all disk space. Configure:

```bash
# /etc/logrotate.d/odod-mining
/var/log/odod*.log {
    size 10M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        supervisorctl reread odod
        supervisorctl restart odod
    endscript
}
```

Verify logs are rotated:

```bash
logrotate -f /etc/logrotate.conf
ls -lh /var/log/odod*.log*
```

---

## FPGA Bitstream Loading

The FPGA bitstream (`.rbf` format) is loaded at boot via the Linux FPGA Manager.

### Placement on SD Card

```
fpga.rbf  (on the FAT boot partition, mmcblk0p1)
```

The U-Boot boot script (`boot.scr`, generated by `scripts/build-sdcard.sh`) loads it with `fpga load 0` and enables the HPS↔FPGA bridges before booting Linux. The kernel's FPGA Manager (enabled via `linux/linux-fpga.fragment`: `CONFIG_FPGA_MGR_SOCFPGA` + bridge/region drivers) allows reloading at runtime.

### Runtime Bitstream Updates (OdoCrypt Mutation Epochs)

At mutation epochs, a new bitstream must be loaded. Two approaches:

#### Manual Update (Lab)

```bash
# Download or compile new .rbf
wget https://your-repo/fpga-epoch-123.rbf -O /tmp/new.rbf

# Validate checksum (optional)
sha256sum /tmp/new.rbf

# Load via FPGA Manager
echo /tmp/new.rbf > /sys/class/fpga_manager/fpga0/firmware
# Or reboot with new .rbf in /boot/fpga.rbf
```

#### Automated Update (Production)

Create an update service:

```bash
# /usr/local/bin/odo-update-fpga
#!/bin/bash

EPOCH=$1
BITSTREAM_URL="https://your-repo/fpga-epoch-${EPOCH}.rbf"

cd /tmp
wget "$BITSTREAM_URL" -O new.rbf
sha256sum -c <(curl "$BITSTREAM_URL.sha256") || exit 1

cp new.rbf /boot/fpga.rbf
reboot
```

Schedule via cron or triggered by the `odod` daemon at mutation epoch.

---

## Networking & Remote Access

### Ethernet (Primary)

DHCP is enabled by default. At boot:

```bash
root@odo-miner:~# ifconfig eth0
eth0: flags=...
  inet 192.168.1.100  netmask 255.255.255.0
```

To set a static IP:

```bash
# /etc/network/interfaces
auto eth0
iface eth0 inet static
  address 192.168.1.100
  netmask 255.255.255.0
  gateway 192.168.1.1
  dns-nameservers 8.8.8.8 8.8.4.4
```

### WiFi (Optional, if USB adapter attached)

WPA_SUPPLICANT is included. Configure:

```bash
cat > /etc/wpa_supplicant.conf <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="YourSSID"
    psk="YourPassword"
    key_mgmt=WPA-PSK
}
EOF

# Start WPA
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf

# Get DHCP
dhclient wlan0
```

### SSH Access

SSH is enabled. Recommended: use SSH keys instead of passwords:

```bash
# On deployment machine
ssh-copy-id -i ~/.ssh/id_rsa.pub root@<board-ip>

# Then disable password login
cat >> /etc/ssh/sshd_config <<'EOF'
PasswordAuthentication no
PermitRootLogin without-password
EOF

systemctl restart ssh
```

---

## Monitoring & Debugging

### Check System Health

```bash
# CPU/memory usage
top
free -h

# Disk usage
df -h

# Temperature (if sensor exists)
cat /sys/class/thermal/thermal_zone*/temp

# Kernel logs
dmesg | tail -20

# ntpd status
ntpq -p

# Supervisor status
supervisorctl status
```

### Watch Mining Output

```bash
# Real-time odod logs
tail -f /var/log/odod.log

# Supervisor logs
tail -f /var/log/supervisord.log

# System journal (if systemd available)
journalctl -f -u odod
```

---

## Pre-Deployment Checklist

- [ ] Root password changed from `odo-miner`
- [ ] `/etc/ntp.conf` configured with NTP servers
- [ ] Watchdog daemon enabled and tested (`systemctl status watchdog`)
- [ ] Supervisor configured with `odod.conf` and running (`supervisorctl status`)
- [ ] Logrotate configured and working
- [ ] Serial console tested at 115200 baud
- [ ] Ethernet connectivity verified (DHCP or static IP)
- [ ] FPGA bitstream in `/boot/fpga.rbf` with correct permissions
- [ ] `odod` daemon compiled and placed at `/usr/local/bin/odod`
- [ ] SSH keys deployed (if password-less access desired)
- [ ] System time synchronized to NTP pool (check `ntpq -p`)

---

## Troubleshooting

| Issue | Symptom | Fix |
|-------|---------|-----|
| **No serial output** | USB adapter not showing ttyUSB0 | Check cable, try different port, verify baud rate 115200 |
| **NTP not syncing** | `ntpq -p` shows no refid asterisks | Check `/etc/ntp.conf`, firewall blocks port 123 (UDP) |
| **Watchdog reboot loop** | Board reboots every ~10s | System hanging; check `odod` logs before reboot |
| **odod crashes repeatedly** | supervisor logs show rapid restarts | Check pool connectivity, FPGA register access, add debug logging |
| **Disk full** | 8GB ext4 partition full | Check `/var/log/` size, enable logrotate, clean `/tmp/` |
| **Ethernet down** | `ifconfig eth0` shows no IP | Check cable, try DHCP renewal: `dhclient eth0`, verify PHY in device tree |
| **FPGA manager fails** | `echo /tmp/new.rbf > /sys/class/fpga_manager/fpga0/firmware` returns error | Verify `.rbf` is valid, check kernel FPGA Manager enabled, check permissions |

---

## References

- NTP: https://www.ntp.org/
- Supervisor: http://supervisord.org/
- Linux watchdog: https://www.kernel.org/doc/html/latest/watchdog/watchdog-api.html
- U-Boot FPGA Manager: https://www.kernel.org/doc/html/latest/driver-api/fpga/fpga-mgr.html
