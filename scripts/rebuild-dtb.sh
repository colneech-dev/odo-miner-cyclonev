#!/bin/bash
# rebuild-dtb.sh — recompile a single board DTS to a DTB using the kernel tree
# that Buildroot already built (has the socfpga vendor includes + dtc).
#
# Usage: bash scripts/rebuild-dtb.sh <board.dts> [output.dtb]
#   e.g. bash scripts/rebuild-dtb.sh linux/socfpga_cyclone5_qmtech_odo_headless.dts \
#                                    socfpga_cyclone5_qmtech_odo.dtb
set -e
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDROOT_DIR="${BUILDROOT_DIR:-$HOME/buildroot-2025.11.3}"
DTS_IN="$1"
DTB_OUT="${2:-$(basename "${DTS_IN%.dts}.dtb")}"

# find the kernel build dir
KDIR=$(ls -d "$BUILDROOT_DIR"/output/build/linux-* 2>/dev/null | head -1)
DTC="$KDIR/scripts/dtc/dtc"
DTSDIR="$KDIR/arch/arm/boot/dts"
echo "==> kernel: $KDIR"
[ -x "$DTC" ] || { echo "dtc not found at $DTC"; exit 1; }

# Buildroot copies the board DTS into arch/arm/boot/dts/ (top level), so its
# #include "intel/socfpga/..." resolves there. Stage our DTS the same way.
STAGE="$DTSDIR/$(basename "$DTS_IN")"
cp "$PROJECT_ROOT/$DTS_IN" "$STAGE"

echo "==> preprocessing + compiling -> $DTB_OUT"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "$DTSDIR" -I "$KDIR/include" \
    "$STAGE" | \
"$DTC" -O dtb -o "$PROJECT_ROOT/$DTB_OUT" -b 0 -@ - 2>&1 | grep -v '^$' || true

rm -f "$STAGE"
echo "==> result:"
ls -la "$PROJECT_ROOT/$DTB_OUT"
