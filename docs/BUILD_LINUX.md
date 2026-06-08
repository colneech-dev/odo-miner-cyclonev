# Building Linux for Cyclone V SoC with Buildroot

## Quick Summary

This guide walks you through building a minimal embedded Linux for the HPS (Hard Processor System) on the QMTECH Cyclone V SoC. The resulting rootfs will include:

- Linux kernel (5.15+ with FPGA Manager support)
- Essential utilities (busybox)
- Our compiled miner binaries (odo-miner, fpga_smoke_test, etc.)
- Networking (Ethernet, optionally WiFi)
- SD card boot support (U-Boot + SPL)

**Expected output:**
- `linux/output/images/zImage` — Linux kernel
- `linux/output/images/rootfs.ext4` — Root filesystem
- `linux/output/images/u-boot-with-spl.sfp` — Bootloader
- `linux/sdcard/odo-miner-cyclonev-sdcard.img` — Full SD card image (optional)

**Build time:** 30–90 minutes (depending on machine and internet speed)

---

## Prerequisites

### 1. Install Buildroot Dependencies (Linux/WSL)

If building on **WSL2**, run:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git wget curl bc \
  cpio unzip rsync file bzip2 libssl-dev
```

If building on **native Linux**, same commands.

**Windows Note:** Buildroot requires a POSIX environment. You MUST use **WSL2** or a native Linux machine. Windows PowerShell / MSYS2 won't work reliably.

### 2. Download Buildroot

```bash
cd ~/projects  # or wherever you keep sources
wget https://buildroot.org/downloads/buildroot-2023.11.tar.xz
tar xf buildroot-2023.11.tar.xz
cd buildroot-2023.11
```

**Or use git:**
```bash
git clone https://gitlab.com/buildroot.org/buildroot.git buildroot-latest
cd buildroot-latest
git checkout 2023.11  # stable LTS
```

### 3. Cross-compiler (ARM EABI)

Buildroot includes the cross-compiler, but you can also install the system arm-linux-gnueabihf toolchain:

```bash
sudo apt-get install arm-linux-gnueabihf-gcc arm-linux-gnueabihf-g++ arm-linux-gnueabihf-binutils
```

---

## Building Step-by-Step

### Step 1: Prepare Buildroot Configuration

Create a Buildroot defconfig for Cyclone V. Save this as `buildroot-2023.11/configs/cyclonev_defconfig`:

```ini
BR2_arm=y
BR2_cortex_a9=y
BR2_ARM_FPU_NEON=y
BR2_ARM_FPU_NEON_VFPV4=y
BR2_ARM_EABI=y
BR2_ARM_INSTRUCTIONS_THUMB2=y

# Linux Kernel
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="5.15.155"
BR2_LINUX_KERNEL_DEFCONFIG="multi_v7"
BR2_LINUX_KERNEL_INTREE_DTS_NAME="socfpga_cyclone5"
BR2_LINUX_KERNEL_IMAGE_TARGET_CUSTOM=y
BR2_LINUX_KERNEL_IMAGE_TARGET_NAME="zImage"

# Device Tree
BR2_LINUX_KERNEL_DTS_SUPPORT=y

# U-Boot bootloader
BR2_TARGET_UBOOT=y
BR2_TARGET_UBOOT_BUILD_SYSTEM_KCONFIG=y
BR2_TARGET_UBOOT_CUSTOM_VERSION=y
BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE="2023.10"
BR2_TARGET_UBOOT_BOARD_NAME="socfpga_cyclone5"
BR2_UBOOT_SPL=y
BR2_UBOOT_SPL_ZYNQMP_SECURE_BOOT=n

# Root filesystem
BR2_TARGET_ROOTFS_EXT4=y
BR2_TARGET_ROOTFS_EXT4_SIZE="256M"

# Busybox (minimal utilities)
BR2_PACKAGE_BUSYBOX=y
BR2_PACKAGE_BUSYBOX_SHOW_OTHERS=y

# Networking
BR2_PACKAGE_DHCP=y
BR2_PACKAGE_ETHTOOL=y
BR2_PACKAGE_OPENSSH=y
BR2_PACKAGE_OPENSSH_SERVER=y

# Development tools
BR2_PACKAGE_MAKE=y
BR2_PACKAGE_GIT=y
BR2_PACKAGE_WGET=y
BR2_PACKAGE_CURL=y

# Optional: WiFi (if you have ESP32 module)
# BR2_PACKAGE_WPA_SUPPLICANT=y
# BR2_PACKAGE_HOSTAPD=y

# Locale
BR2_GENERATE_LOCALE="en_US"
BR2_SYSTEM_LOCALE="en_US.UTF-8"

# Hostname
BR2_SYSTEM_HOSTNAME="odo-miner"

# Root password (change this!)
BR2_TARGET_GENERIC_ROOT_PASSWD="odo-miner"

# NTP time sync
BR2_PACKAGE_NTP=y

# Additional tools
BR2_PACKAGE_HTOP=y
BR2_PACKAGE_IPERF3=y
BR2_PACKAGE_LSOF=y
BR2_PACKAGE_STRACE=y
```

### Step 2: Build Buildroot

```bash
cd buildroot-2023.11

# Load the Cyclone V config
make cyclonev_defconfig

# Customize if needed (optional)
make menuconfig  # Edit kernel/U-Boot options if desired

# Start the build (takes 30-90 min, lots of downloading)
make

# Output directory
ls -la output/images/
# Should have: zImage, socfpga_cyclone5.dtb, u-boot-spl.sfp, rootfs.ext4
```

---

## Step 3: Integrate Our Miner Binaries

Once Buildroot finishes, add our compiled HPS software:

```bash
# Mount the rootfs image (read-write)
mkdir -p /tmp/rootfs-mount
sudo mount -t ext4 -o loop,rw output/images/rootfs.ext4 /tmp/rootfs-mount

# Copy our compiled binaries
sudo cp ../../odo-miner-cyclonev/hps/odo-miner /tmp/rootfs-mount/usr/bin/
sudo cp ../../odo-miner-cyclonev/hps/odo-miner-watcher /tmp/rootfs-mount/usr/bin/
sudo cp ../../odo-miner-cyclonev/hps/fpga_smoke_test /tmp/rootfs-mount/usr/bin/
sudo cp ../../odo-miner-cyclonev/hps/miner_io_test /tmp/rootfs-mount/usr/bin/

# Make them executable
sudo chmod +x /tmp/rootfs-mount/usr/bin/odo-*
sudo chmod +x /tmp/rootfs-mount/usr/bin/*_test

# Create miner user (optional, for security)
sudo mkdir -p /tmp/rootfs-mount/home/miner
sudo chown 1000:1000 /tmp/rootfs-mount/home/miner

# Create FPGA Manager device tree overlay directory
sudo mkdir -p /tmp/rootfs-mount/lib/firmware/

# Umount
sudo umount /tmp/rootfs-mount
```

---

## Step 4: Create SD Card Image

### Option A: Manual Assembly (Recommended for understanding)

```bash
# Create a blank SD card image (4 GB)
dd if=/dev/zero of=odo-miner-sdcard.img bs=1M count=4096

# Partition the image
parted odo-miner-sdcard.img <<EOF
mklabel msdos
mkpart primary fat32 1MiB 256MiB
mkpart primary ext4 256MiB 100%
quit
EOF

# Format partitions
loop_dev=$(losetup -f)
losetup $loop_dev odo-miner-sdcard.img
mkfs.vfat -F 32 -n BOOT ${loop_dev}p1
mkfs.ext4 -L rootfs ${loop_dev}p2

# Mount and populate boot partition
mkdir -p /tmp/sdcard-boot /tmp/sdcard-root
mount ${loop_dev}p1 /tmp/sdcard-boot
mount ${loop_dev}p2 /tmp/sdcard-root

# Copy bootloader (SPL + U-Boot)
sudo cp buildroot-2023.11/output/images/u-boot-spl.sfp /tmp/sdcard-boot/
sudo cp buildroot-2023.11/output/images/u-boot.img /tmp/sdcard-boot/

# Copy kernel and device tree
sudo cp buildroot-2023.11/output/images/zImage /tmp/sdcard-boot/
sudo cp buildroot-2023.11/output/images/socfpga_cyclone5.dtb /tmp/sdcard-boot/

# Copy FPGA bitstream (.rbf)
sudo cp ../../odo-miner-cyclonev/bitstreams/odo_miner.rbf /tmp/sdcard-boot/fpga.rbf

# Copy rootfs
sudo cp -r buildroot-2023.11/output/images/rootfs.ext4 /tmp/sdcard-root/

# U-Boot boot script
cat > /tmp/sdcard-boot/boot.txt <<'UBOOT'
setenv bootargs "root=/dev/mmcblk0p2 rw rootwait earlyprintk console=ttyS0,115200n8"
fatload mmc 0:1 ${fdtaddr_r} socfpga_cyclone5.dtb
fatload mmc 0:1 ${kernel_addr_r} zImage
bootz ${kernel_addr_r} - ${fdtaddr_r}
UBOOT

# Convert boot.txt to boot.scr
mkimage -T script -C none -n "Boot Script" -d /tmp/sdcard-boot/boot.txt /tmp/sdcard-boot/boot.scr

# Umount
sudo umount /tmp/sdcard-boot /tmp/sdcard-root
losetup -d $loop_dev
```

### Option B: Automated Script

```bash
#!/bin/bash
# build-sdcard.sh

IMAGE="odo-miner-sdcard.img"
BUILDROOT="buildroot-2023.11"
BITSTREAM="odo_miner.rbf"
SIZE_GB=4

# Create image
dd if=/dev/zero of=$IMAGE bs=1M count=$((SIZE_GB * 1024))

# Partition
parted $IMAGE <<EOF
mklabel msdos
mkpart primary fat32 1MiB 256MiB
mkpart primary ext4 256MiB 100%
quit
EOF

# Mount
loop_dev=$(losetup -f)
losetup $loop_dev $IMAGE
mkdir -p /tmp/boot /tmp/root

mount ${loop_dev}p1 /tmp/boot
mount ${loop_dev}p2 /tmp/root

# Copy files
sudo cp $BUILDROOT/output/images/u-boot-spl.sfp /tmp/boot/
sudo cp $BUILDROOT/output/images/u-boot.img /tmp/boot/
sudo cp $BUILDROOT/output/images/zImage /tmp/boot/
sudo cp $BUILDROOT/output/images/socfpga_cyclone5.dtb /tmp/boot/
sudo cp $BITSTREAM /tmp/boot/fpga.rbf
sudo rsync -av $BUILDROOT/output/target/ /tmp/root/

# Umount & cleanup
sudo umount /tmp/boot /tmp/root
losetup -d $loop_dev

echo "SD card image: $IMAGE (ready to write)"
```

---

## Step 5: Write SD Card

Once you have the image, write it to an actual SD card:

```bash
# Find SD card (e.g., /dev/sdb)
lsblk | grep -i sd

# Write image (example: /dev/sdb)
sudo dd if=odo-miner-sdcard.img of=/dev/sdb bs=4M status=progress && sync

# Or use Etcher (GUI, safer):
# https://www.balena.io/etcher/
```

---

## Boot Sequence

1. **Power on** → HPS boots SPL (from SD card MBR)
2. **SPL loads U-Boot** from FAT partition
3. **U-Boot loads kernel + DTB** from FAT partition
4. **U-Boot loads FPGA bitstream** (fpga.rbf) via FPGA Manager
5. **Kernel starts** and mounts rootfs from ext4 partition
6. **Linux boots** with miner binaries ready at `/usr/bin/odo-miner`

---

## Testing on the Board

Once booted:

```bash
# Test FPGA register access
fpga_smoke_test

# Run the miner daemon
odo-miner pool.example.com 3333

# Check logs
dmesg | tail -20
```

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| "Kernel panic: VFS unable to mount root" | rootfs partition corrupted or missing | Rebuild Buildroot |
| FPGA not programming | Device tree missing FPGA Manager | Use socfpga_cyclone5.dtb from Buildroot |
| "Cannot load FPGA bitstream" | Missing fpga.rbf or wrong path | Copy .rbf to /boot/fpga.rbf |
| Ethernet not working | PHY not enabled in device tree | Check Qsys HPS EMAC config |
| Can't SSH in | sshd not running | Add BR2_PACKAGE_OPENSSH_SERVER to defconfig |

---

## Next Steps

1. **While Quartus compiles:** Build Buildroot (takes 30-90 min)
2. **While Buildroot builds:** Prepare SD card image assembly script
3. **Once Quartus finishes:** Generate bitstream → integrate into SD image
4. **Once all done:** Program FPGA via JTAG → Boot Linux from SD card → Test mining

---

## Buildroot 2025.11.3 Configuration (Current)

The defconfig at `linux/buildroot_cyclonev_defconfig` is the authoritative configuration for this project. Key updates from earlier versions:

**Toolchain & Kernel:**
- glibc (replaces uClibc for modern kernel compatibility)
- Linux 6.6.26 LTS (Dec 2028 support)
- Kernel console: `console=ttyS0,115200n8 earlycon=uart,mmio32,0xffc02000`

**Mining-specific packages:**
- gcc, binutils, gdb, linux-headers (on-target compilation for daemon rebuilds)
- openssl, libcurl, jansson (Stratum protocol + TLS support)

**Robustness:**
- supervisor (auto-restart crashed odod daemon)
- watchdog (ARM watchdog daemon; reboots on system hang)
- logrotate (prevent log files from consuming disk)
- sysstat, htop, lsof, strace (monitoring & debugging)

**Rootfs size:** 8GB (accommodates build tools + logs + on-target compilation temp files)

**See `docs/DEPLOYMENT.md` for post-build configuration** including NTP setup, watchdog enablement, password management, and supervisor configuration.

---

## References

- Buildroot: https://buildroot.org/
- Cyclone V Linux: https://www.intel.com/content/www/us/en/programmable/support/support-resources/design-examples/design-software/embedded-design-tools/altera-soc-embedded-design-suite.html
- QMTECH GHRD: https://github.com/ChinaQMTECH/QMTECH_CycloneV_SoC
