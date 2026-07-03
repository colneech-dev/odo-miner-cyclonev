#!/bin/bash
set -e
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
BOARD="root@${BOARD_IP:-<board-ip>}"
cp "$REPO/tools/testnet/odo-miner" /tmp/dk && chmod 600 /tmp/dk
SSH="ssh -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $BOARD"
SCP="scp -i /tmp/dk -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Strip CRLF from init script (edited on Windows)
sed 's/\r//' "$REPO/linux/overlay/etc/init.d/S90odod" > /tmp/S90odod
chmod +x /tmp/S90odod

echo "--- init script ---"
$SCP /tmp/S90odod $BOARD:/etc/init.d/S90odod && echo "OK" || echo "FAIL"

echo "--- stop odo-ui ---"
$SSH 'pkill odo-ui 2>/dev/null; sleep 0.3; true'

echo "--- odo-ui binary ---"
$SCP "$REPO/deploy-staging/odo-ui" $BOARD:/usr/bin/odo-ui && echo "OK" || echo "FAIL"
$SSH 'chmod +x /usr/bin/odo-ui'

echo "--- web UI ---"
$SCP "$REPO/linux/overlay/etc/odo-web/index.html" $BOARD:/etc/odo-web/index.html && echo "OK" || echo "FAIL"

echo "--- restart daemon ---"
$SSH '/etc/init.d/S90odod restart 2>&1'
sleep 3

echo "--- verify ---"
$SSH 'cat /run/odod/status.json 2>/dev/null | grep -E "backend|epoch|connected"'
echo "DONE"
