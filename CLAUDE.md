# CLAUDE Project Brief

This repository contains a standalone Cyclone V SoC port of the `odo-miner` OdoCrypt FPGA miner, based on the upstream source tree in `upstream/odo-miner/`.

## Purpose

`CLAUDE.md` is the top-level project brief for an AI or engineer to understand the repository intent, the target architecture, and where to find the detailed design artifacts.

## Project summary

- Goal: run the OdoCrypt miner fully autonomously on a QMTECH Cyclone V SoC board.
- The HPS runs Linux and a Stratum-capable miner daemon.
- The system is based on the upstream `odo-miner` design and reworks it into a standalone Cyclone V SoC implementation.
- The FPGA fabric performs OdoCrypt hashing using an Avalon-MM memory-mapped register interface.
- The system should boot from SD card and function without a host PC.

## Key documentation

- `docs/architecture.md` — main architecture and execution plan
- `docs/register-map.md` — FPGA register interface contract
- `docs/project-plan.md` — phase-based project execution brief
- `docs/working-notes.md` — working notes and implementation ideas

## Source layout

- `hdl/` — FPGA and RTL source files
- `hps/` — HPS daemon, job handling, and register definitions
- `boot/` — bootloader, device-tree, and SD card boot assets
- `linux/` — Buildroot and rootfs build support
- `sw/` — supporting user-space software and services
- `scripts/` — build and deployment helpers
- `services/` — init/service unit files

## Current status (2026-06-16)

- **Algorithm correct in RTL, proven**: `hdl/tb/run_tb.sh` drives the full
  register interface and reproduces upstream OdoCrypt+Keccak hashes bit-exact
  for multiple (epoch, header, nonce) vectors. The C oracle in
  `hps/odocrypt_state.c` matches upstream `odocrypt.cpp` (`make check`).
- **Mining on hardware, proven**: board mined ~485 blocks on the testnet
  (2026-06-11). Running dual-core + shared tables at **~57 KH/s** @ 55 MHz on
  the testnet pool (2026-06-16; was ~52 KH/s @ 50 MHz). WiFi stable (0 DEAUTH
  events, USB autosuspend disabled).
- **Dual-core FPGA** (`perf/dual-core` branch): two independent
  `odocrypt_core` + `odocrypt_epoch_tables` pairs in `hdl/src/odocrypt_top.v`;
  epoch write stream fanned out to both; nonce range split at midpoint; first
  found nonce latched (core 0 wins ties). Fit: **81% ALM, 29% BRAM**,
  Fmax = **52.42 MHz** (slower than single-core 55.6 MHz due to routing at
  81% utilization). Bitstream: `hdl/quartus/output_files/odo_miner.rbf`
  (3.3 MB, deployed to SD card 2026-06-14).
- **75 MHz PLL attempted** (`perf/pll-75mhz` branch, 2026-06-15): `altpll`
  synthesizes correctly (1 PLL), but fitter fails `Can't fit design in device`
  — aggressive register retiming at 81% ALM pushes past 100% capacity. Fabric
  critical path is ~19 ns vs 13.33 ns required; not achievable on this device.
- **Shared epoch tables + 55 MHz** (`perf/quad-core` branch, 2026-06-16):
  the pmask/prot/rot/rk FF tables are identical for both cores, so the second
  full `odocrypt_epoch_tables` (~3.8k ALMs) was pure waste. Split the S-box
  BRAMs into `hdl/src/odocrypt/odocrypt_sbox_bank.v` (one per core, ~0 ALM,
  pure M10K) and broadcast ONE shared FF table + write strobes. Drops the
  design **81% → 71% ALM** and lifts Fmax **52.42 → 55.9 MHz** (less routing
  congestion). 75 MHz still fails (−3.8 ns); 56.25 MHz fails the 100C corner
  (−0.111 ns); **55 MHz (11/10 PLL) signs off clean** (clk_fab setup +0.291 ns
  @ Slow/100C, all hold positive). **Deployed to SD card boot partition
  2026-06-16; verified 57,224 H/s on hardware (+10% over 52,033), 0 DEAUTH.**
  Rollback: `fpga_50mhz.rbf` on the board's FAT boot partition. Regression
  `run_tb.sh` bit-exact. Branch name is a misnomer — quad-core is infeasible
  (each core ~11.7k ALM; 3 cores > 100%).
- **Shared Keccak** (`perf/shared-keccak` branch, 2026-06-16): each
  `odocrypt_core` carried its own `keccak_hasher` (~1.8k ALM, measured), but
  Keccak runs only ~58 of every ~1910 cycles per hash (<1% duty/core). Pulled
  the unit out of the core into `odocrypt_top.v` as ONE `keccak_shared` +
  a 2-state lowest-index-priority arbiter (`kec_req`/`kec_result` handshake).
  Collisions self-skew (both cores run a fixed, data-independent FSM), so the
  throughput cost is a one-time ~58-cycle hit. **81%→** no: drops **71% → 67%
  ALM** (28,242/41,910; freed 1,333 net after the arbiter/mux). `run_tb.sh`
  bit-exact 4/4. CAVEAT: the central shared unit's routing dropped clk_fab
  Fmax **55.9 → 55.15 MHz @ Slow/100C** (only +0.05 ns at 55 MHz) — fine as an
  intermediate (NOT deployed; same ~57 KH/s as the board), but register the
  Keccak interface to reclaim margin when building the real next step. This is
  the ALM-freeing ENABLER for adding throughput — see Next steps.
- `hdl/src/odocrypt/odocrypt_core.v` is a multi-cycle FSM (~22 cycles/round,
  ~26 KH/s per core @ 50 MHz); S-boxes live in BRAM in
  `hdl/src/odocrypt/odocrypt_epoch_tables.v` (ping-pong banks, streamed from
  the HPS with waitrequest flow control). Old pipeline/mutator RTL is archived.
- The miner is integrated into Platform Designer (`hdl/qsys/soc_system.qsys`)
  as a proper Avalon component at LW bridge offset 0x0, alongside SPI display
  (ILI9341), SPI touch (XPT2046), and PIO blocks for LCD control/keys/LEDs.
  Use `hdl/qsys/qsys_add_peripherals.tcl` as the reference for how it was
  added — do NOT rebuild from `soc_system.tcl` (stale HPS parameter names).
- HPS software: stratum client with set_difficulty/share targets, correct
  Odo epoch key (`ntime - ntime % 864000`), per-job extranonce2, preemptive
  job switching, stale-job guard (`batch_job_id` checked at harvest to discard
  nonces found for switched jobs), status JSON export. `make all`,
  `make test_units`, `make check` all green.
- Touch UI: `sw/odo-ui` renders a dashboard on `/dev/fb0` with touch
  restart/reboot. Background image `linux/overlay/etc/odo-ui/bg.png` (dim=10).
  Linux side: `linux/socfpga_cyclone5_qmtech_odo.dts` +
  `linux/linux-display.fragment` + BusyBox init overlay in `linux/overlay/`.
- Board identified as DE10-Nano ball-compatible (MiSTer-style); display
  wiring on the GPIO_0 header — see `docs/DISPLAY_WIRING.md`.

## Notes

- `docs/TODO.md` is the authoritative status/plan document (refreshed 2026-06-14).
- `docs/DISPLAY_WIRING.md` — physical wiring for the SPI touch screen.
- `docs/FAN_SENSOR_WIRING.md` — J12 GPIO_1 wiring for DS18B20, PWM fan,
  reset button; pending software tasks listed there.
- RTL regression: `hdl/tb/run_tb.sh` (Icarus in WSL). Run it after ANY
  change to core/tables/keccak, then copy updated RTL into
  `hdl/qsys/soc_system/synthesis/submodules/` before recompiling Quartus
  (Qsys caches its own copy — do NOT rely on auto-copy without re-generating).

## Next steps

Performance roadmap from the shared-Keccak baseline (67% ALM, clk_fab maxes
~55 MHz — the limiter is the Pbox barrel-rotator combinational path ~17 ns, NOT
ALM or core count). ALM is the binding constraint, not BRAM. Pick ONE of A/B:

- **Path A — 3rd core** (`odocrypt_top.v`, +1 core sharing the Keccak/tables):
  ~9.5k ALM → **~90% ALM**. Highest ceiling (**~78 KH/s @ ~50 MHz**, ~86 if 55
  holds) but high risk: at 67% the fabric margin is already only +0.05 ns;
  90% likely drops Fmax toward ~50 MHz or fails to route. Register the Keccak
  interface first to recover margin.
- **Path B — widen Mix** (`odocrypt_core.v`, 2 rotations/cycle): Mix 7→4 cyc,
  round 22→19 → **~66 KH/s**, stays ~70% ALM and holds 55 MHz (width-not-depth,
  low Fmax risk). The safe, bankable win.
- A and B together do NOT fit (3rd core + widening all cores ≈ 103% ALM).
- **75 MHz is infeasible**: it needs the Pbox rotator pipelined (split the ~17 ns
  path), which adds ~6 cyc/round, netting only ~+7%. Not worth the surgery.
- Cheap add-ons that compose with either: Keccak-wait overlap (~+3%, start the
  next nonce during the 58-cyc Keccak wait). Full 2-nonce interleave (C-slow)
  is ~1.3–1.4×/core but ~5–6k ALM/core — only worth it once cores won't fit.

Non-performance backlog:
1. Fan/thermal/reset button software (pending tasks 3–6 in `docs/FAN_SENSOR_WIRING.md`).
2. Merge `claude/18b20-fan-gpio-setup-r4bm1f` → `Fabel` after fixing DTS comments
   and Makefile dead-code identified in that branch's review.
3. Pool failover: wire `ODOD_POOL_HOST2/PORT2` into `hps/miner.c` reconnect loop.
