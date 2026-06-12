#!/bin/bash
# build-buildroot.sh — Automated Buildroot build for Cyclone V SoC
#
# Usage:
#   ./scripts/build-buildroot.sh
#
# Prerequisites:
#   - Buildroot 2025.11.3 installed (download from buildroot.org)
#   - BUILDROOT_DIR environment variable set, or pass path as arg
#   - On WSL: Buildroot tree must live on the Linux filesystem (e.g. ~),
#     NOT under /mnt/c — the kernel build fails on case-insensitive NTFS
#
# Example:
#   BUILDROOT_DIR=~/buildroot-2025.11.3 ./scripts/build-buildroot.sh
#   OR
#   ./scripts/build-buildroot.sh ~/buildroot-2025.11.3

set -e

# Buildroot refuses to build with spaces in PATH (WSL appends the Windows
# PATH, which is full of "Program Files" entries) — use a clean one.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Configuration
BUILDROOT_DIR="${1:-${BUILDROOT_DIR:?'Set BUILDROOT_DIR env var or pass as argument'}}"
DEFCONFIG_SRC="$(dirname "$0")/../linux/buildroot_cyclonev_defconfig"
FRAGMENTS_SRC_DIR="$(dirname "$0")/../linux"
PROJECT_ROOT="$(dirname "$0")/.."
HPS_BUILD_DIR="$PROJECT_ROOT/hps"
PARALLEL_JOBS=${PARALLEL_JOBS:-4}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Sanity checks
if [ ! -d "$BUILDROOT_DIR" ]; then
    log_error "Buildroot directory not found: $BUILDROOT_DIR"
    exit 1
fi

if [ ! -f "$BUILDROOT_DIR/Makefile" ]; then
    log_error "Invalid Buildroot directory (no Makefile found)"
    exit 1
fi

if [ ! -f "$DEFCONFIG_SRC" ]; then
    log_error "Defconfig not found: $DEFCONFIG_SRC"
    exit 1
fi

if [ ! -f "$HPS_BUILD_DIR/Makefile" ]; then
    log_error "HPS build directory not found: $HPS_BUILD_DIR"
    exit 1
fi

log_info "Buildroot build script for odo-miner-cyclonev"
log_info "Buildroot dir: $BUILDROOT_DIR"
log_info "HPS source dir: $HPS_BUILD_DIR"
log_info "Parallel jobs: $PARALLEL_JOBS"
echo

# Warn if building on a Windows-mounted filesystem
case "$BUILDROOT_DIR" in
    /mnt/*)
        log_warn "Buildroot is under /mnt/* (Windows drive)."
        log_warn "The kernel build WILL fail on case-insensitive NTFS."
        log_warn "Copy the tree to the Linux filesystem first, e.g. ~/buildroot-2025.11.3"
        ;;
esac

# Step 1: Copy defconfig + kernel config fragments + board DTS to Buildroot
# (the defconfig references all of these by board/qmtech/cyclonev/ path)
log_info "Step 1: Installing defconfig, kernel fragments, and board DTS..."
cp "$DEFCONFIG_SRC" "$BUILDROOT_DIR/configs/cyclonev_defconfig"
mkdir -p "$BUILDROOT_DIR/board/qmtech/cyclonev"
cp "$FRAGMENTS_SRC_DIR/linux-wifi.fragment" \
   "$FRAGMENTS_SRC_DIR/linux-fpga.fragment" \
   "$FRAGMENTS_SRC_DIR/linux-display.fragment" \
   "$FRAGMENTS_SRC_DIR/uboot-autoboot.fragment" \
   "$FRAGMENTS_SRC_DIR/socfpga_cyclone5_qmtech_odo.dts" \
   "$BUILDROOT_DIR/board/qmtech/cyclonev/"
# Rootfs overlay (BusyBox init scripts + /etc/odod.conf). BR2_ROOTFS_OVERLAY
# in the defconfig points at board/qmtech/cyclonev/overlay, so this copy is
# REQUIRED — without it target-finalize fails and no rootfs.ext4 is produced.
rm -rf "$BUILDROOT_DIR/board/qmtech/cyclonev/overlay"
cp -r "$FRAGMENTS_SRC_DIR/overlay" "$BUILDROOT_DIR/board/qmtech/cyclonev/overlay"
chmod +x "$BUILDROOT_DIR/board/qmtech/cyclonev/overlay/etc/init.d/"S*
log_info "  ✓ Defconfig + kernel fragments + DTS + rootfs overlay installed"

# Step 1.5: Clean stale configuration
cd "$BUILDROOT_DIR"
log_info "Step 1.5: Cleaning stale configuration..."
rm -f .config .config.old .auto.deps
log_info "  ✓ Cleaned"

# Step 2: Load config
log_info "Step 2: Loading configuration..."
make cyclonev_defconfig > /dev/null
log_info "  ✓ Configuration loaded"

# Step 2.2: Optional full clean.
# Required when the toolchain selection changed since the last build
# (e.g. internal glibc -> Bootlin external); otherwise incremental is fine.
# Defaults to NO CLEAN automatically after 30 seconds, so unattended runs
# proceed without input. Force without prompting: BUILDROOT_FULL_CLEAN=1.
do_full_clean=0
if [ "${BUILDROOT_FULL_CLEAN:-0}" = "1" ]; then
    do_full_clean=1
    log_info "Step 2.2: Full clean forced via BUILDROOT_FULL_CLEAN=1"
elif [ -t 0 ]; then
    echo
    log_warn "Full 'make clean' rebuilds everything (~60-90 min, needed after a"
    log_warn "toolchain change). Incremental build is fine for config/package tweaks."
    ans=""
    if read -t 30 -r -p "Run full 'make clean' first? [y/N] (auto-continues without clean in 30s) " ans; then
        :
    else
        echo
        log_info "  No answer in 30 s — continuing WITHOUT full clean"
    fi
    case "$ans" in
        y|Y|yes|YES) do_full_clean=1 ;;
        *)           do_full_clean=0 ;;
    esac
else
    log_info "Step 2.2: Non-interactive run — skipping full clean (set BUILDROOT_FULL_CLEAN=1 to force)"
fi
if [ "$do_full_clean" = "1" ]; then
    log_info "  Running 'make clean' (download cache and ccache are kept)..."
    make clean > /dev/null
    log_info "  ✓ Full clean done"
fi

# Step 2.5: Force the kernel to pick up changed fragments / board DTS.
# Buildroot does NOT rebuild the kernel config when fragment files or the
# custom DTS change — only a package dirclean guarantees it. Cheap (~10 min)
# compared to debugging a stale-config kernel on hardware.
if [ -d output/build ] && ls -d output/build/linux-* > /dev/null 2>&1; then
    log_info "Step 2.5: Cleaning kernel package (fragments/DTS changed)..."
    make linux-dirclean > /dev/null 2>&1 || true
    log_info "  ✓ linux-dirclean done (kernel will rebuild with new config)"
fi

# Step 3: Show configuration summary
log_info "Step 3: Configuration summary"
echo "  Target:    ARM Cortex-A9 hard-float NEON (Cyclone V SX, 5CSXFC6C6U23)"
echo "  Toolchain: Bootlin external armv7-eabihf stable (gcc 14.3, glibc 2.41)"
echo "  Kernel:    6.6.26 LTS (multi_v7 + FPGA manager + Realtek USB WiFi fragments)"
echo "  U-Boot:    2023.10 with SPL (u-boot-with-spl.sfp)"
echo "  Rootfs:    ext4 (8 GB)"
echo

# Step 4: Build
log_info "Step 4: Starting Buildroot build (this takes 30-90 minutes)..."
log_warn "  Do not interrupt the build process."
echo

# Note: the Buildroot top-level make must NOT be given -j; per-package
# parallelism comes from BR2_JLEVEL in the defconfig.
start_time=$(date +%s)
make 2>&1 | tee buildroot-build.log
build_rc=$?
end_time=$(date +%s)
build_time=$((end_time - start_time))

if [ $build_rc -ne 0 ]; then
    log_error "Buildroot build failed!"
    log_error "Check buildroot-build.log for details"
    exit 1
fi

log_info "Build completed in $((build_time / 60)) minutes $((build_time % 60)) seconds"
echo

# Step 5: Verify outputs
log_info "Step 5: Verifying build artifacts..."
outputs=(
    "output/images/zImage"
    "output/images/socfpga_cyclone5_socdk.dtb"
    "output/images/socfpga_cyclone5_qmtech_odo.dtb"
    "output/images/u-boot-with-spl.sfp"
    "output/images/rootfs.ext4"
)

all_ok=true
for output in "${outputs[@]}"; do
    if [ -f "$output" ]; then
        size=$(ls -lh "$output" | awk '{print $5}')
        log_info "  ✓ $output ($size)"
    else
        log_error "  ✗ Missing: $output"
        all_ok=false
    fi
done

if [ "$all_ok" = false ]; then
    log_error "Some artifacts are missing!"
    exit 1
fi

echo
log_info "Step 6: Building HPS software (ARM binaries)..."
cd "$HPS_BUILD_DIR"

# Clean previous ARM builds (if any)
make clean > /dev/null 2>&1 || true

# Build with the Buildroot toolchain (matches the target's glibc 2.41 —
# the Ubuntu arm-linux-gnueabihf toolchain may link against a newer glibc
# than the rootfs ships)
CROSS_GCC="$BUILDROOT_DIR/output/host/bin/arm-buildroot-linux-gnueabihf-gcc"
CROSS_GXX="$BUILDROOT_DIR/output/host/bin/arm-buildroot-linux-gnueabihf-g++"
if [ ! -x "$CROSS_GCC" ]; then
    log_warn "  Buildroot toolchain not found at $CROSS_GCC, falling back to system arm-linux-gnueabihf-gcc"
    CROSS_GCC=arm-linux-gnueabihf-gcc
    CROSS_GXX=arm-linux-gnueabihf-g++
fi
export CC="$CROSS_GCC"
export CXX="$CROSS_GXX"
export CFLAGS="-O2 -march=armv7-a -mfpu=neon -mthumb"
export CXXFLAGS="-O2 -march=armv7-a -mfpu=neon -mthumb"

if make 2>&1 | tee hps-build-arm.log; then
    log_info "  ✓ HPS software built for ARM"
    # Touch UI + web dashboard (sw/) with the same toolchain
    for app in odo-ui odo-webd; do
        if make -C "$HPS_BUILD_DIR/../sw/$app" clean all >> hps-build-arm.log 2>&1; then
            log_info "  ✓ $app built for ARM"
        else
            log_warn "  ⚠ $app build failed (see hps-build-arm.log)"
        fi
    done

    # List binaries
    echo "  Built binaries:"
    ls -lh odo-miner odo-miner-watcher fpga_smoke_test miner_io_test 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'
else
    log_warn "  ⚠ HPS build failed"
    log_warn "  Check hps-build-arm.log; ensure the Buildroot build completed first"
fi

echo
log_info "=========================================="
log_info "Buildroot build completed successfully!"
log_info "=========================================="
echo
log_info "Next steps:"
echo "  1. If HPS binaries built: rootfs is ready to integrate"
echo "  2. Once Quartus finishes: copy .rbf to SD boot partition"
echo "  3. Assemble SD card image: see docs/BUILD_LINUX.md"
echo "  4. Write to SD card and test on hardware"
echo
log_info "Output files:"
echo "  Kernel:  $BUILDROOT_DIR/output/images/zImage"
echo "  DTB:     $BUILDROOT_DIR/output/images/socfpga_cyclone5_qmtech_odo.dtb (board) / socfpga_cyclone5_socdk.dtb (fallback)"
echo "  Bootloader: $BUILDROOT_DIR/output/images/u-boot-with-spl.sfp (raw A2 partition)"
echo "  Rootfs:  $BUILDROOT_DIR/output/images/rootfs.ext4"
echo
