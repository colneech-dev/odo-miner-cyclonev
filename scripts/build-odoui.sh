#!/bin/bash
# Cross-compile sw/odo-ui for the ARM target.
#
# Preferred: Buildroot toolchain (arm-buildroot-linux-gnueabi-gcc).
# Fallback:  system arm-linux-gnueabihf-gcc (apt install gcc-arm-linux-gnueabihf).
#
# NOTE: The Buildroot wrapper at output/host/bin/arm-buildroot-linux-gnueabi-gcc
# uses an external Bootlin toolchain whose sysroot only has kernel headers — not
# glibc. If you get "fatal error: stdio.h: No such file or directory", the Buildroot
# sysroot is incomplete. Use the system cross-compiler (fallback below) instead.
# In WSL, /tmp may be full; set TMPDIR=/mnt/c/tmp/odoui-build before running.
set -e
BR="${BUILDROOT_DIR:-$HOME/buildroot-2025.11.3}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CC=$(ls "$BR"/output/host/bin/*-linux-*gcc 2>/dev/null | grep -vE 'gcc-(ar|nm|ranlib)' | head -1)
if [ -x "$CC" ]; then
    # Quick sysroot sanity check
    if ! echo '#include <stdio.h>' | "$CC" -E - >/dev/null 2>&1; then
        echo "WARNING: Buildroot toolchain sysroot missing glibc headers — falling back to system cross-compiler"
        CC=""
    fi
fi

if [ -z "$CC" ]; then
    CC=$(command -v arm-linux-gnueabihf-gcc 2>/dev/null || true)
    [ -x "$CC" ] || { echo "No ARM gcc found. Install with: sudo apt install gcc-arm-linux-gnueabihf"; exit 1; }
fi

echo "CC = $CC"
cd "$PROJECT_ROOT/sw/odo-ui"
make CC="$CC" clean all
echo "---"
file odo-ui
ls -la odo-ui
