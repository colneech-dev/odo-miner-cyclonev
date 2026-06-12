#!/bin/bash
# rebuild-uboot.sh — rebuild ONLY U-Boot after changing the board defconfig
# (socfpga_cyclone5 -> socfpga_de10_nano). Produces a fresh
# u-boot-with-spl.sfp with the DE10-Nano DDR3/pinmux/PLL/IOCSR handoff.
#
# Usage: BUILDROOT_DIR=~/buildroot-2025.11.3 bash scripts/rebuild-uboot.sh
set -e

# WSL interop PATH can contain Windows dirs with spaces -> breaks Buildroot.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDROOT_DIR="${BUILDROOT_DIR:-$HOME/buildroot-2025.11.3}"
DEFCONFIG_SRC="$PROJECT_ROOT/linux/buildroot_cyclonev_defconfig"

echo "==> project:   $PROJECT_ROOT"
echo "==> buildroot: $BUILDROOT_DIR"

# 1. Refresh the defconfig + U-Boot config fragment in Buildroot, regen .config
cp "$DEFCONFIG_SRC" "$BUILDROOT_DIR/configs/cyclonev_defconfig"
mkdir -p "$BUILDROOT_DIR/board/qmtech/cyclonev"
cp "$PROJECT_ROOT/linux/uboot-autoboot.fragment" \
   "$BUILDROOT_DIR/board/qmtech/cyclonev/"
cd "$BUILDROOT_DIR"
echo "==> regenerating .config"
make cyclonev_defconfig > /dev/null

# 2. Confirm the new board defconfig took
echo -n "==> U-Boot board defconfig now: "
grep BR2_TARGET_UBOOT_BOARD_DEFCONFIG .config

# 3. Force U-Boot to rebuild from scratch (config changed)
echo "==> uboot-dirclean + rebuild (this is the only slow part, ~2-4 min)"
make uboot-dirclean > /dev/null
make uboot

# 4. Verify the artifact
echo
echo "==> result:"
ls -la "$BUILDROOT_DIR/output/images/u-boot-with-spl.sfp"
echo
echo "U-Boot rebuilt with the DE10-Nano preloader."
echo "Next: rebuild the SD image, then re-flash:"
echo "  OUTPUT_DIR=~/sdcard-images BUILDROOT_DIR=$BUILDROOT_DIR bash scripts/build-sdcard.sh"
