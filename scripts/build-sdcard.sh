#!/bin/bash
# build-sdcard.sh — Automated SD card image assembly for odo-miner-cyclonev
#
# Creates a complete, bootable SD card image with:
#   - U-Boot SPL + bootloader
#   - Linux kernel + device tree
#   - FPGA bitstream
#   - Root filesystem with miner binaries
#
# Usage:
#   ./scripts/build-sdcard.sh
#
# Environment variables (optional):
#   BUILDROOT_DIR=~/buildroot-2023.11    (where Buildroot output is)
#   IMAGE_SIZE=4096                       (SD card image size in MB, default 4GB)
#   OUTPUT_DIR=~/sdcard-images            (where to save the image)
#
# Prerequisites:
#   - Buildroot built (zImage, DTB, rootfs.ext4, u-boot-spl.sfp, u-boot.img)
#   - FPGA bitstream (odo_miner.rbf)
#   - HPS binaries built (odo-miner, fpga_smoke_test, etc.)
#   - Utilities: parted, losetup, mkfs.vfat, mkfs.ext4, mkimage, rsync
#   - sudo access (for mount/unmount operations)

set -e

# ============================================================================
# Configuration & Defaults
# ============================================================================

BUILDROOT_DIR="${BUILDROOT_DIR:-${HOME}/projects/buildroot-2023.11}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HPS_BUILD_DIR="$PROJECT_ROOT/hps"
BITSTREAM_DIR="$PROJECT_ROOT/bitstreams"
IMAGE_SIZE_MB="${IMAGE_SIZE:-4096}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_ROOT}/sdcard-output}"
IMAGE_FILE="$OUTPUT_DIR/odo-miner-cyclonev-$(date +%Y%m%d-%H%M%S).img"
TEMP_BOOT_DIR="/tmp/odo-sdcard-boot-$$"
TEMP_ROOT_DIR="/tmp/odo-sdcard-root-$$"

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
    log_info "Set BUILDROOT_DIR=/path/to/buildroot-2023.11"
    exit 1
fi

required_files=(
    "$BUILDROOT_DIR/output/images/zImage"
    "$BUILDROOT_DIR/output/images/socfpga_cyclone5.dtb"
    "$BUILDROOT_DIR/output/images/u-boot-spl.sfp"
    "$BUILDROOT_DIR/output/images/u-boot.img"
    "$BUILDROOT_DIR/output/images/rootfs.ext4"
)

for f in "${required_files[@]}"; do
    if [ ! -f "$f" ]; then
        log_error "Missing: $f"
        log_info "Run Buildroot build first: BUILDROOT_DIR=... bash scripts/build-buildroot.sh"
        exit 1
    fi
done

# Find bitstream (most recent .rbf)
if [ -d "$BITSTREAM_DIR" ]; then
    BITSTREAM=$(find "$BITSTREAM_DIR" -name "*.rbf" -type f -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -z "$BITSTREAM" ]; then
        log_warn "No .rbf bitstream found in $BITSTREAM_DIR (will create blank)"
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
)

for b in "${hps_binaries[@]}"; do
    if [ ! -f "$b" ]; then
        log_warn "Missing HPS binary: $b (will not be included)"
    fi
done

log_info "✓ Buildroot artifacts found"
[ -n "$BITSTREAM" ] && log_info "✓ FPGA bitstream: $BITSTREAM" || log_warn "⚠ No FPGA bitstream"

# Check tools
required_tools=(
    "parted"
    "losetup"
    "mkfs.vfat"
    "mkfs.ext4"
    "mkimage"
    "rsync"
)

for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log_error "Missing required tool: $tool"
        exit 1
    fi
done

log_info "✓ All required tools available"

# ============================================================================
# Create Output Directory
# ============================================================================

mkdir -p "$OUTPUT_DIR"
log_info "Output directory: $OUTPUT_DIR"

# ============================================================================
# Step 1: Create Blank Image
# ============================================================================

log_step "Step 1: Creating blank SD card image (${IMAGE_SIZE_MB}MB)"

if [ -f "$IMAGE_FILE" ]; then
    log_error "Image already exists: $IMAGE_FILE"
    exit 1
fi

dd if=/dev/zero of="$IMAGE_FILE" bs=1M count=$IMAGE_SIZE_MB status=progress
log_info "✓ Image created: $IMAGE_FILE"

# ============================================================================
# Step 2: Partition Image
# ============================================================================

log_step "Step 2: Partitioning image"

parted -s "$IMAGE_FILE" mklabel msdos
parted -s "$IMAGE_FILE" mkpart primary fat32 1MiB 256MiB
parted -s "$IMAGE_FILE" mkpart primary ext4 256MiB 100%
parted -s "$IMAGE_FILE" set 1 boot on

log_info "✓ Partitions created (FAT32 boot @ 1-256MB, ext4 root @ 256MB-end)"

# ============================================================================
# Step 3: Setup Loop Devices
# ============================================================================

log_step "Step 3: Mounting partitions"

LOOP_DEV=$(losetup -f)
losetup "$LOOP_DEV" "$IMAGE_FILE"
log_info "Loop device: $LOOP_DEV"

# Wait for devices to appear
sleep 1

if [ ! -e "${LOOP_DEV}p1" ] || [ ! -e "${LOOP_DEV}p2" ]; then
    log_error "Loop device partitions not created"
    losetup -d "$LOOP_DEV"
    exit 1
fi

# Format partitions
log_info "Formatting partitions..."
mkfs.vfat -F 32 -n BOOT "${LOOP_DEV}p1" > /dev/null
mkfs.ext4 -q -L rootfs "${LOOP_DEV}p2"
log_info "✓ Partitions formatted"

# Mount partitions
mkdir -p "$TEMP_BOOT_DIR" "$TEMP_ROOT_DIR"
sudo mount "${LOOP_DEV}p1" "$TEMP_BOOT_DIR"
sudo mount "${LOOP_DEV}p2" "$TEMP_ROOT_DIR"
log_info "✓ Partitions mounted"
log_info "  Boot: $TEMP_BOOT_DIR"
log_info "  Root: $TEMP_ROOT_DIR"

# ============================================================================
# Step 4: Copy Bootloader
# ============================================================================

log_step "Step 4: Installing bootloader"

sudo cp "$BUILDROOT_DIR/output/images/u-boot-spl.sfp" "$TEMP_BOOT_DIR/u-boot-spl.sfp"
sudo cp "$BUILDROOT_DIR/output/images/u-boot.img" "$TEMP_BOOT_DIR/u-boot.img"
log_info "✓ U-Boot SPL + bootloader installed"

# ============================================================================
# Step 5: Copy Kernel & Device Tree
# ============================================================================

log_step "Step 5: Installing kernel and device tree"

sudo cp "$BUILDROOT_DIR/output/images/zImage" "$TEMP_BOOT_DIR/zImage"
sudo cp "$BUILDROOT_DIR/output/images/socfpga_cyclone5.dtb" "$TEMP_BOOT_DIR/socfpga_cyclone5.dtb"
log_info "✓ Kernel and DTB installed"

# ============================================================================
# Step 6: Copy FPGA Bitstream
# ============================================================================

log_step "Step 6: Installing FPGA bitstream"

if [ -n "$BITSTREAM" ]; then
    sudo cp "$BITSTREAM" "$TEMP_BOOT_DIR/fpga.rbf"
    log_info "✓ FPGA bitstream: $(basename "$BITSTREAM")"
else
    log_warn "⚠ No FPGA bitstream; you'll need to load it manually or copy later"
    log_info "  Copy your .rbf file to: /boot/fpga.rbf on the running system"
fi

# ============================================================================
# Step 7: Create U-Boot Boot Script
# ============================================================================

log_step "Step 7: Creating U-Boot boot script"

cat > "$TEMP_BOOT_DIR/boot.txt" <<'UBOOT'
# U-Boot boot script for odo-miner on Cyclone V SoC
#
# Sequence:
# 1. Load FPGA bitstream (optional)
# 2. Load device tree from FAT
# 3. Load kernel from FAT
# 4. Boot kernel with root on /dev/mmcblk0p2

echo "odo-miner boot script"

# Set kernel boot arguments
setenv bootargs "root=/dev/mmcblk0p2 rw rootwait earlyprintk console=ttyS0,115200n8 mem=500M"

# Load device tree
echo "Loading device tree..."
fatload mmc 0:1 ${fdtaddr_r} socfpga_cyclone5.dtb || goto failed_dtb

# Load kernel
echo "Loading kernel..."
fatload mmc 0:1 ${kernel_addr_r} zImage || goto failed_kernel

# Attempt to load FPGA bitstream if present
if test -e mmc 0:1 fpga.rbf; then
    echo "Loading FPGA bitstream..."
    fatload mmc 0:1 0x02000000 fpga.rbf
    fpga load 0 0x02000000 ${filesize}
fi

# Boot kernel
echo "Booting kernel..."
bootz ${kernel_addr_r} - ${fdtaddr_r}

failed_dtb:
    echo "ERROR: Failed to load device tree"
    goto failed

failed_kernel:
    echo "ERROR: Failed to load kernel"
    goto failed

failed:
    echo "Boot failed. Halting."
    hang
UBOOT

sudo bash -c "mkimage -T script -C none -n 'odo-miner boot' -d '$TEMP_BOOT_DIR/boot.txt' '$TEMP_BOOT_DIR/boot.scr'" > /dev/null
log_info "✓ U-Boot boot script created"

# ============================================================================
# Step 8: Populate Root Filesystem
# ============================================================================

log_step "Step 8: Installing root filesystem"

sudo rsync -av "$BUILDROOT_DIR/output/target/" "$TEMP_ROOT_DIR/" > /dev/null
log_info "✓ Root filesystem installed"

# ============================================================================
# Step 9: Install HPS Binaries
# ============================================================================

log_step "Step 9: Installing HPS miner binaries"

for binary in "${hps_binaries[@]}"; do
    if [ -f "$binary" ]; then
        sudo cp "$binary" "$TEMP_ROOT_DIR/usr/bin/$(basename "$binary")"
        sudo chmod +x "$TEMP_ROOT_DIR/usr/bin/$(basename "$binary")"
        log_info "  ✓ $(basename "$binary")"
    fi
done

# Create /home/miner directory
sudo mkdir -p "$TEMP_ROOT_DIR/home/miner"
sudo chmod 755 "$TEMP_ROOT_DIR/home/miner"

log_info "✓ Miner binaries installed at /usr/bin/odo-*"

# ============================================================================
# Step 10: Create Boot Readme
# ============================================================================

log_step "Step 10: Creating boot documentation"

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

Configure behavior via environment variables:

```bash
export ODOMIN_NONCE_RANGE=2000000      # nonces per dispatch
export ODOMIN_POLL_TIMEOUT_MS=3000     # FPGA poll timeout (ms)
export ODOMIN_EPOCH_POLL_S=5           # epoch check interval (s)
export ODOMIN_HEARTBEAT_S=60           # status log interval (s)
odo-miner pool.example.com 3333
```

## Loading FPGA Bitstream

If the bitstream wasn't pre-loaded:

```bash
# Copy your .rbf file to /boot/
cp odo_miner.rbf /boot/fpga.rbf

# Load it
fpga load 0 /boot/fpga.rbf
```

## Troubleshooting

**FPGA returns 0xFFFFFFFF (not loaded):**
- Make sure bitstream is loaded via FPGA Manager
- Check device tree has FPGA Manager enabled

**No Ethernet:**
- Check cable connection
- Try: `dhclient eth0`
- Monitor: `ethtool eth0`

**Miner binary not found:**
- Binaries are at /usr/bin/odo-*
- Check: `which odo-miner`

## Logs

- Kernel: `dmesg`
- System: `/var/log/messages`
- Network: `ifconfig` / `ip addr`

## Building/Cross-Compiling

To rebuild HPS software on the target:

```bash
# Install build tools (takes space!)
# Not included by default; run Buildroot with BR2_PACKAGE_MAKE=y

make clean
make odo-miner
```

## References

- odo-miner project: https://github.com/MentalCollatz/odo-miner
- Cyclone V SoC docs: https://www.intel.com/content/www/us/en/programmable/
- QMTECH board: https://github.com/ChinaQMTECH/QMTECH_CycloneV_SoC
README

log_info "✓ Boot documentation created"

# ============================================================================
# Step 11: Sync & Unmount
# ============================================================================

log_step "Step 11: Finalizing image"

log_info "Syncing filesystems..."
sync

log_info "Unmounting partitions..."
sudo umount "$TEMP_BOOT_DIR" "$TEMP_ROOT_DIR" 2>/dev/null || true
rmdir "$TEMP_BOOT_DIR" "$TEMP_ROOT_DIR" 2>/dev/null || true

log_info "Detaching loop device..."
losetup -d "$LOOP_DEV"

log_info "✓ Image complete and ready"

# ============================================================================
# Summary
# ============================================================================

log_step "SD Card Image Ready!"

image_size=$(ls -lh "$IMAGE_FILE" | awk '{print $5}')
log_info "Image file: $IMAGE_FILE ($image_size)"
echo
log_info "Next: Write to SD card"
echo
echo "  Option 1 - Using dd (Linux/WSL):"
echo "    sudo dd if='$IMAGE_FILE' of=/dev/sdX bs=4M status=progress && sync"
echo "    (Replace /dev/sdX with your SD card device, e.g., /dev/sdb)"
echo
echo "  Option 2 - Using Etcher (GUI, safer):"
echo "    Download: https://www.balena.io/etcher/"
echo "    1. Select image: $IMAGE_FILE"
echo "    2. Select target: Your SD card"
echo "    3. Click Flash"
echo
echo "  Option 3 - On macOS:"
echo "    sudo dd if='$IMAGE_FILE' of=/dev/rdiskX bs=4m && sync"
echo
log_warn "Warning: Make sure to select the correct device! dd can destroy data."
echo
log_info "Once written:"
echo "  1. Insert SD card into QMTECH board"
echo "  2. Power on (with Ethernet connected)"
echo "  3. Watch serial console at 115200 baud"
echo "  4. Login as root:odo-miner"
echo "  5. Run: fpga_smoke_test  (to test FPGA)"
echo "  6. Run: odo-miner pool.example.com 3333  (to start mining)"
echo
