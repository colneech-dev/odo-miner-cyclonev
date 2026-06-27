#!/bin/bash
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
BOARD_IP="${BOARD_IP:-192.168.1.37}"
cp "$REPO/tools/testnet/odo-miner" /tmp/dk && chmod 600 /tmp/dk
ssh -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$BOARD_IP << 'REMOTE'
echo "--- fix pool port 5103 -> 5003 ---"
sed -i 's/ODOD_POOL_PORT=5103/ODOD_POOL_PORT=5003/' /etc/odod.conf
grep ODOD_POOL_PORT /etc/odod.conf

echo "--- restart daemon ---"
/etc/init.d/S90odod restart 2>&1
sleep 5

echo "--- verify ---"
cat /run/odod/status.json 2>/dev/null | grep -E '"hashrate|shares|epoch|connected|backend"'
echo "---"
cat /run/odod/status.json 2>/dev/null | grep -E 'hashrate|shares_sub|epoch|connected|backend'
REMOTE
