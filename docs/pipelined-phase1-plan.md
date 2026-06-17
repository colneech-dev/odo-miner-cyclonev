# Phase 1 Plan — Pipelined Miner SoC Integration

Branch: `feat/pipelined-miner`. Goal: the HPS drives the upstream pipelined
`odo_encrypt` over Avalon-MM for one fixed epoch, co-fit with the existing
HPS + display + touch + PIO, proving real on-board MH/s. Phase 0 PASSED
(65% ALM, 162 MHz, ~37.5 MH/s standalone — see pipelined-miner-scope.md).

## Core interface (from upstream `miner.v`)

`miner(clk, header[607:0], target[255:0], nonce[31:0])` — **free-running**: it
continuously sweeps all nonces (one new nonce every THROUGHPUT=4 cycles) and
latches `nonce` whenever a hash ≤ target. No start/stop, no found-strobe; the
host polls `nonce`. `header[607:0]` = the 76-byte header (19×32, NO nonce slot —
the core appends the swept nonce as the top 32 bits → 640-bit odo input, matching
our FSM's premix layout). The epoch is baked in (`ODOKEY` macro).

## Clocking / CDC

- One `altpll` (extend the existing `u_pll_fab`): `clk0` = soc_system/Avalon
  fabric (~55 MHz), add `clk1` = **×3 = 150 MHz** miner domain.
- **Config CDC (Avalon→150 MHz):** HPS writes header/target into Avalon-domain
  registers, then writes `CONFIG_COMMIT` (toggles `cfg_tgl`). Sync `cfg_tgl`
  (2-FF) into the miner domain; on edge, latch the now-stable header/target buses
  (data-stable-at-capture — only the 1-bit toggle needs synchronizing).
- **Found CDC (150 MHz→Avalon):** an **async found-FIFO** (≈16-deep, 32-bit
  nonces) is the robust path — the core only holds the *last* found nonce, so at
  share difficulty a single register can drop finds (= dropped shares = lost
  revenue). FIFO push on `nonce` change in the miner domain; HPS pops via Avalon.
  v1 bring-up may start with a single found register + `found_seq` counter, but
  the FIFO is the target.

## Register map (new contract — supersedes the FSM's nonce-range/epoch-stream regs)

| Off | Name | Dir | Notes |
|-----|------|-----|-------|
| 0x000 | CONTROL | W | bit1 = soft reset miner domain |
| 0x004 | STATUS | R | bit0 running, bit1 pll_locked, bit2 fifo_empty |
| 0x008 | VERSION | R | 0x0002_xxxx (pipelined) |
| 0x00C | SEED | R | baked-in `ODOKEY` — HPS verifies bitstream epoch vs current |
| 0x020–0x03C | TARGET[0..7] | W | 256-bit target |
| 0x040–0x088 | HEADER[0..18] | W | 608-bit header (19 words, no nonce) |
| 0x08C | CONFIG_COMMIT | W | toggle → latch header/target into miner domain |
| 0x090 | FOUND_NONCE | R | pop next found nonce from FIFO |
| 0x094 | FOUND_STATUS | R | bit0 valid (FIFO non-empty), [15:4] crc12 |
| 0x0B0/B4 | PERF_HASHES_LO/HI | R | optional free-running hash counter |

## Integration approach

Instantiate the miner **in `soc_top.v`** (compiled directly — no Qsys regen),
not as a Qsys component, because the per-epoch `odo_<seed>.v` (15.5k lines)
changes every epoch and `soc_top.v` is the clean place to swap one file +
recompile. Export the LW H2F bridge Avalon master from Qsys to `soc_top`, where
the new `pipelined_miner_top` (register file + CDC + FIFO + `miner` core + 150 MHz
clk) attaches. HPS + bridges + display + touch + PIO stay in `soc_system.qsys`.

## Tasks

- **P1.1** Register map + `pipelined_miner_top.v`: Avalon-MM slave, config CDC,
  found-FIFO, instantiate `miner`. New `hps_regs_pipe.h`.
- **P1.2** Testbench: Avalon-drive header/target for a generated epoch, verify a
  known nonce ≤ target is found, hash bit-exact vs `odocrypt_state.c` oracle.
- **P1.3** 150 MHz PLL output in `soc_top.v` (+ SDC).
- **P1.4** Qsys: export LW bridge master to `soc_top`; attach wrapper; **co-fit**
  with peripherals; re-sign at **100°C**; record ALM/Fmax/THROUGHPUT achieved.
- **P1.5** HPS daemon: new register contract; drive one fixed epoch; pop found
  nonces; reuse stratum/job/share logic + stale-job guard.
- **P1.6** On-board bring-up: flash co-fit bitstream, verify end-to-end MH/s on
  one epoch on the testnet pool.

## Risks

- Co-fit may force THROUGHPUT 6/8 or lower clock (still MH/s) — measured at P1.4.
- Exporting the LW bridge master is a delicate Qsys edit (see feedback-qsys-sync).
- Found-FIFO depth vs share rate; CDC correctness — gated by P1.2 TB + soak.
