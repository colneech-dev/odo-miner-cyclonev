#!/bin/bash
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
BOARD_IP="${BOARD_IP:-192.168.1.37}"
cp "$REPO/tools/testnet/odo-miner" /tmp/dk && chmod 600 /tmp/dk
ssh -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$BOARD_IP << 'REMOTE'
pid=$(cat /run/odod.pid 2>/dev/null)
echo "daemon pid: $pid"
echo "--- cmdline ---"
cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' '; echo
echo "--- /dev/uio0 ---"
ls -la /dev/uio0 2>/dev/null || echo "NOT FOUND"
echo "--- devmem SEED (0xFF20000C) ---"
devmem 0xFF20000C 32 2>/dev/null || echo "FAIL"
echo "--- devmem FSTATUS (0xFF200094) ---"
devmem 0xFF200094 32 2>/dev/null || echo "FAIL"
echo "--- devmem TARGET[0] (0xFF200020) ---"
devmem 0xFF200020 32 2>/dev/null || echo "FAIL"
echo "--- devmem TARGET[1] (0xFF200024) ---"
devmem 0xFF200024 32 2>/dev/null || echo "FAIL"
REMOTE
