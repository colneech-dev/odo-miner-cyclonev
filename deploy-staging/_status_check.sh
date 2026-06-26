#!/bin/bash
REPO="/mnt/c/Users/builder/Documents/GitHub/odo-miner-cyclonev"
BOARD_IP="${BOARD_IP:-192.168.1.37}"
cp "$REPO/tools/testnet/odo-miner" /tmp/dk && chmod 600 /tmp/dk
ssh -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$BOARD_IP \
  'cat /run/odod/status.json 2>/dev/null | grep -E "hashrate|epoch|backend|connected|shares|temp"'
