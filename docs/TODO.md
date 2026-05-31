# TODO

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
- RTL core skeleton is implemented and now exercises a full 84-stage pipeline with epoch-aware constants.
- The Avalon-MM register interface is wired through `hdl/src/odocrypt_top.v` and is compatible with the HPS job loader.
- The remaining work is functional validation, exact OdoCrypt algorithm matching, multi-core expansion, and Quartus/System integration.
