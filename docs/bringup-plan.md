# Bring-Up Plan

This document captures the next concrete steps required to turn the current prototype into a validated standalone Cyclone V SoC OdoCrypt miner.

## Goal

Enable a complete hardware/software bring-up path for the Cyclone V SoC miner, including:
- verified OdoCrypt RTL behavior,
- a correct HPS register driver and Stratum path,
- a working Quartus/Platform Designer integration,
- a reproducible SD card boot/runtime flow.

## 1. Immediate fixes

1. Fix the HPS job loader so it writes the nonce range before starting the FPGA.
2. Add sanity checks and logging for `REG_VERSION`, `REG_STATUS`, and job field validity.
3. Ensure the daemon explicitly clears and re-arms the found condition using `CTRL_CLEAR_FOUND`.

## 2. RTL validation

1. Add a reference software model for OdoCrypt or reuse a verified upstream implementation.
2. Add RTL testbenches for `hdl/src/odocrypt_top.v` to validate:
   - read/write of all control registers,
   - `CONTROL` start/reset semantics,
   - `STATUS` bits and found latch behavior,
   - header/target layout and endianness.
3. Add test vectors for the actual OdoCrypt initial state / target comparison.

## 3. FPGA integration

1. Populate `hdl/qsys/` with the Platform Designer system.
2. Populate `hdl/quartus/` with the Cyclone V project files.
3. Connect `odocrypt_top.v` as a LWH2F slave, assign a stable base address, and document it in `hps/hps_regs.h`.
4. Add timing constraints in `hdl/constraints/` for the bridge clock and hash clock domains.

## 4. Software and deployment

1. Confirm the canonical HPS source tree and remove duplicate copies.
2. Build the daemon and smoke-test using `hps/Makefile`.
3. Verify the `linux/buildroot/` image includes the daemon and required kernel features.
4. Add service units for `odod` and optional update/autonomy services in `services/`.

## 5. Validation and automation

1. Run `hps/fpga_smoke_test` on hardware to validate register access.
2. Add CI checks for HPS build and register map consistency.
3. Document the bring-up sequence in this file, including:
   - FPGA register smoke test,
   - job load and found-share test,
   - network/Stratum connection.

## 6. Priority order

1. Correct HPS daemon register writes.
2. Add RTL verification and simulation coverage.
3. Complete Quartus/Platform Designer integration.
4. Build and validate the bitstream and runtime image.
5. Automate and document the full bring-up flow.

## 7. Notes

- The current repository already has a useful register map and smoke-test utility.
- The main risk areas are algorithm correctness and HPS↔FPGA contract drift.
- This plan should be updated as new validation results are available.
