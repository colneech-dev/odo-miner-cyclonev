#!/bin/bash
# run_tb_fifo.sh — found-handoff async-FIFO regression for pipelined_miner_top.
# Compiles tb_pipe_fifo.v (which embeds a stub `miner` emitting a controlled
# burst of finds) against ONLY the wrapper — no core/keccak/odo_gen needed — and
# checks depth-8 buffering, overflow + sticky flag, in-order drain, and the level
# irq. Run from hdl/tb in WSL/Linux. Fast (<1 s); safe for CI.
set -e
cd "$(dirname "$0")"

PIPE="$(cd ../.. && pwd)/hdl/src/pipelined"

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
if ! command -v "$IVERILOG" >/dev/null && [ -x "$HOME/oss-cad-suite/bin/iverilog" ]; then
    IVERILOG="$HOME/oss-cad-suite/bin/iverilog"; VVP="$HOME/oss-cad-suite/bin/vvp"
fi

echo "=== Building FIFO testbench ==="
# ODOKEY is only read back at SEED here; value is irrelevant. odo_miner_core.v is
# intentionally omitted so the stub `miner` in tb_pipe_fifo.v is used instead.
"$IVERILOG" -g2005 -DODOKEY=1 -o tb_fifo.vvp \
    tb_pipe_fifo.v \
    "$PIPE/pipelined_miner_top.v"

echo "=== Simulating ==="
"$VVP" tb_fifo.vvp | tee tb_fifo.log

if grep -q '^TB_FIFO_PASS' tb_fifo.log; then
    echo "=== FIFO TB: PASS ==="
else
    echo "=== FIFO TB: FAIL ==="; exit 1
fi
