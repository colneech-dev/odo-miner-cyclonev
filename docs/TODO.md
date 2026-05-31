# TODO

## Immediate work

- [x] Fix `hps/miner_daemon.c` so `REG_NONCE_START` and `REG_NONCE_END` are written before starting the FPGA.
- [x] Fix `hps/stratum.c` compile issues so HPS daemon code builds cleanly in WSL.
- [x] Build `hps/fpga_smoke_test` and verify `/dev/mem` access on target hardware.
- [ ] Add explicit `CTRL_CLEAR_FOUND` behavior on each job start/re-arm.
- [ ] Add logging for FPGA register status and version during daemon startup.
- [ ] Diagnose why `hps/fpga_smoke_test` reads all `0xFFFFFFFF` from the FPGA MMIO region.

## RTL and register validation

- [ ] Add RTL testbenches for `hdl/src/odocrypt_top.v` register read/write behavior.
- [ ] Add simulation coverage for `CONTROL` start/reset semantics and `STATUS` bit behavior.
- [ ] Validate the OdoCrypt algorithm against a reference implementation.
- [ ] Confirm target and header endianness in `hps/odocrypt_header.c` matches RTL expectations.

## FPGA integration

- [ ] Populate `hdl/qsys/` with the Platform Designer project.
- [ ] Populate `hdl/quartus/` with the Quartus project files and build scripts.
- [ ] Add `hdl/constraints/` timing constraints for bridge and hash clock domains.
- [ ] Verify the LWH2F base address and document it in `hps/hps_regs.h`.

## Software and deployment

- [ ] Choose the canonical HPS source tree and remove redundant copies.
- [ ] Verify Buildroot/rootfs includes `odod` and required kernel support.
- [ ] Add `services/odod.service` and optional `services/odo-update.service`.
- [ ] Document SD card layout and boot flow in `docs/bringup-plan.md`.

## Validation and automation

- [ ] Run `hps/fpga_smoke_test` on target hardware to validate MMIO.
- [ ] Add CI jobs for HPS build and smoke-test compilation.
- [ ] Add a register-map consistency check between RTL, `hps/hps_regs.h`, and docs.
- [ ] Add a hardware bring-up checklist to `docs/bringup-plan.md`.

## 1. RTL / FPGA
- [x] Implement `hdl/src/odocrypt_top.v` Avalon-MM wrapper for control/status/epoch/header/target/nonce registers
- [x] Implement `hdl/src/odocrypt_core.v` job FSM, pipeline input builder, and target comparison
- [x] Implement `hdl/src/odocrypt_compress.v` as an 84-round pipeline with per-stage registers
- [x] Implement `hdl/src/odocrypt_epoch_mutator.v` epoch-dependent per-round constant/rotation generation
- [x] Implement `hdl/src/odocrypt_round.v` lane-based round logic with DSP-accelerated nonlinear mixing
- [x] Implement `hdl/src/odocrypt_sbox_dsp.v` as the nonlinear DSP layer
- [ ] Validate the implementation against the exact OdoCrypt specification and target comparison semantics
- [ ] Add multi-core support via `odocrypt_array.v` or additional parallel engine instances
- [ ] Add RTL simulations or formal checks for the mining state pipeline

## 2. Register / interface validation
- [x] Expose control/status/epoch/header/target/nonce/register fields in `odocrypt_top.v`
- [x] Capture the final hash output in hash result registers for verification
- [ ] Validate register endian semantics against `hps/hps_regs.h` and the host-side job loader
- [x] Add a smoke test or simulation for register read/write and start/clear behavior

## 3. Repository structure
- [ ] Decide canonical HPS source location: root `hps/` or `hdl/src/hps/`
- [ ] Remove or consolidate duplicate HPS source copies if needed
- [ ] Document the current `hdl/src/odocrypt_top.v` wrapper and its intended register map

## 4. Integration / build
- [ ] Add `hdl/src/odocrypt_top.v` and the OdoCrypt RTL to the Quartus/Qsys SoC build project
- [ ] Assign a fixed LWH2F base address and verify the HPS-FPGA bridge connection
- [ ] Synthesize the design and verify timing on the target Cyclone V device
- [ ] Build a Linux-side test program using `hps/hps_regs.h`
- [ ] Test `/dev/mem` register access from the HPS once hardware is available

## 5. Software / daemon
- [x] Load job header, target, and epoch from the Stratum job into FPGA registers
- [ ] Verify the current `hps/miner_daemon.c` startup and job submission flow against the RTL
- [ ] Add share submission and job re-arm behavior once the core is functional

## 6. Current status
- HPS software now builds cleanly in WSL; `odod` is produced successfully.
- `hps/fpga_smoke_test` also compiles and runs, and `/dev/mem` open succeeds on the target.
- The smoke test currently reads `0xFFFFFFFF` for every expected register at `0xFF200000`.
- This indicates the HPS MMIO region is reachable, but the FPGA peripheral is not responding at the expected address or the bitstream/interface is not present.
- Next work: verify the LWH2F base address, confirm the FPGA bitstream is loaded, and update the register-map contract in `hps/hps_regs.h`.
- Remaining work still includes functional RTL validation, exact OdoCrypt algorithm matching, and SoC/Quartus integration.
