#!/bin/bash
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
BOARD_IP="${BOARD_IP:-<board-ip>}"
cp "$REPO/tools/testnet/odo-miner" /tmp/dk && chmod 600 /tmp/dk
ssh -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$BOARD_IP << 'REMOTE'
echo "--- /etc/odod.conf ---"
cat /etc/odod.conf 2>/dev/null
echo "--- correct registers ---"
echo "CONTROL  (0xFF200000):" $(devmem 0xFF200000 32 2>/dev/null)
echo "STATUS   (0xFF200004):" $(devmem 0xFF200004 32 2>/dev/null)
echo "VERSION  (0xFF200008):" $(devmem 0xFF200008 32 2>/dev/null)
echo "SEED     (0xFF20000C):" $(devmem 0xFF20000C 32 2>/dev/null)
echo "TARGET[0](0xFF200020):" $(devmem 0xFF200020 32 2>/dev/null)
echo "TARGET[7](0xFF20003C):" $(devmem 0xFF20003C 32 2>/dev/null)
echo "FSTATUS  (0xFF200094):" $(devmem 0xFF200094 32 2>/dev/null)
REMOTE
