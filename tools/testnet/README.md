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

## One command

**Windows** (node + Python are native here):
```
tools\testnet\start_fpga_miner.bat        # regtest test bed, ready for the FPGA
```
Brings up the node, mines to OdoCrypt activation, starts the bridge on
`127.0.0.1:3333`, and a **web status view on `http://127.0.0.1:8080`**
(stdlib-only — no Flask/pip — replacing the old `web.py`), then leaves it
running. Point the board at it: `odo-miner <this-PC-IP> 3333 worker`.

**Self-test, no FPGA** (proves the whole stack mines a block):
```
python tools\testnet\run_testbed.py --demo        # Windows
bash   tools/testnet/run_regtest_demo.sh          # Linux/WSL
```
→ `DEMO PASS` (a block the node validated as OdoCrypt, mined over Stratum).

## Contents

| File | Purpose |
|---|---|
| `run_testbed.py` | one-command orchestrator: node → mine to activation → bridge → (optional) CPU self-test. Used by the `.bat` and the `.sh`. |
| `start_fpga_miner.bat` | Windows launcher (test bed, leaves the bridge running) |
| `run_regtest_demo.sh` | Linux/WSL self-test wrapper (`--demo`) |
| `regtest_selftest.py` | stage-2 keystone: CPU-mine one block end-to-end via RPC |
| `cpu_miner.py` | reference CPU miner over Stratum — the FPGA's stand-in |
| `stratum/solo_stratum.py` | the bridge: GBT → Stratum v1 → submitblock, real OdoCrypt validation |
| `lib/odo_node.py` | reusable core: RPC, OdoCrypt hash, segwit coinbase + block assembly |
| `odocrypt_wrapper.cpp` + `build_odocrypt_lib.sh` | portable hash lib (`.so`/`.dll`) built from `third_party/odo-miner` |
| `regtest_up.sh` | bring a node up by hand (encodes the conf/activation gotchas) |
| `conf/digibyte.conf.{regtest,testnet}` | node config templates |

## Status: VERIFIED working (2026-06-11)

Run against a live DigiByte 8.26.2 regtest node:
- `regtest_selftest.py` — block CPU-mined end-to-end, node **accepted** it.
- `run_testbed.py --demo` — block mined over the Stratum wire, **DEMO PASS**.

`solo_stratum.py` speaks the exact dialect `hps/stratum.c` implements
(subscribe → authorize → 9-field notify → submit), validated by `cpu_miner.py`
which reconstructs the header the same way the FPGA does. When the board is
ready, point it at the same bridge — only the hasher changes. See
[TEST_PLAN.md](TEST_PLAN.md) for the staged FPGA bring-up.
