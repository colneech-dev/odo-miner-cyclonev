#!/bin/bash
# build_odocrypt_lib.sh — build the OdoCrypt PoW hash as a shared library
# (libodocrypt.so) from the repo's upstream submodule, so the Python test
# harness needs no external DigiByte build.
#
# Output: tools/testnet/libodocrypt.so  (loaded automatically by lib/odo_node.py)
# Requires: g++, gcc (Linux/WSL).

set -e
cd "$(dirname "$0")"
CRYPTO="../../upstream/odo-miner/src/crypto"

if [ ! -f "$CRYPTO/odocrypt.cpp" ]; then
    echo "upstream submodule missing — run: git submodule update --init" >&2
    exit 1
fi

echo "building libodocrypt.so from $CRYPTO ..."
g++ -O2 -std=c++17 -fPIC -I"$CRYPTO" -c "$CRYPTO/odocrypt.cpp" -o /tmp/odo_o.o
gcc -O2 -fPIC -I"$CRYPTO" -c "$CRYPTO/KeccakP-800-reference.c" -o /tmp/odo_k.o
g++ -O2 -std=c++17 -fPIC -I"$CRYPTO" -shared odocrypt_wrapper.cpp /tmp/odo_o.o /tmp/odo_k.o \
    -o libodocrypt.so
echo "built: $(pwd)/libodocrypt.so"
