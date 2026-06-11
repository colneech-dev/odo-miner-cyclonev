"""
odo_node.py — reusable helpers for OdoCrypt regtest/testnet testing.

Provides:
  - rpc()                  JSON-RPC client for digibyted
  - odocrypt_hash()        consensus OdoCrypt PoW hash (via odocrypt.dll/.so)
  - build_coinbase()       assemble a segwit coinbase tx from a block template
  - serialize_header()     80-byte OdoCrypt/Bitcoin block header
  - assemble_block()       header + coinbase -> submittable block hex
  - target_from_template() integer PoW target from getblocktemplate

These are deliberately dependency-light (stdlib + ctypes) so the test
harness runs anywhere a node and Python 3 are available.

The OdoCrypt hash library is located in this order:
  1. $ODOCRYPT_LIB                          (explicit path)
  2. tools/testnet/odocrypt.dll | .so       (built by build_odocrypt_lib.*)
  3. C:/digibyte-testnet/odocrypt/odocrypt.dll  (a local DigiByte build)
"""

import os
import json
import struct
import hashlib
import ctypes
import urllib.request

# ---------------------------------------------------------------- RPC

RPC_URL = os.environ.get("ODO_RPC_URL", "http://127.0.0.1:18443/")
RPC_USER = os.environ.get("ODO_RPC_USER", "user")
RPC_PASS = os.environ.get("ODO_RPC_PASS", "pass")


def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "1.0", "id": "odo", "method": method,
                       "params": params or []}).encode()
    req = urllib.request.Request(RPC_URL, data=body,
                                 headers={"Content-Type": "application/json"})
    import base64
    tok = base64.b64encode(f"{RPC_USER}:{RPC_PASS}".encode()).decode()
    req.add_header("Authorization", "Basic " + tok)
    with urllib.request.urlopen(req, timeout=30) as r:
        resp = json.load(r)
    if resp.get("error"):
        raise RuntimeError(f"RPC {method} error: {resp['error']}")
    return resp["result"]


# ---------------------------------------------------------------- OdoCrypt hash

def _find_lib():
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [
        os.environ.get("ODOCRYPT_LIB"),
        os.path.join(here, "..", "odocrypt.dll"),
        os.path.join(here, "..", "libodocrypt.so"),
        r"C:\digibyte-testnet\odocrypt\odocrypt.dll",
        r"C:\digibyte\odocrypt.dll",
    ]
    for c in cands:
        if c and os.path.exists(c):
            return c
    raise FileNotFoundError(
        "odocrypt library not found. Build it with build_odocrypt_lib.sh "
        "(.so) or build_odocrypt_lib.bat (.dll), or set $ODOCRYPT_LIB.")


_lib = None


def odocrypt_hash(header80: bytes, key: int) -> bytes:
    """Consensus OdoCrypt PoW hash of an 80-byte header. Returns 32 bytes
    in internal (little-endian) order, as DigiByte's HashOdo emits."""
    global _lib
    if _lib is None:
        _lib = ctypes.CDLL(_find_lib())
        _lib.odocrypt_hash_header.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                              ctypes.c_void_p]
        _lib.odocrypt_hash_header.restype = None
    assert len(header80) == 80
    out = ctypes.create_string_buffer(32)
    _lib.odocrypt_hash_header(ctypes.create_string_buffer(header80, 80),
                              key & 0xffffffff, out)
    return out.raw


# ---------------------------------------------------------------- serialization

def dsha(b: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def varint(n: int) -> bytes:
    if n < 0xfd:
        return bytes([n])
    if n <= 0xffff:
        return b"\xfd" + struct.pack("<H", n)
    if n <= 0xffffffff:
        return b"\xfe" + struct.pack("<I", n)
    return b"\xff" + struct.pack("<Q", n)


def push_height(h: int) -> bytes:
    """BIP34 minimal-encoded height push for the coinbase scriptSig."""
    if h == 0:
        return b"\x00"
    out = b""
    v = h
    while v:
        out += bytes([v & 0xff])
        v >>= 8
    if out[-1] & 0x80:
        out += b"\x00"
    return bytes([len(out)]) + out


def build_coinbase(tmpl, script_pubkey_hex):
    """Assemble a segwit coinbase paying coinbasevalue to script_pubkey_hex,
    including the witness commitment from the template.

    Returns (txid_internal, nonwitness_hex, witness_hex):
      txid_internal  merkle leaf = dsha(nonwitness); the header merkle root
      nonwitness_hex coinbase WITHOUT witness — send this as Stratum coinb1 so
                     the miner computes dsha(coinb1) == txid
      witness_hex    coinbase WITH witness — used to assemble the block body
    """
    height = tmpl["height"]
    value = tmpl["coinbasevalue"]
    spk = bytes.fromhex(script_pubkey_hex)
    witcommit = bytes.fromhex(tmpl["default_witness_commitment"])

    script_sig = push_height(height) + b"\x04\x00\x00\x00\x00"  # height + extranonce
    vin = (bytes(32) + b"\xff\xff\xff\xff"
           + varint(len(script_sig)) + script_sig + b"\xff\xff\xff\xff")

    out_reward = struct.pack("<Q", value) + varint(len(spk)) + spk
    out_commit = struct.pack("<Q", 0) + varint(len(witcommit)) + witcommit
    vout = b"\x02" + out_reward + out_commit

    # Non-witness serialization -> txid (this is the merkle leaf, and coinb1)
    nonwit = struct.pack("<I", 1) + b"\x01" + vin + vout + struct.pack("<I", 0)
    txid = dsha(nonwit)  # internal order

    # Witness serialization (for the block body): 1 stack item, length 0x20,
    # then the 32-byte witness reserved value.
    witness = b"\x01" + b"\x20" + bytes(32)
    full = (struct.pack("<I", 1) + b"\x00\x01" + b"\x01" + vin + vout
            + witness + struct.pack("<I", 0))
    return txid, nonwit.hex(), full.hex()


def serialize_header(tmpl, merkle_root_internal: bytes, nonce: int) -> bytes:
    prev_internal = bytes.fromhex(tmpl["previousblockhash"])[::-1]
    return (struct.pack("<I", tmpl["version"]) + prev_internal
            + merkle_root_internal
            + struct.pack("<I", tmpl["curtime"])
            + struct.pack("<I", int(tmpl["bits"], 16))
            + struct.pack("<I", nonce))


def assemble_block(header80: bytes, coinbase_hex: str) -> str:
    # single-tx block (empty mempool): header + txcount(1) + coinbase
    return header80.hex() + "01" + coinbase_hex


def target_from_template(tmpl) -> int:
    return int(tmpl["target"], 16)
