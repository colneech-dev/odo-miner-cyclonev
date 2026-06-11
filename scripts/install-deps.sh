#!/bin/bash
# install-deps.sh — install every Linux/WSL build dependency for
# odo-miner-cyclonev in one shot. Run once per WSL/Linux machine.
#
# Covers:
#   - Buildroot (kernel, U-Boot, rootfs) build
#   - SD-card image assembly (build-sdcard.sh)
#   - HPS software + test-harness compilation
#
# NOT covered (separate, non-apt installs):
#   - Icarus Verilog for the RTL testbench  -> OSS CAD Suite, see
#     docs/SETUP_FROM_SCRATCH.md
#   - Quartus (Windows install, for the bitstream)
#
# Usage: bash scripts/install-deps.sh

set -e

PKGS=(
    # toolchain + general build utilities
    build-essential git wget curl bc file rsync cpio unzip
    # Python (Buildroot host scripts, test harness)
    python3
    # Buildroot kernel / U-Boot menuconfig + build
    libncurses-dev flex bison libssl-dev
    # SD-card imaging: mkfs.vfat (dosfstools), mkimage (u-boot-tools),
    # sfdisk/losetup (util-linux), e2fsck/resize2fs (e2fsprogs)
    dosfstools mtools e2fsprogs util-linux u-boot-tools
)

echo "==> apt update"
sudo apt-get update
echo "==> installing: ${PKGS[*]}"
sudo apt-get install -y "${PKGS[@]}"

echo
echo "Build dependencies installed."
echo "Still needed separately (see docs/SETUP_FROM_SCRATCH.md):"
echo "  - Icarus Verilog (RTL testbench)  : OSS CAD Suite download"
echo "  - Quartus Prime Lite (bitstream)  : Windows install"
