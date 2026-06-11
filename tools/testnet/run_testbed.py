#!/usr/bin/env python3
"""
run_testbed.py — one-command OdoCrypt mining test bed.

Starts a DigiByte node + the solo Stratum bridge, ready for a miner on
127.0.0.1:3333. Cross-platform (used by start_fpga_miner.bat on Windows and
run_regtest_demo.sh on Linux) so the orchestration lives in one place.

Modes:
  (default)   bring up node + bridge, leave running for the FPGA miner.
  --demo      additionally run the CPU reference miner and assert it mines a
              block, then exit (self-test, no FPGA, no hang).

Options:
  --net {regtest,testnet}   default regtest
  --dgb-bin PATH            digibyte bin dir (default C:\\digibyte\\bin or $DGB_BIN)
  --datadir PATH            node data dir
  --odocrypt-lib PATH       odocrypt.dll/.so (default $ODOCRYPT_LIB or a local build)
  --keep                    with --demo, keep node+bridge running after the test

Handles the gotchas that bite people:
  - rpcport/rpcuser must be under the [regtest]/[test] conf section
  - OdoCrypt is not active until regtest block 600 (mines 601)
  - the getblocktemplate algo name is "odo"
"""

import os
import sys
import time
import argparse
import subprocess
import urllib.request
import json
import base64

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))


def rpc_call(url, user, pw, method, params=None):
    body = json.dumps({"jsonrpc": "1.0", "id": "tb", "method": method,
                       "params": params or []}).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    tok = base64.b64encode(f"{user}:{pw}".encode()).decode()
    req.add_header("Authorization", "Basic " + tok)
    with urllib.request.urlopen(req, timeout=30) as r:
        resp = json.load(r)
    if resp.get("error"):
        raise RuntimeError(resp["error"])
    return resp["result"]


def main():
    default_bin = os.environ.get("DGB_BIN",
                                 "C:\\digibyte\\bin" if os.name == "nt" else "")
    ap = argparse.ArgumentParser()
    ap.add_argument("--net", default="regtest", choices=["regtest", "testnet"])
    ap.add_argument("--dgb-bin", default=default_bin)
    ap.add_argument("--datadir", default=None)
    ap.add_argument("--odocrypt-lib", default=os.environ.get("ODOCRYPT_LIB"))
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    net = a.net
    rpcport = 18443 if net == "regtest" else 14022
    datadir = a.datadir or os.path.join(
        os.path.expanduser("~"), ".odo-testbed", net)
    dgbd = os.path.join(a.dgb_bin, "digibyted" + (".exe" if os.name == "nt" else ""))
    url = f"http://127.0.0.1:{rpcport}/"
    user, pw = "user", "pass"
    if a.odocrypt_lib:
        os.environ["ODOCRYPT_LIB"] = a.odocrypt_lib
    os.environ["ODO_RPC_URL"] = url
    os.environ["ODO_RPC_USER"] = user
    os.environ["ODO_RPC_PASS"] = pw

    os.makedirs(datadir, exist_ok=True)
    section = "regtest" if net == "regtest" else "test"
    with open(os.path.join(datadir, "digibyte.conf"), "w") as f:
        f.write(f"{net}=1\nserver=1\ntxindex=1\nfallbackfee=0.0001\n"
                f"[{section}]\nrpcuser={user}\nrpcpassword={pw}\n"
                f"rpcallowip=127.0.0.1\nrpcport={rpcport}\n"
                f"zmqpubhashblock=tcp://127.0.0.1:28332\n")

    def rpc(m, p=None):
        return rpc_call(url, user, pw, m, p)

    # --- start node if not already up ---
    node_proc = None
    try:
        rpc("getblockcount")
        print("[*] node already running")
    except Exception:
        print(f"[*] starting digibyted ({net}) ...")
        flags = 0
        if os.name == "nt":
            flags = 0x00000008  # DETACHED_PROCESS
        node_proc = subprocess.Popen([dgbd, f"-datadir={datadir}"],
                                     creationflags=flags) if os.name == "nt" \
            else subprocess.Popen([dgbd, f"-datadir={datadir}"],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        for _ in range(60):
            try:
                rpc("getblockcount")
                break
            except Exception:
                time.sleep(2)
        else:
            print("[!] node did not come up — check the datadir/debug.log")
            return 1

    # --- wallet + address ---
    try:
        rpc("createwallet", ["test"])
    except Exception:
        try:
            rpc("loadwallet", ["test"])
        except Exception:
            pass
    addr = rpc("getnewaddress")
    print(f"[*] payout address: {addr}")

    # --- regtest: activate OdoCrypt (block 600) ---
    if net == "regtest":
        h = rpc("getblockcount")
        if h < 601:
            print(f"[*] mining {601 - h} blocks to activate OdoCrypt ...")
            rpc("generatetoaddress", [601 - h, addr])
        print(f"[*] height = {rpc('getblockcount')}")

    # --- verify an odo template ---
    tmpl = rpc("getblocktemplate", [{"rules": ["segwit"]}, "odo"])
    if tmpl.get("pow_algo") != "odo" or "odokey" not in tmpl:
        print("[!] getblocktemplate 'odo' did not return an odo template "
              "(regtest height<600, or testnet not synced)")
        return 1
    print(f"[*] OdoCrypt template OK: odokey={tmpl['odokey']} height={tmpl['height']}")

    # --- start the bridge ---
    print("[*] starting solo Stratum bridge on 127.0.0.1:3333 ...")
    bridge = subprocess.Popen(
        [sys.executable, "-u", os.path.join(HERE, "stratum", "solo_stratum.py"), net],
        env=os.environ.copy())
    time.sleep(2)

    if a.demo:
        interval = 864000 if net in ("regtest", "mainnet") else 86400
        print("[*] DEMO: running the CPU reference miner ...")
        before = rpc("getblockcount")
        rc = subprocess.call([sys.executable, os.path.join(HERE, "cpu_miner.py"),
                              "127.0.0.1", "3333", str(interval)])
        time.sleep(1)
        after = rpc("getblockcount")
        ok = rc == 0 and after > before
        print(f"[*] node height {before} -> {after}  (miner rc={rc})")
        if not a.keep:
            bridge.terminate()
            if node_proc:
                try:
                    rpc("stop")
                except Exception:
                    pass
        print("DEMO PASS" if ok else "DEMO FAIL")
        return 0 if ok else 1

    print("\n" + "=" * 56)
    print(f"  TEST BED RUNNING ({net})")
    print("  Point the FPGA miner at  <this-PC-IP>:3333")
    print("  Self-test (no FPGA):  python cpu_miner.py 127.0.0.1 3333")
    print("  Ctrl-C here to stop the bridge; node keeps running.")
    print("=" * 56)
    try:
        bridge.wait()
    except KeyboardInterrupt:
        bridge.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
