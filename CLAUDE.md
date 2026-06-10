# CLAUDE Project Brief

This repository contains a standalone Cyclone V SoC port of the `odo-miner` OdoCrypt FPGA miner, based on the upstream source tree in `upstream/odo-miner/`.

## Purpose

`CLAUDE.md` is the top-level project brief for an AI or engineer to understand the repository intent, the target architecture, and where to find the detailed design artifacts.

## Project summary

- Goal: run the OdoCrypt miner fully autonomously on a QMTECH Cyclone V SoC board.
- The HPS runs Linux and a Stratum-capable miner daemon.
- The system is based on the upstream `odo-miner` design and reworks it into a standalone Cyclone V SoC implementation.
- The FPGA fabric performs OdoCrypt hashing using an Avalon-MM memory-mapped register interface.
- The project may include an optional external ESP32-based WiFi/display module (e.g. Liligo with screen) for local status, console output, and wireless management.
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

## Current status (2026-06-10)

- **Algorithm correct in RTL, proven**: `hdl/tb/run_tb.sh` drives the full
  register interface and reproduces upstream OdoCrypt+Keccak hashes bit-exact
  for multiple (epoch, header, nonce) vectors. The C oracle in
  `hps/odocrypt_state.c` matches upstream `odocrypt.cpp` (`make check`).
- `hdl/src/odocrypt/odocrypt_core.v` is a multi-cycle FSM (~22 cycles/round,
  ~26 KH/s @ 50 MHz); S-boxes live in BRAM in
  `hdl/src/odocrypt/odocrypt_epoch_tables.v` (ping-pong banks, streamed from
  the HPS with waitrequest flow control). Old pipeline/mutator RTL is archived.
- The miner is integrated into Platform Designer (`hdl/qsys/soc_system.qsys`)
  as a proper Avalon component at LW bridge offset 0x0, alongside SPI display
  (ILI9341), SPI touch (XPT2046), and PIO blocks for LCD control/keys/LEDs.
  Use `hdl/qsys/qsys_add_peripherals.tcl` as the reference for how it was
  added — do NOT rebuild from `soc_system.tcl` (stale HPS parameter names).
- HPS software: stratum client with set_difficulty/share targets, correct
  Odo epoch key (`ntime - ntime % 864000`), per-job extranonce2, preemptive
  job switching, status JSON export. `make all`, `make test_units`,
  `make check` all green.
- Touch UI: `sw/odo-ui` renders a dashboard on `/dev/fb0` with touch
  restart/reboot. Linux side: `linux/socfpga_cyclone5_qmtech_odo.dts` +
  `linux/linux-display.fragment` + BusyBox init overlay in `linux/overlay/`.
- Board identified as DE10-Nano ball-compatible (MiSTer-style); display
  wiring on the GPIO_0 header — see `docs/DISPLAY_WIRING.md`.

## Validation focus

- Quartus fit/timing closure of the integrated design (see docs/TODO.md §1
  for the fit-failure history and what to check if it regresses).
- Hardware gate checks: smoke test → epoch load → known-nonce on silicon →
  display probe → testnet stratum round-trip (docs/TODO.md §2).
- Touch calibration and GPIO_0 power-pin verification before wiring.

## Notes

- `docs/TODO.md` is the authoritative status/plan document (refreshed 2026-06-10).
- `docs/DISPLAY_WIRING.md` — physical wiring for the SPI touch screen.
- RTL regression: `hdl/tb/run_tb.sh` (Icarus in WSL). Run it after ANY
  change to core/tables/keccak, then regenerate Qsys (it copies RTL into
  `soc_system/synthesis/submodules/`) before recompiling Quartus.

## Next steps

1. Confirm the latest Quartus compile fits and meets timing; produce .rbf.
2. Rebuild the Buildroot image (new defconfig/DTS/overlay), assemble SD card.
3. Run the hardware gate checks in docs/TODO.md.
4. Wire the display per docs/DISPLAY_WIRING.md and bring up odo-ui.
