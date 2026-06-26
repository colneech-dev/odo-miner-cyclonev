#!/bin/bash
REPO="/mnt/c/Users/builder/Documents/GitHub/odo-miner-cyclonev"
cd "$REPO/hdl/tb"
sed 's/\r//' run_tb_pipe.sh > run_tb_pipe_lf.sh
chmod +x run_tb_pipe_lf.sh
echo "=== Testing epoch 1748736000 (should PASS - was working epoch) ==="
KEY=1748736000 bash run_tb_pipe_lf.sh 2>&1 | tail -8
echo ""
echo "=== Testing epoch 1782432000 (newly regenerated T=6 file) ==="
KEY=1782432000 bash run_tb_pipe_lf.sh 2>&1 | tail -8
