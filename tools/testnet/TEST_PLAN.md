# Test plan — validating the OdoCrypt FPGA miner

A staged plan that de-risks the miner from "algorithm on paper" to "finds
real blocks on hardware". Each stage has a pass/fail gate and builds on the
previous one, so a failure localises the problem.

The harness in this directory lets you run stages 1–3 with **no FPGA**, then
swap the CPU reference miner for the real board at stage 4 without changing
anything else in the stack.

```
 Stage 1   Stage 2        Stage 3              Stage 4
 hash  ->  consensus  ->  Stratum bridge   ->  FPGA on the wire
 vector    block loop     + CPU miner          (same bridge)
```

## Stage 0 — node ready (prerequisite)

```
bash regtest_up.sh
```
Brings up a regtest node and mines past OdoCrypt activation (block 600).
Gate: `getblocktemplate '{"rules":["segwit"]}' 'odo'` shows `pow_algo: odo`
and an `odokey`.

## Stage 1 — algorithm is consensus-correct (no node, no FPGA)

The FPGA's hash is already proven bit-exact with DigiByte 8.26.2 by the RTL
testbench (`hdl/tb/run_tb.sh`) and the C oracle (`hps/ make check`). The same
vector is checked natively by Miningcore's `build_test_odocrypt.sh`.
Gate: all three agree on the digest for a fixed (key, header).

## Stage 2 — full consensus loop in software (node, no FPGA)

```
bash build_odocrypt_lib.sh        # once, builds libodocrypt.so from the submodule
python3 regtest_selftest.py
```
CPU-mines one regtest block end-to-end — getblocktemplate → assemble block →
OdoCrypt hash → submitblock — and asserts the node accepts it.
Gate: prints `SELFTEST PASS` (a block the node validated as OdoCrypt).
This proves header layout, odokey, target comparison, and block assembly are
all correct against the real validator. **This is the keystone test.**

## Stage 3 — Stratum path, CPU miner (node, no FPGA)

```
python3 stratum/solo_stratum.py regtest &   # GBT -> Stratum v1 -> :3333
python3 cpu_miner.py 127.0.0.1 3333         # reference miner, finds a block
```
Exercises the exact wire protocol the FPGA will use: subscribe → authorize →
notify → submit, with the bridge validating the share via OdoCrypt and
calling submitblock. The CPU miner is a stand-in that speaks the same
protocol as `hps/stratum.c`.
Gate: bridge logs `BLOCK SUBMITTED` and the node height increases.
This validates the bridge and the protocol **without risking FPGA time**.

## Stage 4 — the real FPGA miner (hardware)

Everything above passed in software, so the only new variable is the board.

1. Flash the SD image, boot, confirm the smoke test reads the registers and
   the known-answer hardware test matches `hdl/tb/gen_vectors` (see
   docs/TODO.md §2). This isolates "does the silicon hash correctly" from
   "does the pool plumbing work".
2. Point the miner at the **same bridge** from stage 3:
   `odo-miner <host> 3333 <worker>` (or set it in the web dashboard).
   Nothing on the pool side changes — only the hasher is now the FPGA.
3. Gate A (regtest, trivial difficulty): the board finds a nonce within
   seconds; the bridge accepts it and the node mines a block. Confirms the
   end-to-end path on real hardware.
4. Gate B (testnet, `ODO_TESTNET=1`): point at a testnet node/pool and let it
   run. Confirms real difficulty, share submission cadence, and — within a
   day — an epoch shapechange (testnet interval is 1 day) handled live without
   a restart.
5. Gate C (soak): 24 h unattended. Then enable the hardware watchdog
   (`ODOD_WATCHDOG=1`).

## What each stage isolates

| If this stage fails | the problem is in |
|---|---|
| 1 | the OdoCrypt algorithm (RTL or C) |
| 2 | header layout / odokey / target / block assembly |
| 3 | the Stratum wire protocol (bridge ↔ miner) |
| 4.1 | the FPGA bitstream / register interface |
| 4.2+ | pool/network/epoch handling on real difficulty |

## Notes

- Regtest difficulty is trivial, so a CPU finds a valid nonce immediately —
  stages 2–3 run in seconds.
- OdoCrypt epoch interval: regtest & mainnet 864000s, testnet 86400s
  (verified against 8.26.2). The miner derives the key from nTime; the node
  validates with the same formula, so they always agree.
- Miningcore is an alternative to the solo bridge for stages 3–4; see
  `../../../miningcore/examples/DIGIBYTE_ODOCRYPT_SETUP.md` (separate repo).
  It needs Postgres and a rebuild, so the solo bridge is the lighter path.
