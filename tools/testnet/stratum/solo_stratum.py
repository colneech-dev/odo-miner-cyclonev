#!/usr/bin/env python3
"""
solo_stratum.py — minimal SOLO Stratum-v1 bridge for the odo-miner FPGA.

Sits between a DigiByte Core node (regtest/testnet) and the FPGA miner:

    digibyted  --getblocktemplate-->  this bridge  --Stratum v1-->  odo-miner
       ^                                   |
       +------------- submitblock ---------+

Why this exists: DigiByte's getblocktemplate returns the consensus "odokey"
directly, so the miner and the node always agree on the OdoCrypt epoch with
ZERO formula guessing. (Miningcore recomputes the key itself and its bundled
odocrypt.cpp is an OUTDATED algorithm version — proven non-matching — so it is
NOT usable here. The FPGA's algorithm is bit-exact with DigiByte 8.26.2's own
crypto/odocrypt.cpp; see tools/testnet/README.md.)

This speaks the SAME Stratum dialect that hps/stratum.c implements. Every
byte-order decision below is annotated with the hps/stratum.c behaviour it
must agree with. It is written to be correct-by-construction but has NOT yet
been validated end-to-end against the miner — run the loopback check in
README.md before trusting it on hardware.

Usage:
    python3 solo_stratum.py [regtest|testnet]
Requires: rpc.py (RPC_URL/RPC_AUTH point at your node), a synced/initialised
node, and a wallet address. Listens on 0.0.0.0:3333.
"""

import json
import socket
import threading
import time
import hashlib
import binascii
import struct
import sys

from rpc import rpc

HOST = "0.0.0.0"
PORT = 3333
MODE = sys.argv[1] if len(sys.argv) > 1 else "regtest"


def dsha(b: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def build_job():
    """Pull a template and pre-build the single-coinbase block (solo).

    For regtest/empty-mempool blocks the merkle root is just dsha(coinbase),
    so the miner can be handed the whole coinbase as coinb1 with an empty
    coinb2 and no merkle branches.
    """
    tmpl = rpc("getblocktemplate", [{"rules": ["segwit"]}])

    # odokey: the consensus OdoCrypt key, straight from the node. This is the
    # value the FPGA must load tables for. miner.c will also derive it from
    # ntime (nTime - nTime % interval) and the two MUST match — they do, since
    # DigiByte's OdoKey() uses exactly that formula.
    odokey = tmpl["odokey"]

    # Coinbase: pay the block reward to our address. A real solo pool would
    # build this from coinbasevalue + a payout script; for bring-up we let the
    # node hand us a ready coinbase if it exposes one, else build a trivial one.
    coinbase_hex = tmpl.get("coinbase_tx_hex")
    if coinbase_hex is None:
        raise RuntimeError(
            "this node's getblocktemplate has no coinbase_tx_hex; either use "
            "the odocrypt_wrapper-patched build or extend build_job() to "
            "assemble the coinbase from coinbasevalue + payout address")
    coinbase = binascii.unhexlify(coinbase_hex)
    merkle_root = dsha(coinbase)  # internal byte order

    job = {
        "job_id": format(int(time.time()) & 0xffffffff, "x"),
        "version": tmpl["version"],
        # GBT previousblockhash is big-endian display order. hps/stratum.c
        # REVERSES whatever prevhash bytes it receives, so we must send the
        # GBT hash AS-IS (big-endian) for the miner to end up with the
        # internal little-endian order the header needs.
        "prevhash_be": tmpl["previousblockhash"],
        "coinbase_hex": coinbase_hex,            # sent as coinb1; coinb2 = ""
        "merkle_root": merkle_root,              # for our own submitblock path
        "ntime": int(tmpl["curtime"]),
        "nbits": int(tmpl["bits"], 16),
        "network_target": int(tmpl["target"], 16),
        "odokey": odokey,
        "txcount_varint": tmpl.get("txcount_varint", "01"),
        "other_txs": tmpl.get("other_txs", []),
        "clean": True,
    }
    return job


def serialize_header(job, nonce):
    # version LE | prevhash internal(32) | merkle internal(32) | ntime LE |
    # nbits LE | nonce LE  — identical layout to hps/odocrypt_header.c.
    prev_internal = binascii.unhexlify(job["prevhash_be"])[::-1]
    return struct.pack("<I", job["version"]) + prev_internal + job["merkle_root"] \
        + struct.pack("<III", job["ntime"], job["nbits"], nonce)


def submit_block(job, nonce):
    header = serialize_header(job, nonce)
    block_hex = header.hex() + job["txcount_varint"] + job["coinbase_hex"] \
        + "".join(job["other_txs"])
    return rpc("submitblock", [block_hex])


def send(conn, obj):
    conn.sendall((json.dumps(obj) + "\n").encode())


def handle_client(conn, addr):
    print(f"[+] miner connected: {addr}")
    buf = b""
    job = None
    diff_target = None

    try:
        while True:
            data = conn.recv(4096)
            if not data:
                break
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                msg = json.loads(line.decode())
                method = msg.get("method")
                mid = msg.get("id")

                if method == "mining.subscribe":
                    # Result shape matches hps/stratum.c handle_subscribe_result:
                    # it reads the 3rd quoted string as extranonce1 and the
                    # trailing number as extranonce2_size. We use a fixed empty
                    # extranonce (size 0) — the coinbase is fully pre-built.
                    send(conn, {"id": mid, "result":
                                [[["mining.notify", "odo"]], "00", 0],
                                "error": None})

                elif method == "mining.authorize":
                    send(conn, {"id": mid, "result": True, "error": None})

                    # First job after authorize. share target = network target
                    # here (solo: every valid block is the only thing that
                    # matters); set a lower diff via set_difficulty if you want
                    # progress feedback before a block is found.
                    job = build_job()
                    diff_target = job["network_target"]
                    send(conn, {"id": None, "method": "mining.notify", "params": [
                        job["job_id"],
                        job["prevhash_be"],          # miner reverses this
                        job["coinbase_hex"],         # coinb1 = full coinbase
                        "",                          # coinb2 empty
                        [],                          # no merkle branches
                        format(job["version"], "08x"),
                        format(job["nbits"], "08x"),
                        format(job["ntime"], "08x"),
                        job["clean"],
                    ]})

                elif method == "mining.submit":
                    # params: [worker, job_id, extranonce2, ntime_hex, nonce_hex]
                    nonce = int(msg["params"][5], 16)
                    header = serialize_header(job, nonce)
                    h = dsha(header)  # NOTE: PoW hash is OdoCrypt, not dsha —
                    # for real validation call the odocrypt DLL (see odocrypt.py
                    # and server.py validate_share). dsha here is a placeholder
                    # to keep this file dependency-light; wire odocrypt_hash in.
                    digest_int = int.from_bytes(h[::-1], "big")
                    accepted = digest_int <= diff_target
                    if accepted and digest_int <= job["network_target"]:
                        res = submit_block(job, nonce)
                        print("[*] BLOCK SUBMITTED:", res)
                    send(conn, {"id": mid, "result": bool(accepted),
                                "error": None})

                else:
                    send(conn, {"id": mid, "result": True, "error": None})
    except Exception as e:
        print(f"[!] client {addr} error: {e}")
    finally:
        conn.close()
        print(f"[-] miner disconnected: {addr}")


def main():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((HOST, PORT))
    s.listen(8)
    print(f"solo stratum on {HOST}:{PORT} ({MODE}) — Ctrl-C to stop")
    try:
        while True:
            conn, addr = s.accept()
            threading.Thread(target=handle_client, args=(conn, addr),
                             daemon=True).start()
    except KeyboardInterrupt:
        print("\nshutting down")


if __name__ == "__main__":
    main()
