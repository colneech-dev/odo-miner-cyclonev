# Building the Quartus/Qsys Project for QMTECH Cyclone V SoC

> ⚠️ **STALE — FSM-era manual walkthrough. Do not follow for a greenfield build.**
> This page describes the *retired* sequential-FSM core (`odocrypt_top`, a
> single 50 MHz clock, runtime-loaded epoch tables). The **deployed** design is
> the pipelined core (`pipelined_miner_top`, 156.25 MHz miner PLL, epoch baked
> into LUTs). For an actual build use the scripted flow, which handles the
> epoch-RTL generation, the pipelined sim gate, and timing checks:
>
> - **One-command build:** `bash scripts/build-fpga.sh` (regenerates
>   `odo_<ODOKEY>.v`, runs `run_tb_pipe.sh`, qsys-generate, compile, checks).
> - **Per-epoch build + stage:** `scripts/epoch_build_deploy.ps1`.
> - **Register/architecture contract:** `docs/register-map.md`.
>
> The Platform Designer system already exists (`hdl/qsys/soc_system.qsys`,
> extended via `hdl/qsys/qsys_add_peripherals.tcl`) — do not rebuild it by hand
> from the steps below. The content here is kept only for HPS/bridge background.

## Quick Summary

This guide walks you through the Quartus/Platform Designer setup for the QMTECH Cyclone V SoC board.

**Your board:** QMTECH Cyclone V SoC with **5CSXFC6C6U23I7N**

**Expected outputs:**
- `hdl/quartus/output_files/odo_miner.sof` — SRAM bitstream (JTAG programming)
- `hdl/quartus/output_files/odo_miner.rbf` — Raw binary bitstream (SD card boot)
- `hdl/qsys/soc_system.qsys` — Platform Designer system (already exists)

---

## Step 1: Verify Quartus Project

The Quartus project already exists and is configured for your board.

1. Launch **Quartus Prime**
2. **File → Open Project** → `hdl/quartus/odo_miner.qpf`
3. Verify device is **5CSXFC6C6U23I7** in **Project → Device**
   - If it shows something else, change it to **5CSXFC6C6U23I7**

---

## Step 2: Open/Review Platform Designer System

The Qsys system already exists at `hdl/qsys/soc_system.qsys`.

1. In Quartus: **Tools → Platform Designer** (or **Qsys** if older version)
2. **File → Open** → `hdl/qsys/soc_system.qsys`
3. Review the system:
   - **HPS (Hard Processor System)** — ARM Cortex-A9 with SDRAM, Ethernet, UART, SD/MMC
   - **h2f_lw** — Lightweight HPS-to-FPGA bridge (AXI Lite)
   - **odocrypt_top** — Custom Avalon-MM slave (miner core)

### If components are missing or need updates:

**Add HPS Component:**
1. Click **+ Component** on canvas
2. Search for **HPS (Hard Processor System)** → Add
3. Double-click to configure:
   - Device: **5CSXFC6C6U23I7**
   - Enable SDRAM, EMAC (Ethernet), UART, SD/MMC
   - Use defaults, click **Finish**

**Add LWH2F Bridge:**
1. **+ Component** → search **Lightweight HPS to FPGA**
2. Add to canvas
3. Connect HPS **h2f_lw_axi_master** → Bridge **axi_slave** (drag connection)

**Add odocrypt_top Miner Slave:**
1. **+ Component** → **New Component**
2. Browse to `hdl/src/odocrypt_top.v`
3. Quartus auto-detects Avalon ports — verify and click **Finish**
4. Drag onto canvas
5. Connect Bridge **axi_master** → odocrypt_top **avs** (Avalon slave)
6. Set odocrypt_top base address to **0x0** (relative to 0xFF200000)

**Clock & Reset:**
- Ensure **clk_0** (50 MHz) drives: HPS, Bridge, odocrypt_top
- Ensure **reset_n** (from HPS) drives all components

---

## Step 3: Generate Qsys HDL

1. In Platform Designer: **Generate → Generate HDL**
2. Output directory: `hdl/qsys/`
3. Click **Generate** — creates `soc_system.v` and IP cores

---

## Step 4: Verify Top-Level Integration

The Quartus top-level is `hdl/src/soc_top.v`. Verify it instantiates `soc_system`:

1. Open `hdl/src/soc_top.v` in Quartus
2. Confirm it has:
   ```verilog
   soc_system u_soc (
       .clk_clk(CLOCK_50),
       .reset_reset_n(RESET_n),
       // ... HPS pins auto-connected by Pin Planner
   );
   ```

If missing, add the instantiation above.

---

## Step 5: Pin Assignment

1. **Assignments → Pin Planner**
2. Verify HPS pins are auto-assigned (green = connected)
3. Verify FPGA I/O:
   - **CLOCK_50** → Pin **V11** (check QMTECH schematic)
   - **RESET_n** → Pin **AH17** (check QMTECH schematic)
4. **File → Save** to save assignments

---

## Step 6: Compile

### 6.1 Analysis & Elaboration (syntax check)
1. **Processing → Start → Start Analysis & Elaboration**
2. Fix any errors, should complete in 1–2 min

### 6.2 Full Compilation
1. **Processing → Start Compilation**
2. Takes 10–30 min, watch Messages panel
3. Success → creates `output_files/odo_miner.sof` and `odo_miner.rbf`

---

## Step 7: Program FPGA via JTAG

1. Connect JTAG programmer to board
2. **Tools → Programmer**
3. **Hardware Setup** → select your JTAG cable
4. **Add File** → `hdl/quartus/output_files/odo_miner.sof`
5. Check **Program/Configure**
6. Click **Start** — wait for "100% (Successful)"

FPGA is now programmed. Test with:
```bash
fpga_smoke_test
```

Should return valid register values (not 0xFFFFFFFF).

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Device 5CSXFC6C6U23 is invalid" | Use full name: **5CSXFC6C6U23I7** |
| Missing soc_system in Qsys | Regenerate: **Generate → Generate HDL** |
| JTAG programming fails | Check USB cable, try **Tools → Options → Quartus II → EDA Tool Options** |
| fpga_smoke_test returns 0xFFFFFFFF | FPGA not programmed, or LWH2F bridge disabled |

---

## Next Steps

1. **HPS Linux boot** — Build and boot Buildroot image (see BUILD_LINUX.md)
2. **Mining test** — Run `odo-miner` against test pool
3. **Hardware validation** — Follow BRINGUP.md for full validation sequence
