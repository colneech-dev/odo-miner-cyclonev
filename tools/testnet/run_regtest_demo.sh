#!/bin/bash
# run_regtest_demo.sh — one-command OdoCrypt mining self-test (the reference).
#
# Brings up a regtest node, builds the OdoCrypt lib if needed, runs the solo
# Stratum bridge and the CPU reference miner, and asserts a block is mined
# end-to-end. No FPGA required. Prints "DEMO PASS" on success.
#
# This is the reference others can copy: it exercises the whole stack
# (getblocktemplate -> Stratum -> OdoCrypt hash -> submitblock) in seconds.
#
# Env (defaults shown):
#   DGB_BIN=C:/digibyte/bin   PYTHON=python3   ODOCRYPT_LIB=<auto>
#
# On Windows run the .bat instead (the node and Python are native there);
# this script targets Linux/WSL with a node reachable at $ODO_RPC_URL.

set -e
cd "$(dirname "$0")"
PYTHON="${PYTHON:-python3}"

# Build the portable hash lib from the upstream submodule if no lib is set.
if [ -z "$ODOCRYPT_LIB" ] && [ ! -f libodocrypt.so ]; then
    echo "[*] building libodocrypt.so from the upstream submodule ..."
    bash build_odocrypt_lib.sh
fi

exec "$PYTHON" run_testbed.py --demo --net regtest "$@"
