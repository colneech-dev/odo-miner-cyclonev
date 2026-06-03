#!/bin/bash
# build-buildroot.sh — Automated Buildroot build for Cyclone V SoC
#
# Usage:
#   ./scripts/build-buildroot.sh
#
# Prerequisites:
#   - Buildroot 2023.11 installed (download from buildroot.org)
#   - BUILDROOT_DIR environment variable set, or pass path as arg
#
# Example:
#   BUILDROOT_DIR=~/buildroot-2023.11 ./scripts/build-buildroot.sh
#   OR
#   ./scripts/build-buildroot.sh ~/buildroot-2023.11

set -e

# Configuration
BUILDROOT_DIR="${1:-${BUILDROOT_DIR:?'Set BUILDROOT_DIR env var or pass as argument'}}"
DEFCONFIG_SRC="$(dirname "$0")/../linux/buildroot_cyclonev_defconfig"
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

# Step 1: Copy defconfig to Buildroot
log_info "Step 1: Installing defconfig..."
cp "$DEFCONFIG_SRC" "$BUILDROOT_DIR/configs/cyclonev_defconfig"
log_info "  ✓ Defconfig installed"

# Step 1.5: Clean stale configuration
cd "$BUILDROOT_DIR"
log_info "Step 1.5: Cleaning stale configuration..."
rm -f .config .config.old .auto.deps
log_info "  ✓ Cleaned"

# Step 2: Load config
log_info "Step 2: Loading configuration..."
make cyclonev_defconfig > /dev/null
log_info "  ✓ Configuration loaded"

# Step 3: Show configuration summary
log_info "Step 3: Configuration summary"
echo "  Target: ARM Cortex-A9 (Cyclone V SoC)"
echo "  Kernel: 5.15 LTS with FPGA Manager"
echo "  U-Boot: 2023.10 with SPL"
echo "  Rootfs: ext4 (256 MB)"
echo

# Step 4: Build
log_info "Step 4: Starting Buildroot build (this takes 30-90 minutes)..."
log_warn "  Do not interrupt the build process."
echo

start_time=$(date +%s)
make -j${PARALLEL_JOBS} 2>&1 | tee buildroot-build.log
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
    "output/images/socfpga_cyclone5.dtb"
    "output/images/u-boot-spl.sfp"
    "output/images/u-boot.img"
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

# Build with ARM cross-compiler
export CC=arm-linux-gnueabihf-gcc
export CXX=arm-linux-gnueabihf-g++
export CFLAGS="-O2 -march=armv7-a -mthumb"
export CXXFLAGS="-O2 -march=armv7-a -mthumb"

if make 2>&1 | tee hps-build-arm.log; then
    log_info "  ✓ HPS software built for ARM"

    # List binaries
    echo "  Built binaries:"
    ls -lh odo-miner odo-miner-watcher fpga_smoke_test miner_io_test 2>/dev/null | awk '{print "    " $9 " (" $5 ")"}'
else
    log_warn "  ⚠ HPS build failed (might be due to missing arm-linux-gnueabihf toolchain)"
    log_warn "  Install with: sudo apt-get install arm-linux-gnueabihf-gcc arm-linux-gnueabihf-g++"
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
echo "  DTB:     $BUILDROOT_DIR/output/images/socfpga_cyclone5.dtb"
echo "  Bootloader: $BUILDROOT_DIR/output/images/u-boot-spl.sfp"
echo "  Rootfs:  $BUILDROOT_DIR/output/images/rootfs.ext4"
echo
