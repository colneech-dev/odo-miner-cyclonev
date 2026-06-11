# Testnet / solo-mining harness

Run the OdoCrypt FPGA miner against your own DigiByte node (regtest or
testnet) — no public pool, no third-party software, consensus-correct.

```
 digibyted (regtest/testnet)
     |  getblocktemplate  -> includes the consensus "odokey"
     v
 solo_stratum.py  (this dir)  -- Stratum v1 -->  odo-miner (FPGA, hps/)
     ^                                                |
     +------------------ submitblock ----------------+
```

## Why this, and not Miningcore

The OdoCrypt algorithm the FPGA implements is **bit-exact with DigiByte Core
8.26.2's own `crypto/odocrypt.cpp`** (proven: same 32-byte digest for a fixed
key+header, cross-checked against `hps/odocrypt_state.c` which `make check`
verifies against upstream). So the FPGA produces consensus-valid hashes.

Miningcore was evaluated and rejected for bring-up: its bundled
`odocrypt.cpp` used a *different, simplified RNG* (not the consensus
`OdoRandom`) and its `Odocrypt.cs` derived the epoch key as `nTime / interval`
instead of `nTime - nTime % interval`. Both bugs were fixed in the miningcore
repo (with a standalone test harness), but the **node + solo bridge** here is
the simpler, self-contained path: the node hands us `odokey` directly, so the
miner and validator can never disagree about the epoch.

## OdoCrypt key (epoch) — the thing everyone must agree on

DigiByte consensus (`src/primitives/block.cpp`):
```cpp
uint32_t OdoKey(params, nTime) { return nTime - nTime % params.nOdoShapechangeInterval; }
```
Interval per network (verified against DigiByte 8.26.2): mainnet 864000 (10d),
testnet 86400 (1d), **regtest 864000 (10d, same as mainnet in this build)**.
NOTE: OdoCrypt only activates at block 600 on regtest — mine 601 scrypt blocks
first, then `getblocktemplate {...} 'odo'` returns a real odo template + odokey.

`getblocktemplate` returns this as the `odokey` field; `solo_stratum.py`
passes it through and `hps/miner.c` derives the same value from `nTime`.

## Contents

| File | Purpose |
|---|---|
| `odocrypt_wrapper.cpp` | `odocrypt_hash_header()` — wraps DigiByte's `HashOdo` for the Python share-validator. Build into `odocrypt.dll` against the DGB 8.26.2 tree (see below). |
| `stratum/solo_stratum.py` | The bridge: GBT → Stratum v1 → FPGA, submits found blocks. Matches `hps/stratum.c`'s dialect. |
| `stratum/{header,odocrypt,rpc}.py` | helpers: header serialisation, odocrypt.dll ctypes binding, JSON-RPC client |
| `conf/digibyte.conf.{regtest,testnet}` | node config templates (change rpcuser/rpcpassword!) |

## Quick start (regtest)

1. **Node**: copy `conf/digibyte.conf.regtest` to your DigiByte data dir,
   start `digibyted -regtest`, create a wallet + address, and
   `generatetoaddress 100 <addr>` to mature a spendable balance.
2. **odocrypt.dll** (for the Python share-validator):
   ```
   cl /LD /std:c++17 odocrypt_wrapper.cpp \
      <dgb>/src/crypto/odocrypt.cpp <dgb>/src/crypto/KeccakP-800-reference.cpp \
      /I <dgb>/src /Fe:odocrypt.dll
   ```
   Point `stratum/odocrypt.py` `DLL_PATH` at it.
3. **Bridge**: set `stratum/rpc.py` `RPC_URL`/`RPC_AUTH` for your node, then
   `python3 stratum/solo_stratum.py regtest` (listens on :3333).
4. **Miner**: point the FPGA miner at the bridge —
   `odo-miner <bridge-ip> 3333 <worker>` (or set the pool in the web UI).

## ⚠️ Status: bridge needs one loopback validation before hardware

`solo_stratum.py` is written to match `hps/stratum.c` line-for-line on byte
order (prevhash sent big-endian so the miner's reverse yields internal LE;
full coinbase as `coinb1` with empty `coinb2`/branches so the miner's merkle
root = `dsha(coinbase)`). It has **not** yet been run against the miner. Two
things to confirm on first contact, both in `hps/stratum.c`:

1. **subscribe result shape** — `handle_subscribe_result()` reads the 3rd
   quoted string as extranonce1. `solo_stratum.py` sends
   `[[["mining.notify","odo"]],"00",0]`; verify the miner parses
   extranonce1="" / size 0 from it (adjust either side if not).
2. **share validation hash** — `solo_stratum.py`'s `mining.submit` handler
   currently uses `dsha` as a placeholder; wire in `odocrypt_hash()` from
   `odocrypt.py` (as `server.py` does) so shares are validated with the real
   PoW before `submitblock`.

The cleanest validation is a loopback: run `solo_stratum.py` against a regtest
node and connect the miner with the FPGA stubbed, confirming
subscribe→authorize→notify parses and a (wrong) submit round-trips, before
trusting it with real hardware.
