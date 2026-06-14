#!/bin/bash
# run_tb.sh — build vectors with the C oracle and run the RTL known-answer TB.
#
# Usage: ./run_tb.sh            (run from hdl/tb, inside WSL/Linux)
# Requires: gcc, iverilog (e.g. ~/oss-cad-suite/bin in PATH)
#
# Exits non-zero if any vector fails.

set -e
cd "$(dirname "$0")"

REPO=$(cd ../.. && pwd)
HPS="$REPO/hps"
CRYPTO="$REPO/upstream/odo-miner/src/crypto"
SRC="$REPO/hdl/src"

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
if ! command -v "$IVERILOG" >/dev/null && [ -x "$HOME/oss-cad-suite/bin/iverilog" ]; then
    IVERILOG="$HOME/oss-cad-suite/bin/iverilog"
    VVP="$HOME/oss-cad-suite/bin/vvp"
fi

echo "=== Building vector generator ==="
gcc -O2 -Wall -I"$HPS" -I"$CRYPTO" -o gen_vectors \
    "$HPS/gen_vectors.c" "$HPS/odocrypt_state.c" \
    "$CRYPTO/KeccakP-800-reference.c"

echo "=== Building testbench ==="
"$IVERILOG" -g2005 -o tb_odocrypt_top.vvp \
    tb_odocrypt_top.v \
    "$SRC/odocrypt_top.v" \
    "$SRC/odocrypt/odocrypt_core.v" \
    "$SRC/odocrypt/odocrypt_epoch_tables.v" \
    "$SRC/keccak/keccak800.v"

# (epoch_key, nonce) pairs: a tiny key, a random-looking key, a realistic
# mainnet odokey, and the testnet key that exposed share rejections.
VECTORS=(
    "0x00000001 0x00000000"
    "0x12345678 0xCAFEBABE"
    "1748736000 0x0001E240"
    "1781308800 0x00000000"
)

fail=0
for v in "${VECTORS[@]}"; do
    set -- $v
    key=$1; nonce=$2
    dir="vec_${key}_${nonce}"
    mkdir -p "$dir"
    ./gen_vectors "$key" "$nonce" "$dir"
    echo "=== Simulating key=$key nonce=$nonce ==="
    if ! "$VVP" tb_odocrypt_top.vvp \
            +STREAM="$dir/stream.hex" \
            +HEADER="$dir/header.hex" \
            +EXPECT="$dir/expect.hex" | tee "$dir/sim.log" | grep -q '^TB_PASS$'; then
        echo "VECTOR FAILED: key=$key nonce=$nonce (see $dir/sim.log)"
        fail=1
    fi
done

if [ $fail -ne 0 ]; then
    echo "=== RESULT: FAIL ==="
    exit 1
fi
echo "=== RESULT: ALL VECTORS PASS ==="
