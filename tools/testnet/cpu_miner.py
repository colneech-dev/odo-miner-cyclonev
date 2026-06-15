#!/usr/bin/env python3
"""
cpu_miner.py — reference CPU OdoCrypt miner over Stratum v1.

A stand-in for the FPGA miner: it speaks the exact Stratum dialect
solo_stratum.py serves (and that hps/stratum.c on the FPGA implements), hashes
with the consensus OdoCrypt, and submits a share. Use it to validate the
bridge end-to-end with no hardware. When the FPGA is ready, point it at the
same bridge instead of running this.

Reconstructs the header exactly as hps/stratum.c does:
  - merkle root = dsha(coinb1 + extranonce1 + extranonce2 + coinb2)
  - prevhash from notify is reversed to internal LE
  - odokey is derived from ntime: nTime - nTime % interval

Usage: python3 cpu_miner.py [host] [port] [interval] [blocks]
  interval: OdoCrypt epoch seconds (default 864000 regtest/mainnet;
            use 86400 for testnet).
  blocks:   how many blocks to mine before exiting (default 1; 0 = forever).
"""

import os
import sys
import json
import socket
import struct

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from odo_node import odocrypt_hash, dsha

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 3333
INTERVAL = int(sys.argv[3]) if len(sys.argv) > 3 else 864000
# How many blocks to mine before exiting. 0 = keep going forever.
BLOCKS = int(sys.argv[4]) if len(sys.argv) > 4 else 1

# Difficulty-1 reference target for OdoCrypt (same constant as solo_stratum.py).
_DIFF1 = 0xFFFF << 208


def main():
    s = socket.create_connection((HOST, PORT))
    f = s.makefile("rwb")

    def send(o):
        f.write((json.dumps(o) + "\n").encode())
        f.flush()

    send({"id": 1, "method": "mining.subscribe", "params": ["cpu_miner/1.0"]})
    send({"id": 2, "method": "mining.authorize", "params": ["worker", "x"]})

    extranonce1 = b""
    share_target = _DIFF1   # updated by mining.set_difficulty
    mined = 0
    while True:
        line = f.readline()
        if not line:
            print("connection closed")
            return 1
        msg = json.loads(line.decode())

        if msg.get("id") == 1 and msg.get("result"):
            # [[..]], extranonce1_hex, en2_size
            extranonce1 = bytes.fromhex(msg["result"][1]) if msg["result"][1] else b""

        if msg.get("method") == "mining.set_difficulty":
            diff = float(msg["params"][0])
            if diff > 0:
                share_target = int(_DIFF1 / diff)
            print(f"[miner] share difficulty={diff}")

        if msg.get("method") == "mining.notify":
            (job_id, prevhash_be, coinb1, coinb2, branches,
             ver_hex, nbits_hex, ntime_hex, clean) = msg["params"]

            extranonce2 = b""  # en2_size 0 in this solo bridge
            coinbase = bytes.fromhex(coinb1) + extranonce1 + extranonce2 \
                + bytes.fromhex(coinb2)
            merkle = dsha(coinbase)
            for b in branches:
                merkle = dsha(merkle + bytes.fromhex(b))

            version = int(ver_hex, 16)
            ntime = int(ntime_hex, 16)
            nbits = int(nbits_hex, 16)
            odokey = ntime - ntime % INTERVAL
            prev_internal = bytes.fromhex(prevhash_be)[::-1]

            def header(nonce):
                return (struct.pack("<I", version) + prev_internal + merkle
                        + struct.pack("<III", ntime, nbits, nonce))

            # Sweep nonces until one meets the pool's share target.
            # Using share_target (from mining.set_difficulty) rather than the
            # network target avoids false winners in regtest where nbits is
            # trivially easy but the bridge's share diff is harder.
            nonce = 0
            while nonce < (1 << 32):
                h = odocrypt_hash(header(nonce), odokey)
                if int.from_bytes(h, "little") <= share_target:
                    break
                nonce += 1
            print(f"[miner] job {job_id} odokey={odokey}: winner nonce={nonce} "
                  f"hash={h[::-1].hex()[:16]}...")
            send({"id": 4, "method": "mining.submit",
                  "params": ["worker", job_id, "", ntime_hex,
                             format(nonce, "08x")]})

        if msg.get("id") == 4:
            if msg.get("result"):
                mined += 1
                print(f"[miner] share ACCEPTED (block {mined}"
                      + (f"/{BLOCKS}" if BLOCKS else "") + ")")
                if BLOCKS and mined >= BLOCKS:
                    return 0
                # otherwise keep going — the bridge sends the next job
                # automatically after each accepted block.
            else:
                print(f"[miner] share rejected: {msg.get('error')}; continuing")


if __name__ == "__main__":
    sys.exit(main())
