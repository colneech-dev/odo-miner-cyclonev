# Building the FPGA Bitstream — Pipelined OdoCrypt Miner

This document covers building the FPGA bitstream for the deployed pipelined OdoCrypt
miner. Everything is driven by a single script; the manual Quartus GUI steps in the
original version of this file described the retired sequential-FSM core and should be
ignored.

---

## Overview

The deployed design is `pipelined_miner_top` — a fully-unrolled pipelined
`odo_encrypt` core running at 156.25 MHz (THROUGHPUT=6, ~26 MH/s). The OdoCrypt
epoch key is **baked into the FPGA LUTs at compile time**, so every epoch change
requires a full Quartus recompile. Automated epoch management is handled by
`scripts/epoch_build_deploy.ps1` + the board's `epoch-update.sh`.

**One-command build (the only supported path):**

```bash
# Run from Git Bash on Windows — Quartus is a Windows-only install
bash scripts/build-fpga.sh
```

Output: `hdl/quartus/output_files/odo_miner.rbf`

---

## Prerequisites

### Windows (required)

| Tool | Notes |
|---|---|
| **Quartus Prime Lite 25.1std** | Free; select **Cyclone V device support**. ~25 GB disk. Default install path assumed to be `C:\altera_lite\25.1std`. Set `QUARTUS_ROOT` env var if installed elsewhere. |
| **Git for Windows** | Provides Git Bash, which the build script runs in. |

### WSL (required for testbench gate)

The build script calls into WSL to:
1. Generate the per-epoch RTL (`odo_gen`, a C++ host tool)
2. Run the known-answer testbench (Icarus Verilog)

WSL2 with Ubuntu is assumed. Required WSL packages:

```bash
sudo apt install -y build-essential g++ iverilog
# OR use the OSS CAD Suite for iverilog (auto-detected by run_tb_pipe.sh):
# See SETUP_FROM_SCRATCH.md §3
```

---

## What the Script Does

`scripts/build-fpga.sh` runs five steps:

### Step 1 — Epoch RTL generation

The pipelined core bakes the OdoCrypt algorithm (with the current epoch key) into
FPGA LUTs at synthesis time. The per-epoch Verilog file `hdl/src/pipelined/odo_<ODOKEY>.v`
is **gitignored** (regenerable). The script reads `ODOKEY` and `THROUGHPUT` from
`hdl/quartus/odo_miner.qsf` and generates the file via `odo_gen` in WSL if missing
or if the `THROUGHPUT` localparam doesn't match.

**Do not hand-edit `odo_<ODOKEY>.v`** — always regenerate via `odo_gen`.

### Step 2 — Testbench gate (pipelined core + async FIFO)

Runs `hdl/tb/run_tb_pipe.sh` and `hdl/tb/run_tb_fifo.sh` under Icarus Verilog in
WSL. Both must pass before Quartus is invoked. This gate catches RTL regressions
before spending 30–60 min in the fitter.

Skip with `SKIP_TB=1` (not recommended for production builds):
```bash
SKIP_TB=1 bash scripts/build-fpga.sh
```

### Step 3 — Platform Designer regeneration (qsys-generate)

Runs `qsys-generate soc_system.qsys` to refresh the RTL copies that Quartus actually
compiles. Qsys caches its own copies in `hdl/qsys/soc_system/synthesis/submodules/`;
if you skip this step after editing RTL, Quartus silently compiles stale code. The
script verifies the submodule copies match the source files after regeneration.

**Always run qsys-generate after any RTL or Qsys change.**

### Step 4 — Quartus full compile

`quartus_sh --flow compile odo_miner` runs synthesis → placement → routing → timing
analysis → bitstream assembly. Typical time: **30–60 min**.

Log: `/tmp/quartus-flow.log`

### Step 5 — Sanity checks

The script asserts:
- Fitter status is `Successful`
- ≥ 60 RAM blocks used (confirms S-boxes are in BRAM, not LUT-RAM)
- No negative setup slack on any clock (fabric + 156.25 MHz miner clock)

If any check fails the script exits non-zero with a message pointing at the relevant
report file.

---

## Configuration — `odo_miner.qsf`

Two macros in `hdl/quartus/odo_miner.qsf` control the deployed algorithm:

```tcl
set_global_assignment -name VERILOG_MACRO "ODOKEY=<epoch_key>"
set_global_assignment -name VERILOG_MACRO "THROUGHPUT=6"
```

- `ODOKEY` is the OdoCrypt seed for the epoch (`ntime - ntime % 864000`). The
  `localparam THROUGHPUT` inside the generated `odo_<ODOKEY>.v` **must match** the
  `THROUGHPUT` macro in the QSF. A mismatch → wrong hash → 0 accepted shares. The
  script detects and refuses to proceed if they diverge.
- `THROUGHPUT=6` at 156.25 MHz → ~26 MH/s. `THROUGHPUT=4` would give ~37 MH/s but
  exceeds the on-board 1.1 V core regulator limit (brownout at ~2.2 A); deferred
  pending an external supply upgrade.

---

## Epoch Builds

For production epoch rollovers (every ~10 days), use the automated path instead of
this doc:

```powershell
# Windows PowerShell — builds and stages the next epoch bitstream
# (board auto-applies it via epoch-update.sh + reboot)
.\scripts\epoch_build_deploy.ps1 -EpochKey <new_key>
```

This script calls `build-fpga.sh` with the new key patched into the QSF, then
copies the output `.rbf` to the staged location on the board's FAT partition.

---

## Verifying the Build

After `build-fpga.sh` completes:

```
hdl/quartus/output_files/odo_miner.rbf   ~2.3 MB
hdl/quartus/output_files/odo_miner.fit.summary  — fitter report
hdl/quartus/output_files/odo_miner.sta.summary  — timing report
```

Key numbers to check in `odo_miner.fit.summary`:

| Metric | Expected |
|---|---|
| Logic utilization | < 75% ALM (device has 41,910) |
| Total RAM blocks | ≥ 60 (S-box BRAM) |
| Setup slack — fabric clock | ≥ 0 ns |
| Setup slack — miner clock (156.25 MHz) | ≥ 0 ns |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Quartus not found at $QUARTUS_ROOT` | Wrong install path | Set `QUARTUS_ROOT=C:/altera_lite/25.1std` (or wherever Quartus is) |
| `could not read ODOKEY/THROUGHPUT from .qsf` | QSF macro missing/malformed | Check the `VERILOG_MACRO` lines in `hdl/quartus/odo_miner.qsf` |
| `odo_gen failed to build` | Missing `g++` in WSL | `sudo apt install -y build-essential` |
| `Testbench failed` | RTL regression | Fix the RTL; check `hdl/tb/*.log`; do **not** use SKIP_TB=1 for production builds |
| `stale submodule copy: <file>` | qsys-generate didn't refresh a file | Usually a sign the Qsys system needs manual regeneration; try running `qsys-generate` manually and check for errors |
| `Fitter failed` | Design does not fit | Check ALM utilization in `.fit.rpt`; THROUGHPUT=4 will not fit on this device with current floor-plan |
| `Timing FAILED (negative slack)` | Routing congestion | Usually happens > 75% ALM; try slightly lower THROUGHPUT or relax unconstrained paths |
| `Only N RAM blocks` | S-boxes inferred as LUT-RAM | RTL regression in S-box inference; check `pipelined_miner_hw.tcl` fileset hasn't been changed |
| 0 accepted shares after reflash | ODOKEY or THROUGHPUT mismatch | Re-verify both are consistent between QSF macro and generated RTL localparam |

---

## SD Card Integration

`scripts/build-sdcard.sh` picks up `odo_miner.rbf` automatically when it exists in
`hdl/quartus/output_files/`. The U-Boot boot script loads it with `fpga load 0` and
enables the HPS↔FPGA bridges before booting Linux. See [BUILD_LINUX.md](BUILD_LINUX.md)
and [SETUP_FROM_SCRATCH.md](SETUP_FROM_SCRATCH.md) for the full build + flash flow.
