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

## Current status (2026-06-14)

- **Algorithm correct in RTL, proven**: `hdl/tb/run_tb.sh` drives the full
  register interface and reproduces upstream OdoCrypt+Keccak hashes bit-exact
  for multiple (epoch, header, nonce) vectors. The C oracle in
  `hps/odocrypt_state.c` matches upstream `odocrypt.cpp` (`make check`).
- **Mining on hardware, proven**: board mined ~485 blocks on the testnet
  (2026-06-11). Currently running dual-core at **~52 KH/s** on the testnet
  pool (2026-06-14).
- **Dual-core FPGA** (`perf/dual-core` branch): two independent
  `odocrypt_core` + `odocrypt_epoch_tables` pairs in `hdl/src/odocrypt_top.v`;
  epoch write stream fanned out to both; nonce range split at midpoint; first
  found nonce latched (core 0 wins ties). Fit: **81% ALM, 29% BRAM**,
  Fmax = 55.6 MHz (unchanged). Bitstream: `hdl/quartus/output_files/odo_miner.rbf`
  (3.3 MB, deployed to SD card 2026-06-14).
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

1. PLL clock bump to 75 MHz (`hdl/src/soc_top.v` + `hdl/constraints/miner.sdc`) —
   free hashrate to ~78 KH/s if timing closes; zero RTL changes to the core.
2. Fan/thermal/reset button software (pending tasks 3–6 in `docs/FAN_SENSOR_WIRING.md`).
3. Merge `claude/18b20-fan-gpio-setup-r4bm1f` → `Fabel` after fixing DTS comments
   and Makefile dead-code identified in that branch's review.
4. Pool failover: wire `ODOD_POOL_HOST2/PORT2` into `hps/miner.c` reconnect loop.
