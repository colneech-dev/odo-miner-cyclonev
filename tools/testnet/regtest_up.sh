#!/bin/bash
# regtest_up.sh — bring a DigiByte regtest node up, ready for OdoCrypt mining.
#
# Handles the two gotchas that bite everyone:
#   1. rpcport/rpcuser must be under a [regtest] section in digibyte.conf,
#      else digibyted refuses to start.
#   2. OdoCrypt is not active until block 600 — we mine 601 with the default
#      (scrypt) algo so getblocktemplate "odo" works.
#
# Usage: DGB_BIN=/path/to/bin DATADIR=/path bash regtest_up.sh
# Env (defaults shown):
#   DGB_BIN=C:/digibyte/bin   DATADIR=C:/tmp/dgbreg   RPCPORT=18443
#
# Leaves the node running. Stop it with: digibyte-cli ... stop

set -e
DGB_BIN="${DGB_BIN:-C:/digibyte/bin}"
DATADIR="${DATADIR:-C:/tmp/dgbreg}"
RPCPORT="${RPCPORT:-18443}"
DGBD="$DGB_BIN/digibyted.exe"
CLI="$DGB_BIN/digibyte-cli.exe -datadir=$DATADIR -rpcuser=user -rpcpassword=pass -rpcport=$RPCPORT"

mkdir -p "$DATADIR"
cat > "$DATADIR/digibyte.conf" <<EOF
regtest=1
server=1
txindex=1
fallbackfee=0.0001
[regtest]
rpcuser=user
rpcpassword=pass
rpcallowip=127.0.0.1
rpcport=$RPCPORT
zmqpubhashblock=tcp://127.0.0.1:28332
EOF

if ! $CLI getblockcount >/dev/null 2>&1; then
    echo "[*] starting digibyted (regtest)..."
    "$DGBD" "-datadir=$DATADIR" >/dev/null 2>&1 &
    until $CLI getblockcount >/dev/null 2>&1; do sleep 2; done
fi

$CLI createwallet test >/dev/null 2>&1 || $CLI loadwallet test >/dev/null 2>&1 || true
ADDR=$($CLI getnewaddress)
H=$($CLI getblockcount)
if [ "$H" -lt 601 ]; then
    echo "[*] mining $((601 - H)) blocks to activate OdoCrypt..."
    $CLI generatetoaddress $((601 - H)) "$ADDR" >/dev/null
fi
echo "[OK] regtest ready: height=$($CLI getblockcount), addr=$ADDR"
echo "     verify: $CLI getblocktemplate '{\"rules\":[\"segwit\"]}' 'odo' | grep odokey"
