#!/bin/bash
# Regenerate odo_1782432000.v with THROUGHPUT=6 (matching hardware QSF)
REPO="/mnt/c/Users/Colin/Documents/GitHub/odo-miner-cyclonev"
VERGEN="$REPO/upstream/odo-miner/src/verilog"
PIPE="$REPO/hdl/src/pipelined"
KEY=1782432000
THROUGHPUT=6

echo "=== Rebuilding odo_gen ==="
cd "$VERGEN" && make odo_gen

echo "=== Regenerating odo_${KEY}.v with THROUGHPUT=${THROUGHPUT} ==="
./odo_gen "$KEY" "$THROUGHPUT" "odo_" > "$PIPE/odo_${KEY}.v"

echo "=== Verifying localparam THROUGHPUT in generated file ==="
grep "localparam THROUGHPUT" "$PIPE/odo_${KEY}.v"

echo "=== Verifying module name ==="
grep "^module odo_encrypt" "$PIPE/odo_${KEY}.v" | head -1

wc -l "$PIPE/odo_${KEY}.v"
echo "Done."
