# Scope: Pipelined OdoCrypt Miner with Off-Board Precompile + Runtime Reconfigure

Status: **scoping draft** (2026-06-16). Not started. This is the architecture
project that would close the ~650× gap between this port's sequential FSM
(~57 KH/s) and the upstream pipelined design (~tens of MH/s) **without giving
up headless on-board operation.**

## 1. Why

The upstream `odo-miner` targets the *same Cyclone V SoC class* as our board
(DE10-Nano = `5CSEBA6U23I7`; ours = `5CSXFC6C6U23I7`, both ~110K LE) and runs a
**fully pipelined** `odo_encrypt` at **150 MHz, THROUGHPUT=4** → one hash every
4 cycles ≈ **37.5 MH/s** (`miner.v:88-95`, `keccak800.v:188`,
`projects/de10_nano/{params.sh,pll_150.v}`).

It is fast because it **bakes the epoch's S-boxes/permutations into LUTs**
(`odo_gen.cpp` generates per-epoch Verilog from the epoch SEED) — which is why
it must **recompile the bitstream every 10-day epoch**. Our port instead streams
tables into BRAM at runtime (autonomous, no recompile) and pays for it with a
sequential FSM (~1900 cycles/hash).

**This project keeps the autonomy but moves the recompile off-board:** epochs are
deterministic and known ~10 days ahead, so an external x86 builds each epoch's
bitstream in advance; the board fetches a ~3 MB `.rbf` and reconfigures the
fabric at the epoch boundary. Board stays headless; only dependency is a small
always-on compile host it already has network access to reach.

## 2. Key findings from the code (what's reusable vs new)

| Area | Finding | Implication |
|------|---------|-------------|
| Precompile-ahead | `autocompile.sh` already builds **current + next** epoch's bitstreams with fitter-seed retries, caches per-seed, prunes old | Reuse it almost as-is for the compile service |
| Epoch→algorithm | SEED = `ntime - ntime % 864000` (mainnet) — **same formula our daemon already uses** | Epoch math already solved |
| Host↔miner IF | Upstream uses **JTAG** (`altsource_probe`, `mine.tcl` over USB-Blaster). **No Avalon/HPS path exists.** | Must build a new Avalon-MM wrapper (biggest RTL task) |
| Runtime reconfig | Kernel **already** has `CONFIG_FPGA_MGR_SOCFPGA`, `FPGA_BRIDGE`, `SOCFPGA_FPGA_BRIDGE`, `FPGA_REGION`, `OF_FPGA_REGION` (`linux/linux-fpga.fragment`) | Hot-reconfig is supported infra, not a from-scratch build |
| Fallback path | U-Boot already loads `.rbf` from the FAT boot partition at boot | "Reboot into next epoch's `.rbf`" is a trivial, bulletproof v1 reconfig |

## 3. Workstreams

### WS1 — Pipelined core + Avalon wrapper (LARGE, highest risk)
- Port the upstream `odo_gen` + pipeline RTL (`odo_encrypt`, `keccak800`,
  `miner`) to **Quartus 25.1** (upstream targets 18.1; `altpll`/`altsource_probe`
  IP may need regen).
- **Strip the JTAG source/probe interface; build an Avalon-MM slave** so the HPS
  feeds header/target and reads found-nonce/status over the LW bridge. The
  upstream `miner` module already sweeps a nonce range internally and reports
  finds — a good fit for an Avalon wrapper. Reuse our `odocrypt_top.v` register
  pattern (`hps_regs.h` contract).
- **No runtime table streaming** (tables are baked in) — that whole subsystem
  disappears, simplifying both RTL and daemon.
- Integrate into `soc_system.qsys` at LW 0x0 in place of `odocrypt_top`, keeping
  HPS + bridges + SPI display + touch + PIO. New PLL at the target clock.

### WS2 — Off-board precompile service (MEDIUM, low risk)
- Adapt `autocompile.sh`/`compile.sh`: set our `DEVICE`, emit **`.rbf`**
  (`GENERATE_RBF_FILE ON`), name by epoch, publish to a fetch endpoint
  (HTTP/scp/object store) with a **checksum/signature**.
- Run on cron/CI on an always-on x86 (Quartus Lite, ~9.5 GB RAM, ~40 min/epoch).
- Robustly handle hard epochs (OdoCrypt deliberately makes some epochs
  fit/timing-hard → fitter-seed sweeps). 10-day lead absorbs retries; alert on
  failure.

### WS3 — On-board reconfiguration (MEDIUM)
- **v1 (reboot-reconfigure):** daemon fetches+verifies next `.rbf`, writes it to
  the FAT boot partition, reboots at the epoch flip. ~30 s downtime / 10 days.
  Reuses the existing U-Boot path — near-zero risk.
- **v2 (live reconfigure):** at the flip, stop mining → disable HPS↔FPGA bridges
  → program fabric via `/sys/class/fpga_manager` (or an `fpga-region` overlay) →
  re-enable bridges → re-init peripherals + miner regs → resume. Few seconds, no
  reboot. Risk: bus hangs on bad bridge sequencing; display/touch must re-init.

### WS4 — HPS daemon integration (MEDIUM)
- Delete epoch-table streaming. Add: "is the loaded bitstream's epoch == current
  epoch? if not, trigger reconfig." New/extended register contract for the
  pipelined core. Stratum/job/share logic unchanged.

### WS5 — Verification (MEDIUM)
- Bit-exact vs the proven oracle (`hps/odocrypt_state.c`, already == upstream
  `odocrypt.cpp`): cross-check the pipelined RTL's hashes (new TB harness — the
  pipelined core has a different interface than `run_tb.sh` drives).
- Epoch-transition soak: forced flips, reconfig completes, mining resumes, no bus
  hang, peripherals recover. Multi-day hardware soak.

## 4. Top risks

1. **Co-fit/timing with peripherals at high clock.** Upstream's 150 MHz/T=4 was a
   *standalone* miner. With our HPS bridges + display + touch + PIO sharing the
   fabric it may not fit at T=4 or hit 150 MHz. Mitigation: accept lower
   THROUGHPUT (6/8) and/or clock — still MH/s. **De-risk first (Phase 0).**
2. **Pathologically hard epochs** taking many fitter-seeds / long compiles.
   Mitigation: start each epoch's build many days early; alerting; the board can
   keep mining the *previous* epoch is NOT valid (consensus), so a missed compile
   = downtime → must be monitored.
3. **Live-reconfig bus hangs / peripheral recovery** (WS3 v2). Mitigation:
   ship v1 (reboot) first; live reconfig is a later optimization, not a blocker.
4. **Toolchain drift** (upstream 18.1 → our 25.1 IP/flow differences).
5. **Compile-host dependency** is a real change to the "zero external machine"
   ideal (accepted premise of this project).

## 5. Phased plan (each phase delivers + de-risks the next)

| Phase | Goal | Output | Rough effort |
|-------|------|--------|--------------|
| **0 — Spike** | Does the pipelined core fit/time on *our* exact part, and how fast? | Upstream RTL compiled for `5CSXFC6C6` (no peripherals), measured fit/Fmax/MH/s on the board via JTAG | 2–4 days |
| **1 — SoC integration** | HPS drives the pipelined core for one fixed epoch | Avalon wrapper + Qsys co-fit with peripherals; manual `.rbf` flash; real on-board hashrate | 1–2 weeks |
| **2 — Autonomy (reboot)** | Self-updating across epochs | Precompile service + board fetch + reboot-reconfigure at epoch flip | ~1 week |
| **3 — Live reconfig** | No-reboot epoch switch | FPGA-Manager live reconfig + peripheral recovery + soak | 1–2 weeks |

**Total ≈ 4–7 weeks** of focused work. Phase 0 alone answers the single biggest
unknown (fit/timing/hashrate on our part with the toolchain) for a few days'
cost, and is a clean go/no-go gate before committing to the integration.

## 6. Decisions needed before starting

1. **Compile host:** where does it live (your PC / a VM / cloud), and is an
   always-on x86 with Quartus Lite acceptable?
2. **Reconfig style for v1:** is ~30 s reboot downtime per epoch fine (simple,
   robust), with live reconfig as a later nice-to-have?
3. **Throughput target if 150 MHz/T=4 won't co-fit** with peripherals — accept a
   lower clock/THROUGHPUT (still MH/s)?
4. **Keep the display/touch UI** in the pipelined bitstream (costs fabric,
   complicates reconfig) or drop it for maximum hashrate?
5. **Monitoring:** a missed/failed epoch compile = mining downtime. Acceptable
   with alerting, or need redundancy (two compile hosts)?
