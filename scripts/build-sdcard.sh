#!/bin/bash
# build-sdcard.sh — Automated SD card image assembly for odo-miner-cyclonev
#
# Creates a complete, bootable SD card image with:
#   - U-Boot SPL+bootloader in a raw 0xA2 partition (REQUIRED: the Cyclone V
#     BootROM only loads the preloader from a partition of type 0xA2 — it
#     cannot read FAT)
#   - Linux kernel + device tree + boot script on a FAT partition
#   - FPGA bitstream (if available)
#   - Root filesystem (Buildroot rootfs.ext4) with miner binaries injected
#
# Partition layout:
#   p1  FAT32  256 MiB   zImage, socfpga_cyclone5_qmtech_odo.dtb, boot.scr, fpga.rbf
#   p2  ext4   remainder rootfs (root=/dev/mmcblk0p2)
#   p3  0xA2   16 MiB    u-boot-with-spl.sfp (raw, no filesystem)
#
# Usage:
#   ./scripts/build-sdcard.sh
#
# Environment variables (optional):
#   BUILDROOT_DIR=~/buildroot-2025.11.3  (where Buildroot output is)
#   IMAGE_SIZE=9216                       (image size in MB; must exceed the
#                                          8 GB rootfs + 272 MB boot/A2)
#   OUTPUT_DIR=~/sdcard-images            (where to save the image)
#
# Prerequisites:
#   - Buildroot built (zImage, socfpga_cyclone5_qmtech_odo.dtb, u-boot-with-spl.sfp,
#     rootfs.ext4) — see scripts/build-buildroot.sh
#   - FPGA bitstream (odo_miner.rbf), optional
#   - HPS binaries built (odo-miner, fpga_smoke_test, etc.), optional
#   - Utilities: sfdisk, losetup, mkfs.vfat, mkimage, e2fsck, resize2fs
#   - sudo access (for loop devices and mounts)

set -e

# ============================================================================
# Configuration & Defaults
# ============================================================================

BUILDROOT_DIR="${BUILDROOT_DIR:-${HOME}/buildroot-2025.11.3}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HPS_BUILD_DIR="$PROJECT_ROOT/hps"
# Where to find the .rbf. Default to the Quartus output dir (where the build
# actually puts it); override with BITSTREAM_DIR=... if you stage it elsewhere.
BITSTREAM_DIR="${BITSTREAM_DIR:-$PROJECT_ROOT/hdl/quartus/output_files}"
IMAGE_SIZE_MB="${IMAGE_SIZE:-9216}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/sdcard-output}"
IMAGE_FILE="$OUTPUT_DIR/odo-miner-cyclonev-$(date +%Y%m%d-%H%M%S).img"
TEMP_BOOT_DIR="/tmp/odo-sdcard-boot-$$"
TEMP_ROOT_DIR="/tmp/odo-sdcard-root-$$"

DTB_NAME="socfpga_cyclone5_qmtech_odo.dtb"

# Partition geometry (512-byte sectors)
P1_START=2048      # 1 MiB
P1_SIZE=524288     # 256 MiB FAT boot
A2_START=$((P1_START + P1_SIZE))
A2_SIZE=32768      # 16 MiB raw preloader partition
P2_START=$((A2_START + A2_SIZE))

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${BLUE}=== $* ===${NC}"; }

# ============================================================================
# Sanity Checks
# ============================================================================

log_step "Validating environment"

if [ ! -d "$BUILDROOT_DIR" ]; then
    log_error "Buildroot directory not found: $BUILDROOT_DIR"
    log_info "Set BUILDROOT_DIR=/path/to/buildroot-2025.11.3"
    exit 1
fi

required_files=(
    "$BUILDROOT_DIR/output/images/zImage"
    "$BUILDROOT_DIR/output/images/$DTB_NAME"
    "$BUILDROOT_DIR/output/images/u-boot-with-spl.sfp"
    "$BUILDROOT_DIR/output/images/rootfs.ext4"
)

for f in "${required_files[@]}"; do
    if [ ! -f "$f" ]; then
        log_error "Missing: $f"
        log_info "Run Buildroot build first: BUILDROOT_DIR=... bash scripts/build-buildroot.sh"
        exit 1
    fi
done

# The rootfs (plus boot + A2 partitions) must fit in the image
rootfs_bytes=$(stat -c%s "$BUILDROOT_DIR/output/images/rootfs.ext4")
min_image_mb=$(( rootfs_bytes / 1024 / 1024 + (P2_START * 512 / 1024 / 1024) + 16 ))
if [ "$IMAGE_SIZE_MB" -lt "$min_image_mb" ]; then
    log_error "IMAGE_SIZE=${IMAGE_SIZE_MB}MB too small for rootfs.ext4 (need >= ${min_image_mb}MB)"
    exit 1
fi

# Find bitstream (most recent .rbf)
if [ -d "$BITSTREAM_DIR" ]; then
    BITSTREAM=$(find "$BITSTREAM_DIR" -name "*.rbf" -type f -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -z "$BITSTREAM" ]; then
        log_warn "No .rbf bitstream found in $BITSTREAM_DIR"
        BITSTREAM=""
    fi
else
    log_warn "Bitstream directory not found: $BITSTREAM_DIR"
    BITSTREAM=""
fi

# Check for HPS binaries
hps_binaries=(
    "$HPS_BUILD_DIR/odo-miner"
    "$HPS_BUILD_DIR/odo-miner-watcher"
    "$HPS_BUILD_DIR/fpga_smoke_test"
    "$PROJECT_ROOT/sw/odo-ui/odo-ui"
    "$PROJECT_ROOT/sw/odo-webd/odo-webd"
)

for b in "${hps_binaries[@]}"; do
    if [ ! -f "$b" ]; then
        log_warn "Missing HPS binary: $b (will not be included)"
    fi
done

log_info "✓ Buildroot artifacts found"
[ -n "$BITSTREAM" ] && log_info "✓ FPGA bitstream: $BITSTREAM" || log_warn "⚠ No FPGA bitstream"

# Check tools
# tool -> apt package, so a missing tool tells you exactly what to install
declare -A tool_pkg=(
    [sfdisk]=util-linux [losetup]=util-linux
    [mkfs.vfat]=dosfstools [mkimage]=u-boot-tools
    [e2fsck]=e2fsprogs [resize2fs]=e2fsprogs
)
missing_pkgs=()
for tool in "${!tool_pkg[@]}"; do
    command -v "$tool" &>/dev/null || missing_pkgs+=("${tool_pkg[$tool]}")
done
if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    uniq_pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
    log_error "Missing build tools. Install them with:"
    log_error "    sudo apt install -y $uniq_pkgs"
    log_error "  (or run scripts/install-deps.sh to install everything at once)"
    exit 1
fi

log_info "✓ All required tools available"

# ============================================================================
# Create Output Directory
# ============================================================================

mkdir -p "$OUTPUT_DIR"
log_info "Output directory: $OUTPUT_DIR"

# ============================================================================
# Step 1: Create Blank Image
# ============================================================================

log_step "Step 1: Creating blank SD card image (${IMAGE_SIZE_MB}MB, sparse)"

if [ -f "$IMAGE_FILE" ]; then
    log_error "Image already exists: $IMAGE_FILE"
    exit 1
fi

truncate -s "${IMAGE_SIZE_MB}M" "$IMAGE_FILE"
log_info "✓ Image created: $IMAGE_FILE"

# ============================================================================
# Step 2: Partition Image (FAT boot + ext4 root + raw A2 preloader)
# ============================================================================

log_step "Step 2: Partitioning image"

sfdisk "$IMAGE_FILE" > /dev/null <<EOF
label: dos
unit: sectors

start=$P1_START, size=$P1_SIZE, type=c, bootable
start=$P2_START, type=83
start=$A2_START, size=$A2_SIZE, type=a2
EOF

log_info "✓ Partitions: p1 FAT32 boot (256MiB), p2 ext4 rootfs, p3 raw 0xA2 preloader (16MiB)"

# ============================================================================
# Step 3: Setup Loop Device
# ============================================================================

log_step "Step 3: Attaching loop device"

LOOP_DEV=$(sudo losetup -f --show -P "$IMAGE_FILE")
log_info "Loop device: $LOOP_DEV"
sleep 1

if [ ! -e "${LOOP_DEV}p1" ] || [ ! -e "${LOOP_DEV}p2" ] || [ ! -e "${LOOP_DEV}p3" ]; then
    log_error "Loop device partitions not created"
    sudo losetup -d "$LOOP_DEV"
    exit 1
fi

cleanup() {
    sudo umount "$TEMP_BOOT_DIR" "$TEMP_ROOT_DIR" 2>/dev/null || true
    rmdir "$TEMP_BOOT_DIR" "$TEMP_ROOT_DIR" 2>/dev/null || true
    sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Step 4: Install Bootloader (raw write to the A2 partition)
# ============================================================================

log_step "Step 4: Installing bootloader (u-boot-with-spl.sfp -> A2 partition)"

sudo dd if="$BUILDROOT_DIR/output/images/u-boot-with-spl.sfp" \
        of="${LOOP_DEV}p3" bs=64k status=none
log_info "✓ SPL + U-Boot written raw to ${LOOP_DEV}p3 (type 0xA2)"

# ============================================================================
# Step 5: Root Filesystem (dd the Buildroot ext4, then grow to partition)
# ============================================================================

log_step "Step 5: Installing root filesystem"

sudo dd if="$BUILDROOT_DIR/output/images/rootfs.ext4" \
        of="${LOOP_DEV}p2" bs=4M status=progress
sudo e2fsck -fy "${LOOP_DEV}p2" > /dev/null || true
sudo resize2fs "${LOOP_DEV}p2" > /dev/null
log_info "✓ rootfs.ext4 written and resized to fill partition"

# ============================================================================
# Step 6: Boot Partition (kernel, DTB, boot script, bitstream)
# ============================================================================

log_step "Step 6: Populating FAT boot partition"

sudo mkfs.vfat -F 32 -n BOOT "${LOOP_DEV}p1" > /dev/null
mkdir -p "$TEMP_BOOT_DIR" "$TEMP_ROOT_DIR"
sudo mount "${LOOP_DEV}p1" "$TEMP_BOOT_DIR"

sudo cp "$BUILDROOT_DIR/output/images/zImage" "$TEMP_BOOT_DIR/zImage"
sudo cp "$BUILDROOT_DIR/output/images/$DTB_NAME" "$TEMP_BOOT_DIR/$DTB_NAME"
log_info "✓ Kernel and DTB installed"

if [ -n "$BITSTREAM" ]; then
    sudo cp "$BITSTREAM" "$TEMP_BOOT_DIR/fpga.rbf"
    log_info "✓ FPGA bitstream: $(basename "$BITSTREAM")"
else
    log_warn "⚠ No FPGA bitstream; copy your .rbf to the FAT partition as fpga.rbf later"
fi

# U-Boot boot script (U-Boot's distro boot finds boot.scr on the FAT partition)
cat > "/tmp/odo-boot-$$.txt" <<UBOOT
echo "odo-miner boot script"

setenv bootargs root=/dev/mmcblk0p2 rw rootwait console=ttyS0,115200n8

if test -e mmc 0:1 fpga.rbf; then
    echo "Loading FPGA bitstream..."
    fatload mmc 0:1 0x2000000 fpga.rbf
    fpga load 0 0x2000000 \${filesize}
    bridge enable
fi

echo "Loading device tree and kernel..."
fatload mmc 0:1 \${fdt_addr_r} $DTB_NAME
fatload mmc 0:1 \${kernel_addr_r} zImage

echo "Booting..."
bootz \${kernel_addr_r} - \${fdt_addr_r}
UBOOT

mkimage -T script -C none -n 'odo-miner boot' \
        -d "/tmp/odo-boot-$$.txt" "/tmp/odo-boot-$$.scr" > /dev/null
sudo cp "/tmp/odo-boot-$$.scr" "$TEMP_BOOT_DIR/boot.scr"
rm -f "/tmp/odo-boot-$$.txt" "/tmp/odo-boot-$$.scr"
log_info "✓ U-Boot boot script created"

# ============================================================================
# Step 7: Inject HPS Binaries into the Rootfs
# ============================================================================

log_step "Step 7: Installing HPS miner binaries"

sudo mount "${LOOP_DEV}p2" "$TEMP_ROOT_DIR"

for binary in "${hps_binaries[@]}"; do
    if [ -f "$binary" ]; then
        sudo cp "$binary" "$TEMP_ROOT_DIR/usr/bin/$(basename "$binary")"
        sudo chmod +x "$TEMP_ROOT_DIR/usr/bin/$(basename "$binary")"
        log_info "  ✓ $(basename "$binary")"
    fi
done

sudo mkdir -p "$TEMP_ROOT_DIR/home/miner"
sudo chmod 755 "$TEMP_ROOT_DIR/home/miner"

# ============================================================================
# Step 8: On-Target Readme
# ============================================================================

log_step "Step 8: Creating on-target documentation"

sudo tee "$TEMP_ROOT_DIR/root/README.md" > /dev/null <<'README'
# odo-miner Cyclone V SoC

Welcome! You're running on a standalone FPGA mining system.

## Quick Start

```bash
# Test FPGA register access
fpga_smoke_test

# Connect to a mining pool
odo-miner pool.example.com 3333

# Or use the watcher version (auto-epoch reload)
odo-miner-watcher pool.example.com 3333
```

## Environment Variables

```bash
export ODOMIN_NONCE_RANGE=2000000      # nonces per dispatch
export ODOMIN_POLL_TIMEOUT_MS=3000     # FPGA poll timeout (ms)
export ODOMIN_EPOCH_POLL_S=5           # epoch check interval (s)
export ODOMIN_HEARTBEAT_S=60           # status log interval (s)
odo-miner pool.example.com 3333
```

## Loading FPGA Bitstream

The boot script loads /boot FAT partition fpga.rbf automatically at U-Boot
time. To reload from Linux via the FPGA manager:

```bash
mount /dev/mmcblk0p1 /mnt
cp /mnt/fpga.rbf /lib/firmware/
echo 0 > /sys/class/fpga_manager/fpga0/flags
echo fpga.rbf > /sys/class/fpga_manager/fpga0/firmware
cat /sys/class/fpga_manager/fpga0/state   # should say "operating"
```

## Troubleshooting

**FPGA returns 0xFFFFFFFF (not loaded):**
- Make sure a bitstream is loaded (see above)
- Bridges must be enabled before register access

**No Ethernet:**
- Check cable; dhcpcd runs automatically
- Inspect: `ip addr` / `ethtool eth0`

**WiFi (USB adapter):**
- `ip link` should show wlan0 once the adapter is plugged in
- Configure: `wpa_passphrase SSID PASS > /etc/wpa_supplicant.conf`
  then `wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf && dhcpcd wlan0`

## Logs

- Kernel: `dmesg`
- System: `/var/log/messages`

## Rebuilding the Miner

The rootfs has no compiler — cross-compile on the build host (WSL) with the
Buildroot toolchain and scp the binary over. See docs/BUILD_LINUX.md in the
project repository.

## References

- odo-miner project: https://github.com/MentalCollatz/odo-miner
- QMTECH board: https://github.com/ChinaQMTECH/QMTECH_CycloneV_SoC
README

log_info "✓ On-target documentation created"

# ============================================================================
# Step 9: Sync & Detach
# ============================================================================

log_step "Step 9: Finalizing image"

sync
sudo umount "$TEMP_BOOT_DIR" "$TEMP_ROOT_DIR"
rmdir "$TEMP_BOOT_DIR" "$TEMP_ROOT_DIR" 2>/dev/null || true
sudo losetup -d "$LOOP_DEV"
trap - EXIT

log_info "✓ Image complete and ready"

# ============================================================================
# Summary
# ============================================================================

log_step "SD Card Image Ready!"

image_size=$(du -h "$IMAGE_FILE" | awk '{print $1}')
log_info "Image file: $IMAGE_FILE ($image_size on disk, sparse)"
echo
log_info "Write to SD card (16 GB or larger):"
echo
echo "  sudo dd if='$IMAGE_FILE' of=/dev/sdX bs=4M status=progress conv=sparse && sync"
echo "  (Replace /dev/sdX with your SD card device — check with lsblk!)"
echo
echo "  Or use Etcher (GUI, safer): https://www.balena.io/etcher/"
echo
log_warn "Warning: Make sure to select the correct device! dd can destroy data."
echo
log_info "Once written:"
echo "  1. Insert SD card into QMTECH board, set BSEL jumpers to SD boot"
echo "  2. Power on (Ethernet connected)"
echo "  3. Serial console on UART0 at 115200 8N1"
echo "  4. Login as root:odo-miner"
echo "  5. Run: fpga_smoke_test"
echo
