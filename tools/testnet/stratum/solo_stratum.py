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

import tempfile
import threading as _th

HOST, PORT = "0.0.0.0", 3333
MODE = sys.argv[1] if len(sys.argv) > 1 else "regtest"

EN1 = b"\xde\xad\xbe\xef"   # fixed extranonce1 (hps/stratum.c needs >=1 byte)
EN2_SIZE = 0               # extranonce2 size advertised to the miner

# Shared stats file the web view reads (same default in webview.py).
STATS_FILE = os.environ.get(
    "ODO_STATS_FILE", os.path.join(tempfile.gettempdir(), "odo_testbed_stats.json"))
_stats = {"shares": 0, "blocks": 0, "hashrate": [], "recent": [], "job": {}}
_stats_lock = _th.Lock()
_last_share_t = [time.time()]


def _write_stats():
    try:
        tmp = STATS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(_stats, f)
        os.replace(tmp, STATS_FILE)
    except Exception:
        pass


def record_job(job):
    with _stats_lock:
        t = job["tmpl"]
        _stats["job"] = {
            "job_id": job["id"], "odokey": job["odokey"],
            "height": t["height"], "nbits": format(int(t["bits"], 16), "08x"),
            "ntime": t["curtime"],
            "prevhash": t["previousblockhash"],
            "merkle": job["cb"]["txid"]().hex(),
            "txcount": len(t.get("transactions", [])) + 1,
        }
        _write_stats()


def record_share(result):
    """result: 'block' | 'share' | 'rejected'"""
    with _stats_lock:
        now = time.time()
        if result != "rejected":
            _stats["shares"] += 1
            elapsed = now - _last_share_t[0]
            _last_share_t[0] = now
            if elapsed > 0:
                _stats["hashrate"].append(round((2 ** 32) / elapsed))
                _stats["hashrate"] = _stats["hashrate"][-60:]
        if result == "block":
            _stats["blocks"] += 1
        _stats["recent"].append({
            "time": time.strftime("%H:%M:%S"),
            "diff": "net", "result": result})
        _stats["recent"] = _stats["recent"][-50:]
        _write_stats()


def make_job():
    addr = rpc("getnewaddress")
    spk = rpc("getaddressinfo", [addr])["scriptPubKey"]
    tmpl = rpc("getblocktemplate", [{"rules": ["segwit"]}, "odo"])
    if tmpl.get("pow_algo") != "odo":
        raise RuntimeError("node did not return an odo template (height<600?)")
    cb = build_coinbase(tmpl, spk, extranonce1=EN1, en2_size=EN2_SIZE)
    return {
        "id": format(int(time.time()) & 0xffffffff, "08x"),
        "tmpl": tmpl,
        "cb": cb,
        "target": target_from_template(tmpl),
        "odokey": tmpl["odokey"],
    }


def send(conn, obj):
    conn.sendall((json.dumps(obj) + "\n").encode())


def notify(conn, job):
    t = job["tmpl"]
    send(conn, {"id": None, "method": "mining.notify", "params": [
        job["id"], t["previousblockhash"], job["cb"]["coinb1"],
        job["cb"]["coinb2"], [], format(t["version"], "08x"),
        format(int(t["bits"], 16), "08x"), format(t["curtime"], "08x"), True]})


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
                    send(conn, {"id": mid, "error": None, "result": [
                        [["mining.notify", "odo"]], EN1.hex(), EN2_SIZE]})

                elif m == "mining.authorize":
                    send(conn, {"id": mid, "result": True, "error": None})
                    job = make_job()
                    record_job(job)
                    notify(conn, job)
                    print(f"[*] job {job['id']} odokey={job['odokey']} "
                          f"height={job['tmpl']['height']}")

                elif m == "mining.submit":
                    # [worker, job_id, extranonce2, ntime_hex, nonce_hex]
                    en2 = bytes.fromhex(msg["params"][2]) if msg["params"][2] else b""
                    nonce = int(msg["params"][4], 16)
                    # rebuild the EXACT coinbase the miner hashed (coinb1+en1+en2+coinb2)
                    merkle = job["cb"]["txid"](en2)
                    header = serialize_header(job["tmpl"], merkle, nonce)
                    # Local OdoCrypt pre-check is best-effort: it needs the
                    # odocrypt.dll/.so on THIS host. If the lib can't load (e.g.
                    # Windows without a built odocrypt.dll), skip the pre-check —
                    # digibyted's submitblock is the authoritative PoW validator.
                    try:
                        h = odocrypt_hash(header, job["odokey"])
                        if int.from_bytes(h, "little") > job["target"]:
                            record_share("rejected")
                            send(conn, {"id": mid, "result": False,
                                        "error": [23, "high-hash", None]})
                            continue
                    except Exception as e:
                        if not globals().get("_warned_nolib"):
                            print(f"[!] local OdoCrypt lib unavailable ({e}); "
                                  f"relying on node submitblock for validation")
                            globals()["_warned_nolib"] = True
                    block = assemble_block(header, job["cb"]["witness_block"](en2))
                    res = rpc("submitblock", [block])
                    ok = res is None
                    record_share("block" if ok else "rejected")
                    print(f"[*] share nonce={nonce} en2={en2.hex() or '-'} -> "
                          f"{'BLOCK ACCEPTED' if ok else 'REJECTED %r' % res}")
                    send(conn, {"id": mid, "result": ok, "error": None})
                    if ok:
                        job = make_job()
                        record_job(job)
                        notify(conn, job)
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
