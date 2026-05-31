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

## Current status

- The FPGA RTL now includes `hdl/src/odocrypt_top.v` as the Avalon-MM register wrapper.
- The mining core has a single-core 84-round pipeline in `hdl/src/odocrypt_compress.v` and `hdl/src/odocrypt_round.v`.
- `hdl/src/odocrypt_core.v` implements a job FSM, runtime nonce injection, header-folding state builder, target compare, and hash capture.
- Epoch-dependent round constants are generated in `hdl/src/odocrypt_epoch_mutator.v`.
- The HPS software already streams the 80-byte job header, target, and epoch into the FPGA registers.

## Recent progress

- Added a stronger initial-state mixer for header+nonce/epoch in `hdl/src/odocrypt_core.v`.
- Expanded the nonlinear DSP layer in `hdl/src/odocrypt_sbox_dsp.v` for richer FPGA-friendly mixing.
- Updated `hdl/src/odocrypt_round.v` to use multiple epoch/key-dependent operations and lane rotations.
- Captured final pipeline hash results in top-level hash registers for verification.

## Validation focus

- Confirm `hdl/src/odocrypt_top.v` register mapping matches `hps/hps_regs.h` and HPS software assumptions.
- Verify `hash_meets_target()` comparison semantics are correct for the little-endian target format.
- Add a smoke-test or simple HDL simulation for the start/status/clear and register access sequence.
- Integrate the RTL into the Quartus SoC project and assign a stable LWH2F base address.

## Notes

- `docs/TODO.md` now tracks current RTL progress and pending integration/validation items.
- `docs/register-map.md` should be reviewed and updated as the wrapper register layout stabilizes.

## Next steps

1. Review `docs/architecture.md` for the high-level plan.
2. Confirm the register map in `docs/register-map.md` matches the FPGA and HPS sources.
3. Implement or validate the HPS daemon and FPGA bridge interface.
4. Build and boot the SoC image on the target hardware.
