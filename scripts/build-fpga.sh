#!/bin/bash
# build-fpga.sh — one-command FPGA bitstream build for odo-miner-cyclonev.
#
# Runs the full flow in the right order with the two gotchas handled:
#   1. Known-answer testbench (Icarus, WSL) — proves the RTL still produces
#      bit-exact upstream OdoCrypt hashes BEFORE spending an hour in Quartus.
#   2. qsys-generate — REQUIRED after any RTL edit: Platform Designer COPIES
#      hdl/src sources into soc_system/synthesis/submodules/, so skipping
#      this step silently compiles stale RTL.
#   3. quartus_sh --flow compile — synthesis through assembler (.rbf).
#   4. Sanity checks: fitter success, S-boxes actually in block RAM,
#      setup timing met on the 50 MHz fabric clock.
#
# Run from Git Bash on Windows (Quartus is a Windows install):
#   bash scripts/build-fpga.sh
#
# Options (environment):
#   QUARTUS_ROOT=/c/altera_lite/25.1std   Quartus installation
#   SKIP_TB=1                             skip the simulation gate (not advised)
#
# Output: hdl/quartus/output_files/odo_miner.rbf
#   -> copy to the SD card FAT partition as fpga.rbf (build-sdcard.sh does
#      this automatically when the file exists).
#
# When does the FPGA need rebuilding? ONLY when RTL/Qsys/pins change.
# OdoCrypt epoch changes do NOT require a rebuild — tables load at runtime.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUARTUS_ROOT="${QUARTUS_ROOT:-/c/altera_lite/25.1std}"

QSYS_BIN="$QUARTUS_ROOT/quartus/sopc_builder/bin"
QUARTUS_BIN="$QUARTUS_ROOT/quartus/bin64"

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; YEL='\033[1;33m'; NC='\033[0m'
info() { echo -e "${BLUE}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YEL}[!]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

[ -x "$QUARTUS_BIN/quartus_sh.exe" ] || die "Quartus not found at $QUARTUS_ROOT (set QUARTUS_ROOT)"

# ----------------------------------------------------------------------------
# Step 1: simulation gate
# ----------------------------------------------------------------------------
if [ "${SKIP_TB:-0}" = "1" ]; then
    warn "Step 1: SKIPPING the known-answer testbench (SKIP_TB=1)"
elif command -v wsl.exe > /dev/null 2>&1; then
    info "Step 1: Known-answer testbench (Icarus in WSL)..."
    TB_DIR_WSL=$(echo "$PROJECT_ROOT/hdl/tb" | sed 's|^/\([a-z]\)/|/mnt/\1/|')
    if wsl.exe -e bash -lc "cd '$TB_DIR_WSL' && ./run_tb.sh" 2>&1 | grep -q "ALL VECTORS PASS"; then
        ok "RTL matches the upstream OdoCrypt reference (all vectors)"
    else
        die "Testbench failed — fix the RTL before synthesizing (or SKIP_TB=1 to override)"
    fi
else
    warn "Step 1: WSL not available — skipping the simulation gate"
fi

# ----------------------------------------------------------------------------
# Step 2: regenerate the Platform Designer system (copies RTL into submodules)
# ----------------------------------------------------------------------------
info "Step 2: qsys-generate (refreshes the RTL copies the compile actually uses)..."
cd "$PROJECT_ROOT/hdl/qsys"
PATH="$QSYS_BIN:$PATH" qsys-generate soc_system.qsys --synthesis=VERILOG \
    --output-directory=soc_system --search-path="$(pwd),\$" > /tmp/qsys-gen.log 2>&1 \
    || die "qsys-generate failed (see /tmp/qsys-gen.log)"
for f in odocrypt_top odocrypt_core odocrypt_epoch_tables odocrypt_sbox_bank keccak800; do
    src_md5=$(md5sum "../src/"*"/$f.v" "../src/$f.v" 2>/dev/null | head -1 | cut -d' ' -f1)
    gen_md5=$(md5sum "soc_system/synthesis/submodules/$f.v" 2>/dev/null | cut -d' ' -f1)
    [ "$src_md5" = "$gen_md5" ] || die "stale submodule copy: $f.v (qsys did not refresh it)"
done
ok "Platform Designer system generated; submodule copies verified current"

# ----------------------------------------------------------------------------
# Step 3: full Quartus compile (30-60 min)
# ----------------------------------------------------------------------------
info "Step 3: Quartus full compile (synthesis -> fitter -> timing -> .rbf)..."
cd "$PROJECT_ROOT/hdl/quartus"
"$QUARTUS_BIN/quartus_sh.exe" --flow compile odo_miner > /tmp/quartus-flow.log 2>&1 \
    || die "Quartus flow failed (see /tmp/quartus-flow.log and output_files/*.rpt)"

# ----------------------------------------------------------------------------
# Step 4: sanity checks
# ----------------------------------------------------------------------------
info "Step 4: Checking results..."
grep -q "Fitter Status : Successful" output_files/odo_miner.fit.summary \
    || die "Fitter failed — see output_files/odo_miner.fit.rpt"

ram_blocks=$(grep -oE "Total RAM Blocks : [0-9]+" output_files/odo_miner.fit.summary | grep -oE "[0-9]+$" || echo 0)
[ "$ram_blocks" -ge 60 ] \
    || die "Only $ram_blocks RAM blocks used (expected >=60) — S-box BRAM inference regressed; see docs/TODO.md fit history"

if grep -A2 "Setup 'clk_50'" output_files/odo_miner.sta.summary | grep -q "Slack : -"; then
    die "Setup timing FAILED on clk_50 — see output_files/odo_miner.sta.rpt"
fi

alm=$(grep -oE "Logic utilization \(in ALMs\) : [0-9,]+ / [0-9,]+" output_files/odo_miner.fit.summary || true)
ok "Fit successful ($alm; $ram_blocks RAM blocks; timing met)"
ok "Bitstream: hdl/quartus/output_files/odo_miner.rbf"
echo
echo "Next: copy to the SD card boot partition as fpga.rbf"
echo "  (scripts/build-sdcard.sh picks it up automatically)"
