#!/bin/bash
# Cross-compile sw/odo-ui for the ARM target using the Buildroot toolchain.
set -e
BR="${BUILDROOT_DIR:-$HOME/buildroot-2025.11.3}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC=$(ls "$BR"/output/host/bin/*-linux-*gcc 2>/dev/null | grep -vE 'gcc-(ar|nm|ranlib)' | head -1)
[ -x "$CC" ] || { echo "ARM gcc not found under $BR/output/host/bin"; exit 1; }
echo "CC = $CC"
cd "$PROJECT_ROOT/sw/odo-ui"
make CC="$CC" clean all
echo "---"
file odo-ui
ls -la odo-ui
