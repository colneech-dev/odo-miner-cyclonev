#!/bin/bash
# build-all.sh — Complete build orchestration for odo-miner-cyclonev
#
# This script coordinates building:
#   1. HPS software (Stratum daemon, FPGA bridge)
#   2. Linux rootfs (Buildroot)
#   3. SD card image (bootable image ready to write)
#
# The FPGA bitstream is built separately (Quartus is a Windows install):
#   run `bash scripts/build-fpga.sh` from Git Bash on Windows first; the
#   SD card step picks up hdl/quartus/output_files/odo_miner.rbf when it
#   exists. Epoch changes never require an FPGA rebuild (runtime tables).
#
# Usage (on Linux/WSL with Buildroot installed):
#   BUILDROOT_DIR=~/buildroot-2025.11.3 ./scripts/build-all.sh
#
# Or with all options:
#   BUILDROOT_DIR=~/buildroot-2025.11.3 \
#   IMAGE_SIZE=9216 \
#   PARALLEL_JOBS=8 \
#   ./scripts/build-all.sh
#
# On WSL the Buildroot tree must live on the Linux filesystem (e.g. ~),
# NOT under /mnt/c — the kernel build fails on case-insensitive NTFS.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}╔════════════════════════════════════════════╗${NC}"; echo -e "${BLUE}║ $*${NC}"; echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"; }
log_success() { echo -e "${GREEN}✓ $*${NC}"; }

# ============================================================================
# Welcome
# ============================================================================

echo
echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║        odo-miner-cyclonev — Complete Build Orchestrator       ║"
echo "║                                                                ║"
echo "║  This script will build:                                      ║"
echo "║    • HPS software (Stratum daemon + FPGA bridge)              ║"
echo "║    • Linux rootfs (with Buildroot)                            ║"
echo "║    • SD card image (ready to write to physical SD)            ║"
echo "║                                                                ║"
echo "║  Total time: ~2 hours (mostly Buildroot building)             ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================================
# Configuration
# ============================================================================

BUILDROOT_DIR="${BUILDROOT_DIR:?'Error: Set BUILDROOT_DIR=/path/to/buildroot-2025.11.3'}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
# 8 GB rootfs + boot/A2 partitions must fit
IMAGE_SIZE="${IMAGE_SIZE:-9216}"

echo "Configuration:"
echo "  Buildroot:    $BUILDROOT_DIR"
echo "  Parallel:     $PARALLEL_JOBS jobs"
echo "  Image size:   ${IMAGE_SIZE}MB"
echo "  Project root: $PROJECT_ROOT"
echo

# ============================================================================
# Stage 1: Build HPS Software (Host Processor System)
# ============================================================================

log_step "Stage 1/3: Building HPS Software (daemon, FPGA bridge, tests)"

cd "$PROJECT_ROOT/hps"

if [ ! -f Makefile ]; then
    log_step "ERROR: Makefile not found in $PROJECT_ROOT/hps"
    exit 1
fi

# Clean previous builds
make clean 2>/dev/null || true

# Build default targets (odod, fpga_smoke_test)
make -j"$PARALLEL_JOBS" 2>&1 | tee build-hps.log

# Check for required binaries
required_binaries=(
    "odo-miner-pipe"
    "odo-miner-pipe-uio"
    "fpga_smoke_test"
)

all_built=true
for binary in "${required_binaries[@]}"; do
    if [ -f "$binary" ]; then
        size=$(ls -lh "$binary" | awk '{print $5}')
        log_success "Built: $binary ($size)"
    else
        echo "⚠ Missing: $binary (will be skipped)"
        all_built=false
    fi
done

if [ "$all_built" = false ]; then
    echo
    echo "Note: Some binaries weren't built. This is OK if they're optional."
    echo "The required ones (odod, odo-miner) should be present."
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

cd "$PROJECT_ROOT"
log_success "Stage 1 complete"

# ============================================================================
# Stage 2: Build Linux Rootfs (Buildroot)
# ============================================================================

log_step "Stage 2/3: Building Linux Rootfs (this takes 30-90 minutes)"

echo
echo "Launching Buildroot build..."
echo "  Output: $BUILDROOT_DIR/buildroot-build.log"
echo

BUILDROOT_CMD="BUILDROOT_DIR='$BUILDROOT_DIR' PARALLEL_JOBS=$PARALLEL_JOBS bash '$SCRIPT_DIR/build-buildroot.sh'"
eval "$BUILDROOT_CMD"

log_success "Stage 2 complete"

# ============================================================================
# Stage 3: Build SD Card Image
# ============================================================================

log_step "Stage 3/3: Assembling SD Card Image"

echo
echo "Creating bootable SD card image..."
echo "  This will integrate:"
echo "    • U-Boot bootloader"
echo "    • Linux kernel + device tree"
echo "    • FPGA bitstream (if available)"
echo "    • Root filesystem with miner binaries"
echo

BUILD_SDCARD_CMD="BUILDROOT_DIR='$BUILDROOT_DIR' IMAGE_SIZE=$IMAGE_SIZE bash '$SCRIPT_DIR/build-sdcard.sh'"
eval "$BUILD_SDCARD_CMD"

log_success "Stage 3 complete"

# ============================================================================
# Final Summary
# ============================================================================

echo
echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                   BUILD COMPLETE! ✓                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo
echo "Build artifacts:"
echo "  HPS binaries:   $PROJECT_ROOT/hps/odo-miner*"
echo "  Buildroot:      $BUILDROOT_DIR/output/"
echo "  SD card image:  $PROJECT_ROOT/sdcard-output/*.img"
echo

echo "Next steps:"
echo "  1. Write SD card image to physical SD card (see build-sdcard.sh output)"
echo "  2. Insert SD card into QMTECH Cyclone V SoC board"
echo "  3. Connect Ethernet cable (for pool connectivity)"
echo "  4. Connect serial console to see boot output (optional)"
echo "  5. Power on the board"
echo "  6. Once booted, run:"
echo "       fpga_smoke_test          # Test FPGA register access"
echo "       odo-miner pool:port      # Start mining"
echo

echo "For details, see documentation:"
echo "  • docs/BUILD_LINUX.md     — Linux/Buildroot guide"
echo "  • docs/BUILD_QUARTUS.md   — FPGA/Quartus guide"
echo "  • docs/BUILD_SDCARD.md    — SD card assembly"
echo "  • docs/CODE_REVIEW.md     — Software code review"
echo

echo "Support:"
echo "  Issues? Check: https://github.com/MentalCollatz/odo-miner"
echo "  Questions? See: docs/ directory in this project"
echo
