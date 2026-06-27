#!/bin/bash
# run_tb_pipe.sh — P1.2 functional gate for the pipelined Avalon wrapper.
# Builds the oracle sweeper, generates header/target/expect for one epoch,
# compiles tb_pipelined_miner against the pipelined RTL, and checks the core
# finds the oracle's first-qualifying nonce. Run from hdl/tb in WSL/Linux.
set -e
cd "$(dirname "$0")"

REPO=$(cd ../.. && pwd)
HPS="$REPO/hps"
CRYPTO="$REPO/third_party/odo-miner/src/crypto"
PIPE="$REPO/hdl/src/pipelined"
VERGEN="$REPO/third_party/odo-miner/src/verilog"
QSF="$REPO/hdl/quartus/odo_miner.qsf"

# Read THROUGHPUT and ODOKEY from the QSF so testbench matches deployed config.
_QSF_T=$(grep 'VERILOG_MACRO.*THROUGHPUT=' "$QSF" | sed 's/.*THROUGHPUT=\([0-9]*\).*/\1/')
_QSF_K=$(grep 'VERILOG_MACRO.*ODOKEY=' "$QSF" | sed 's/.*ODOKEY=\([0-9]*\).*/\1/')
THROUGHPUT=${THROUGHPUT:-${_QSF_T:-6}}   # hash-pipeline fold (must match QSF)
KEY=${KEY:-${_QSF_K:-1782432000}}        # epoch seed (must match baked bitstream)
TMSB=${TMSB:-16}                         # target MSB byte (looser = faster sim)
echo "=== Using QSF config: THROUGHPUT=$THROUGHPUT KEY=$KEY ==="

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
if ! command -v "$IVERILOG" >/dev/null && [ -x "$HOME/oss-cad-suite/bin/iverilog" ]; then
    IVERILOG="$HOME/oss-cad-suite/bin/iverilog"; VVP="$HOME/oss-cad-suite/bin/vvp"
fi

echo "=== Building oracle sweeper ==="
gcc -O2 -I"$HPS" -I"$CRYPTO" -o gen_vectors_pipe \
    gen_vectors_pipe.c "$HPS/odocrypt_state.c" "$CRYPTO/KeccakP-800-reference.c"

dir="vecpipe_${KEY}"; mkdir -p "$dir"
echo "=== Generating vectors (key=$KEY target_msb=$TMSB) ==="
./gen_vectors_pipe gen "$KEY" "$TMSB" "$dir"

if [ ! -f "$PIPE/odo_${KEY}.v" ]; then
    echo "=== Generating epoch RTL odo_${KEY}.v ==="
    ( cd "$VERGEN" && make odo_gen >/dev/null && ./odo_gen "$KEY" 6 "odo_" > "$PIPE/odo_${KEY}.v" )
fi

echo "=== Building testbench ==="
"$IVERILOG" -g2005 -DTHROUGHPUT="$THROUGHPUT" -DODOKEY="$KEY" -o tb_pipe.vvp \
    tb_pipelined_miner.v \
    "$PIPE/pipelined_miner_top.v" \
    "$PIPE/odo_miner_core.v" \
    "$PIPE/keccak800.v" \
    "$PIPE/odo_${KEY}.v"

echo "=== Simulating ==="
"$VVP" tb_pipe.vvp \
    +HEADER="$dir/header.hex" +TARGET="$dir/target.hex" \
    | tee "$dir/sim.log"

if ! grep -q '^TB_FOUND$' "$dir/sim.log"; then
    echo "=== PIPE TB: FAIL (no nonce found) ==="; exit 1
fi

NONCE=$(grep -oE 'FOUND_NONCE=[0-9a-f]+' "$dir/sim.log" | head -1 | cut -d= -f2)
echo "=== Verifying found nonce 0x$NONCE against the oracle ==="
if ./gen_vectors_pipe verify "$KEY" "$TMSB" "0x$NONCE"; then
    echo "=== PIPE TB: PASS (RTL nonce is a valid oracle solution) ==="
else
    echo "=== PIPE TB: FAIL (RTL nonce does not satisfy the oracle) ==="; exit 1
fi
