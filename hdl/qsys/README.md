# Platform Designer System — soc_system

This directory will contain the Qsys/Platform Designer project file
(`soc_system.qsys`) and its generated HDL output.

## How to create the system

1. Start from the **QMTECH Cyclone V SoC GHRD** (Golden Hardware Reference
   Design) available from the QMTECH GitHub or vendor page for the
   `5CSXFC6C6U23` board. It already has the HPS, DDR3 controller, and EMAC
   wired correctly with verified pin assignments.

2. Open `soc_system.qsys` from the GHRD in Platform Designer.

3. Add the `odocrypt_top` IP:
   - In Platform Designer: IP Catalog → New Component → import `odocrypt_top.v`
   - Set the Avalon-MM slave parameters: data width 32, address width 8.
   - Connect the slave's `clk` and `reset` to the system clock/reset.
   - Connect the slave's Avalon-MM port to the **Lightweight HPS-to-FPGA bridge**
     master (not the full H2F bridge).
   - Set the slave base address to **0x00000000** within the LWH2F window.
     This makes the miner registers appear at physical address `0xFF200000`
     on the HPS, which is what `hps/hps_regs.h` expects.

4. Generate HDL: Platform Designer → Generate → HDL → output to this directory.

5. Update `hdl/quartus/odo_miner.qsf`: uncomment the `QSYS_FILE` and the
   generated `soc_system.v` source file lines.

6. Update `hdl/src/soc_top.v`: uncomment the `soc_system u_soc (...)` block
   and remove the tie-off assignments at the bottom.

## Required system contents

| Component | Role |
|---|---|
| HPS | ARM Cortex-A9, DDR3, EMAC1 (RGMII), SD, UART, USB |
| LWH2F bridge | Lightweight HPS-to-FPGA Avalon-MM bridge (2 MB window at 0xFF200000) |
| `odocrypt_top` | Miner slave at offset 0x0 within LWH2F |
| Clock source | 50 MHz from `CLOCK_50` board oscillator |

## Device
`5CSXFC6C6U23` — Cyclone V SX, 110K LE, 484-ball BGA

## Pin assignment source
Do **not** invent HPS pin assignments. Use the QMTECH GHRD `.qsf` as the
authoritative source. The GHRD `.qsf` already contains the correct DDR3,
EMAC, SD, UART, and USB pin locations for this board.
