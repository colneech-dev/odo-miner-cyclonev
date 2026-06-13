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
import urllib.error
import json
import base64
import platform
import signal

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))


def rpc_call(url, user, pw, method, params=None):
    body = json.dumps({"jsonrpc": "1.0", "id": "tb", "method": method,
                       "params": params or []}).encode()
    req = urllib.request.Request(url, data=body,
                                 headers={"Content-Type": "application/json"})
    tok = base64.b64encode(f"{user}:{pw}".encode()).decode()
    req.add_header("Authorization", "Basic " + tok)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as err:
        body = err.read().decode(errors="replace") if err.fp else ""
        try:
            data = json.loads(body)
            if isinstance(data, dict) and data.get("error"):
                raise RuntimeError(
                    f"RPC error {data['error']} from {url}: {data['error']}")
        except Exception:
            raise RuntimeError(
                f"HTTP error {err.code}: {err.reason}\nResponse body: {body}")
    except urllib.error.URLError as err:
        raise RuntimeError(f"RPC connection failed: {err.reason}") from err
    if resp.get("error"):
        raise RuntimeError(resp["error"])
    return resp["result"]


def print_connection_status(rpc_func):
    try:
        netinfo = rpc_func("getnetworkinfo")
        print(f"[*] connections total: {netinfo.get('connections')}")
        if netinfo.get('networks'):
            for n in netinfo['networks']:
                print(f"    {n.get('name')} reachable={n.get('reachable')} "
                      f"limited={n.get('limited')}")
    except Exception as exc:
        print(f"[*] getnetworkinfo failed: {exc}")
    try:
        peers = rpc_func("getpeerinfo")
        if peers:
            print(f"[*] getpeerinfo returned {len(peers)} peer(s)")
            for p in peers[:8]:
                flags = []
                if p.get('inbound'):
                    flags.append('in')
                if p.get('syncnode'):
                    flags.append('sync')
                print(f"    {p.get('addr')} ping={p.get('pingtime', '?')} "
                      f"sec flags={','.join(flags)} subver={p.get('subver')}")
            if len(peers) > 8:
                print(f"    ... {len(peers) - 8} more peers")
        else:
            print("[*] no connected peers")
            try:
                added = rpc_func("getaddednodeinfo")
                if added:
                    print(f"[*] getaddednodeinfo returned {len(added)} added node entries")
                    for a in added:
                        print(f"    {a.get('addednode')} connected={a.get('connected')}")
                        for addr in a.get('addresses', []):
                            print(f"        addr={addr.get('address')} connected={addr.get('connected')}")
                else:
                    print("[*] no added nodes configured")
            except Exception as exc:
                print(f"[*] getaddednodeinfo failed: {exc}")
    except Exception as exc:
        print(f"[*] getpeerinfo failed: {exc}")


def wait_for_odo_activation(rpc_func):
    print("[*] waiting for OdoCrypt activation / sync status...")
    while True:
        try:
            tmpl = rpc_func("getblocktemplate", [{"rules": ["segwit"]}, "odo"])
            return tmpl
        except Exception as exc:
            msg = str(exc)
            if "Algorithm 'odo' is not currently active" in msg:
                print("[!] OdoCrypt is not active yet.")
                print_connection_status(rpc_func)
                print("[*] retrying in 30 seconds; press Ctrl-C to abort")
                time.sleep(30)
                continue
            raise


def write_merged_config(conf_path, net, user, pw, rpcport):
    desired_addnodes = []
    if net == "testnet":
        desired_addnodes = [
            "178.62.247.237:12033",
            "51.158.109.112:12033",
            "seed.digibyte.help:12033",
            "174.138.30.222:12033",
            "95.179.167.31:12033",
        ]
    required_values = {
        "server": "1",
        "txindex": "1",
        "fallbackfee": "0.0001",
        "rpcuser": user,
        "rpcpassword": pw,
        "rpcallowip": "127.0.0.1",
        "rpcport": str(rpcport),
        "zmqpubhashblock": "tcp://127.0.0.1:28332",
    }

    section_name = "regtest" if net == "regtest" else "test"
    new_lines = []
    if net == "testnet":
        new_lines.append("testnet=4")
    else:
        new_lines.append("regtest=1")
    new_lines.append(f"[{section_name}]")
    for key, value in required_values.items():
        new_lines.append(f"{key}={value}")

    if net == "testnet":
        new_lines.extend([
            "# testnet bootstrap peers for first connection",
            "# official DNS seeds are built into DigiByte Core:",
            "#   seed.testnet.digibyte.io",
            "#   testnet-seed.digibyte.nl",
        ])
        for addr in desired_addnodes:
            new_lines.append(f"addnode={addr}")

    with open(conf_path, "w", encoding="utf-8") as f:
        f.write("\n".join(new_lines) + "\n")
    return True


def get_running_digibyted_commands():
    if os.name == "nt":
        try:
            out = subprocess.check_output(
                ["wmic", "process", "where", "name='digibyted.exe'", "get", "CommandLine", "/value"],
                stderr=subprocess.DEVNULL,
                universal_newlines=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            return []
        return [line.split("=", 1)[1].strip() for line in out.splitlines()
                if line.startswith("CommandLine=") and line.split("=", 1)[1].strip()]
    else:
        try:
            out = subprocess.check_output(["ps", "-eo", "pid,args"],
                                          stderr=subprocess.DEVNULL,
                                          universal_newlines=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            return []
        cmds = []
        for line in out.splitlines()[1:]:
            if "digibyted" in line:
                parts = line.split(None, 1)
                if len(parts) == 2:
                    cmds.append(parts[1].strip())
                else:
                    cmds.append(parts[0].strip())
        return cmds


def kill_digibyted_processes():
    if os.name == "nt":
        subprocess.run(["taskkill", "/IM", "digibyted.exe", "/F"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    else:
        subprocess.run(["pkill", "-f", "digibyted"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)


def check_existing_digibyted(datadir, rpcport):
    commands = get_running_digibyted_commands()
    if not commands:
        return None

    exact_matches = [c for c in commands if f"-datadir={datadir}" in c]
    port_matches = [c for c in commands if f"-rpcport={rpcport}" in c]

    print("[*] detected existing digibyted process(es):")
    for cmd in commands:
        print(f"    {cmd}")

    if exact_matches:
        print("[*] one or more existing digibyted processes already use the same datadir.")
        return True
    if port_matches:
        print("[*] one or more existing digibyted processes already use the same rpcport.")
        return True

    print("[!] existing digibyted process(es) do not match this net/datadir.")
    stop = input("Stop them? [y/N]: ").strip().lower()
    if stop == "y":
        kill_digibyted_processes()
        return False
    print("[!] please stop the existing digibyted processes before continuing.")
    sys.exit(1)


def main():
    default_bin = os.environ.get("DGB_BIN",
                                 "C:\\digibyte\\bin" if os.name == "nt" else "")
    ap = argparse.ArgumentParser()
    ap.add_argument("--net", default="regtest", choices=["regtest", "testnet"])
    ap.add_argument("--dgb-bin", default=default_bin)
    ap.add_argument("--datadir", default=None)
    ap.add_argument("--rpc-port", type=int, default=None,
                    help="custom RPC port for testnet or regtest")
    ap.add_argument("--odocrypt-lib", default=os.environ.get("ODOCRYPT_LIB"))
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--wait", action="store_true",
                    help="wait for testnet sync and OdoCrypt activation before starting the bridge")
    ap.add_argument("--no-web", action="store_true", help="don't start the web view")
    ap.add_argument("--web-port", type=int, default=8080)
    a = ap.parse_args()

    net = a.net
    default_rpc = 18443 if net == "regtest" else 14026
    rpcport = a.rpc_port if a.rpc_port else default_rpc
    datadir = a.datadir or os.path.join(
        os.path.expanduser("~"), ".odo-testbed", net)
    print(f"[*] using datadir: {datadir}")
    check_existing_digibyted(datadir, rpcport)
    dgbd = os.path.join(a.dgb_bin, "digibyted" + (".exe" if os.name == "nt" else ""))
    url = f"http://127.0.0.1:{rpcport}/"
    user, pw = "user", "pass"
    if a.odocrypt_lib:
        os.environ["ODOCRYPT_LIB"] = a.odocrypt_lib
    os.environ["ODO_RPC_URL"] = url
    os.environ["ODO_RPC_USER"] = user
    os.environ["ODO_RPC_PASS"] = pw
    # Shared stats file for the bridge -> web view; reset it for a clean session.
    import tempfile
    os.environ.setdefault("ODO_STATS_FILE",
                          os.path.join(tempfile.gettempdir(), "odo_testbed_stats.json"))
    try:
        os.remove(os.environ["ODO_STATS_FILE"])
    except OSError:
        pass

    os.makedirs(datadir, exist_ok=True)
    conf_path = os.path.join(datadir, "digibyte.conf")
    print(f"[*] writing config: {conf_path}")
    write_merged_config(conf_path, net, user, pw, rpcport)
    print(f"[*] using config: {conf_path}")
    try:
        with open(conf_path, "r") as f:
            print("[*] digibyte.conf contents:")
            print(f.read().strip())
    except Exception as exc:
        print(f"[!] failed to read config: {exc}")

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
        node_args = [dgbd, f"-datadir={datadir}", f"-rpcport={rpcport}", "-rpcbind=127.0.0.1"]
        if net == "testnet":
            node_args.append("-testnet")
        else:
            node_args.append("-regtest")
        node_proc = subprocess.Popen(node_args,
                                     creationflags=flags) if os.name == "nt" \
            else subprocess.Popen(node_args,
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
    wallet_name = "test"
    def wallet_loaded(name):
        try:
            return name in rpc("listwallets")
        except Exception:
            return False

    if not wallet_loaded(wallet_name):
        try:
            rpc("createwallet", [wallet_name])
        except Exception as exc:
            print(f"[*] createwallet failed: {exc}")
            print("[*] trying to load an existing wallet instead")
            try:
                rpc("loadwallet", [wallet_name])
            except Exception as exc2:
                print(f"[!] loadwallet failed: {exc2}")
                return 1

    if not wallet_loaded(wallet_name):
        try:
            rpc("loadwallet", [wallet_name])
        except Exception as exc:
            print(f"[!] final loadwallet failed: {exc}")
            return 1

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
    if a.wait and net == "testnet":
        try:
            tmpl = wait_for_odo_activation(rpc)
        except Exception as exc:
            print(f"[!] failed while waiting for OdoCrypt activation: {exc}")
            return 1
    else:
        try:
            tmpl = rpc("getblocktemplate", [{"rules": ["segwit"]}, "odo"])
        except Exception as exc:
            print(f"[!] failed to query getblocktemplate: {exc}")
            if isinstance(exc, RuntimeError) and "Algorithm 'odo' is not currently active" in str(exc):
                try:
                    info = rpc("getblockchaininfo")
                    print(f"[*] testnet chain height = {info.get('blocks')} "
                          f"progress = {info.get('verificationprogress'):.4f}")
                except Exception:
                    pass
                print("[!] On testnet, OdoCrypt is not active until the chain reaches the activation height.")
                print_connection_status(rpc)
                if net == "testnet":
                    answer = input("Wait for sync/Odo activation and retry? [Y/n]: ").strip().lower()
                    if answer in ("", "y", "yes"):
                        try:
                            tmpl = wait_for_odo_activation(rpc)
                        except Exception as exc2:
                            print(f"[!] wait failed: {exc2}")
                            return 1
                    else:
                        return 1
                else:
                    return 1
            else:
                print("[!] check that the node is running, synced, and that the RPC port matches the config.")
                return 1
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

    # --- start the web status view (stdlib-only; replaces the old Flask web.py) ---
    web = None
    if not a.no_web:
        web = subprocess.Popen(
            [sys.executable, "-u", os.path.join(HERE, "webview.py"), str(a.web_port)],
            env=os.environ.copy())

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
            if web:
                web.terminate()
            if node_proc:
                try:
                    rpc("stop")
                except Exception:
                    pass
        print("DEMO PASS" if ok else "DEMO FAIL")
        return 0 if ok else 1

    shutdown_requested = False

    def request_shutdown(signum, frame):
        nonlocal shutdown_requested
        shutdown_requested = True

    signal.signal(signal.SIGINT, request_shutdown)
    if hasattr(signal, 'SIGTERM'):
        signal.signal(signal.SIGTERM, request_shutdown)

    print("\n" + "=" * 56)
    print(f"  TEST BED RUNNING ({net})")
    print("  Point the FPGA miner at  <this-PC-IP>:3333")
    if web:
        print(f"  Web status view:      http://127.0.0.1:{a.web_port}")
    print("  Self-test (no FPGA):  python cpu_miner.py 127.0.0.1 3333")
    print("  Ctrl-C here to stop the bridge; node keeps running.")
    print("=" * 56)
    try:
        while bridge.poll() is None and not shutdown_requested:
            time.sleep(0.2)
    except KeyboardInterrupt:
        shutdown_requested = True
    finally:
        if shutdown_requested:
            print("[*] shutdown requested, terminating bridge and web view...")
        if bridge.poll() is None:
            bridge.terminate()
        if web and web.poll() is None:
            web.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
