#!/usr/bin/env python3
"""
regtest_selftest.py — prove the full OdoCrypt consensus loop works.

Mines exactly one regtest block on the local DigiByte node using the
consensus OdoCrypt hash, entirely in Python (CPU), and asserts the node
accepts it. This validates, with no FPGA and no Stratum:

    getblocktemplate("odo") -> assemble block -> OdoCrypt hash -> submitblock

If this passes, the algorithm, the odokey, the header layout, and block
assembly are all correct against the real validator. It is the foundation
the Stratum bridge and the FPGA miner build on.

Prereqs: a regtest node past block 600 (run scripts/regtest_up.sh), and the
odocrypt library (see lib/odo_node.py for how it's located).

Usage: python3 regtest_selftest.py
Exit 0 + "SELFTEST PASS" on success.
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))

from odo_node import (rpc, odocrypt_hash, build_coinbase, serialize_header,
                      assemble_block, target_from_template)


def main():
    info = rpc("getblockchaininfo")
    if info["chain"] != "regtest":
        print("refusing to run outside regtest (chain=%s)" % info["chain"])
        return 1
    if info["blocks"] < 600:
        print("OdoCrypt not active yet (height %d < 600). Run regtest_up.sh"
              % info["blocks"])
        return 1

    addr = rpc("getnewaddress")
    spk = rpc("getaddressinfo", [addr])["scriptPubKey"]

    tmpl = rpc("getblocktemplate", [{"rules": ["segwit"]}, "odo"])
    if tmpl.get("pow_algo") != "odo" or "odokey" not in tmpl:
        print("template is not odo (pow_algo=%s, odokey=%s) — wrong algo name?"
              % (tmpl.get("pow_algo"), tmpl.get("odokey")))
        return 1

    odokey = tmpl["odokey"]
    target = target_from_template(tmpl)
    print("height=%d odokey=%d target=%064x" % (tmpl["height"], odokey, target))

    cb = build_coinbase(tmpl, spk)
    merkle = cb["txid"]()          # single tx -> merkle root is the coinbase txid
    coinbase_hex = cb["witness_block"]()

    start = rpc("getblockcount")
    nonce = 0
    while nonce < 0x100000:  # regtest target is trivial; found almost instantly
        header = serialize_header(tmpl, merkle, nonce)
        h = odocrypt_hash(header, odokey)
        if int.from_bytes(h, "little") <= target:
            break
        nonce += 1
    else:
        print("no nonce found in range — unexpected on regtest")
        return 1

    print("found nonce=%d hash=%s" % (nonce, h[::-1].hex()))
    block_hex = assemble_block(serialize_header(tmpl, merkle, nonce), coinbase_hex)
    res = rpc("submitblock", [block_hex])

    if res is not None:
        print("submitblock REJECTED: %r" % res)
        return 1
    end = rpc("getblockcount")
    if end != start + 1:
        print("block not accepted (height %d -> %d)" % (start, end))
        return 1

    print("block accepted: height %d -> %d" % (start, end))
    print("SELFTEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
