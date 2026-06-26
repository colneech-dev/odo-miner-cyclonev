#!/bin/bash
# Deploy corrected bitstream (T=6 epoch 1782432000) to the board.
# Run from WSL after Quartus compile completes successfully.
set -e
REPO="/mnt/c/Users/builder/Documents/GitHub/odo-miner-cyclonev"
BOARD="root@${BOARD_IP:-192.168.1.37}"
RBF="$REPO/hdl/quartus/output_files/odo_miner.rbf"

# Quick pre-check: verify RBF is fresh (after the new compile)
echo "--- RBF file info ---"
ls -lh "$RBF"
echo "Expected: > 06:34 (previous build timestamp)"

cp "$REPO/tools/testnet/odo-miner" /tmp/dk && chmod 600 /tmp/dk
SSH="ssh -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $BOARD"
SCP="scp -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "--- copy RBF to board /tmp ---"
$SCP "$RBF" $BOARD:/tmp/fpga_new.rbf
echo "OK"

echo "--- mount FAT, replace fpga.rbf, reboot ---"
$SSH 'mkdir -p /mnt/boot && mount /dev/mmcblk0p1 /mnt/boot && cp /tmp/fpga_new.rbf /mnt/boot/fpga.rbf && sync && umount /mnt/boot && echo "REBOOTING" && reboot'

echo "--- waiting 45s for board to reboot and start daemon ---"
sleep 45

echo "--- verify SEED register (expect 0x6A3DC100 = epoch 1782432000) ---"
for i in 1 2 3 4 5 6; do
    result=$($SSH 'devmem 0xFF20000C 32 2>/dev/null' 2>/dev/null) && break || { echo "retry $i..."; sleep 5; }
done
echo "SEED (0xFF20000C): $result"
if [ "$result" = "0x6A3DC100" ]; then
    echo "SEED OK: bitstream epoch 1782432000 confirmed"
else
    echo "WARNING: unexpected SEED value"
fi

echo "--- check status.json ---"
sleep 5
$SSH 'cat /run/odod/status.json 2>/dev/null | grep -E "epoch|bitstream|backend|connected|hashrate|shares"' || echo "(daemon not yet ready)"
echo "DONE"
