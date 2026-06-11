#!/usr/bin/env python3
"""
solo_stratum.py — SOLO Stratum-v1 bridge for OdoCrypt mining.

    digibyted (regtest/testnet)
        |  getblocktemplate "odo"  (consensus odokey)
        v
    solo_stratum.py  -- Stratum v1 -->  miner (cpu_miner.py, or the FPGA)
        ^                                   |
        +-------------- submitblock --------+

Single-coinbase (empty-mempool) solo pool: it pre-builds the coinbase, so it
hands the miner the whole coinbase as `coinb1` with empty `coinb2`/branches.
The miner's merkle root is then just dsha(coinbase), and the header it builds
matches the block this bridge submits.

Validates every share with the real OdoCrypt hash (lib/odo_node.py) before
submitblock — no placeholder hashing.

Protocol notes (must match hps/stratum.c on the FPGA side):
  - subscribe result: [[["mining.notify","odo"]], extranonce1, en2_size]
  - notify params: [job_id, prevhash_BE, coinb1=coinbase, coinb2="", [],
                    version_hex, nbits_hex, ntime_hex, clean]
    prevhash is sent big-endian; the miner reverses it to internal LE.
  - submit params: [worker, job_id, extranonce2, ntime_hex, nonce_hex]

Usage: python3 solo_stratum.py [regtest|testnet]   (listens on :3333)
"""

import os
import sys
import json
import socket
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from odo_node import (rpc, odocrypt_hash, build_coinbase, serialize_header,
                      assemble_block, target_from_template)

HOST, PORT = "0.0.0.0", 3333
MODE = sys.argv[1] if len(sys.argv) > 1 else "regtest"


def make_job():
    addr = rpc("getnewaddress")
    spk = rpc("getaddressinfo", [addr])["scriptPubKey"]
    tmpl = rpc("getblocktemplate", [{"rules": ["segwit"]}, "odo"])
    if tmpl.get("pow_algo") != "odo":
        raise RuntimeError("node did not return an odo template (height<600?)")
    txid, coinb1_hex, coinbase_hex = build_coinbase(tmpl, spk)
    return {
        "id": format(int(time.time()) & 0xffffffff, "08x"),
        "tmpl": tmpl,
        "merkle": txid,             # single tx -> merkle root = coinbase txid
        "coinb1": coinb1_hex,       # NON-witness -> miner's dsha(coinb1)==txid
        "coinbase_hex": coinbase_hex,  # witness -> block body
        "target": target_from_template(tmpl),
        "odokey": tmpl["odokey"],
    }


def send(conn, obj):
    conn.sendall((json.dumps(obj) + "\n").encode())


def handle(conn, addr):
    print(f"[+] miner {addr}")
    job = None
    buf = b""
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
                m, mid = msg.get("method"), msg.get("id")

                if m == "mining.subscribe":
                    send(conn, {"id": mid, "error": None,
                                "result": [[["mining.notify", "odo"]], "00", 0]})

                elif m == "mining.authorize":
                    send(conn, {"id": mid, "result": True, "error": None})
                    job = make_job()
                    t = job["tmpl"]
                    send(conn, {"id": None, "method": "mining.notify", "params": [
                        job["id"], t["previousblockhash"], job["coinb1"],
                        "", [], format(t["version"], "08x"),
                        format(int(t["bits"], 16), "08x"),
                        format(t["curtime"], "08x"), True]})
                    print(f"[*] job {job['id']} odokey={job['odokey']} "
                          f"height={t['height']}")

                elif m == "mining.submit":
                    # [worker, job_id, extranonce2, ntime_hex, nonce_hex]
                    nonce = int(msg["params"][4], 16)
                    header = serialize_header(job["tmpl"], job["merkle"], nonce)
                    h = odocrypt_hash(header, job["odokey"])
                    val = int.from_bytes(h, "little")
                    if val > job["target"]:
                        send(conn, {"id": mid, "result": False,
                                    "error": [23, "high-hash", None]})
                        continue
                    # meets target -> it's a block on regtest (share==block here)
                    block = assemble_block(header, job["coinbase_hex"])
                    res = rpc("submitblock", [block])
                    ok = res is None
                    print(f"[*] share nonce={nonce} -> "
                          f"{'BLOCK ACCEPTED' if ok else 'REJECTED %r' % res}")
                    send(conn, {"id": mid, "result": ok, "error": None})
                    if ok:
                        job = make_job()  # next block
                        t = job["tmpl"]
                        send(conn, {"id": None, "method": "mining.notify",
                                    "params": [job["id"], t["previousblockhash"],
                                    job["coinb1"], "", [],
                                    format(t["version"], "08x"),
                                    format(int(t["bits"], 16), "08x"),
                                    format(t["curtime"], "08x"), True]})
                else:
                    send(conn, {"id": mid, "result": True, "error": None})
    except Exception as e:
        print(f"[!] {addr}: {e}")
    finally:
        conn.close()
        print(f"[-] miner {addr} gone")


def main():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((HOST, PORT))
    s.listen(8)
    print(f"solo stratum :{PORT} ({MODE})")
    while True:
        c, a = s.accept()
        threading.Thread(target=handle, args=(c, a), daemon=True).start()


if __name__ == "__main__":
    main()
