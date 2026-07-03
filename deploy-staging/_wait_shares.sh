#!/bin/bash
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
BOARD_IP="${BOARD_IP:-<board-ip>}"
cp "$REPO/tools/testnet/odo-miner" /tmp/dk && chmod 600 /tmp/dk
# wait 90s then check
sleep 90
ssh -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$BOARD_IP \
  'cat /run/odod/status.json 2>/dev/null | grep -E "hashrate|shares|epoch|backend|connected"'
