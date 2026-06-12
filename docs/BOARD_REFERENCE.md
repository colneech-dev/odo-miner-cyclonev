# QMTECH Cyclone V SoC KFB (Dual SDRAM) — Board Reference

Everything extracted from
`docs/QMTECH_Cyclone_V_SoC_KFB_Dual_SDRAM_Schematic_20240607_V01.pdf`
(9 sheets, rev 2024-06-07) during the 2026-06-10 review — including hardware
this project does **not** currently use, so future work doesn't have to
re-mine the PDF.

Confidence legend: ✅ verified (cross-checked against a second source or the
working design), ◐ read from the schematic text only, ? inferred.

> **See also `docs/SCHEMATIC_PINMAP.md`** — the detailed clock / reset / config
> / I/O ball map extracted during the 2026-06-11 hardware bring-up, cross-checked
> against `odo_miner.qsf`. It documents the `CLOCK_50=V11` verification, the
> `RESET_n=AE25`→NCEO mistake (root cause of the frozen fabric), and a flag that
> the LCD SPI pins sit on clock-capable balls.

---

## The headline fact ✅

The board is **ball-compatible with the Terasic DE10-Nano** (the FPGA symbol
even lists `5CSEBA6U23 / 5CSXFC6C6U23 / 5CSEMA6U23` as alternates), laid out
MiSTer-style. DE10-Nano pin tables, GHRD projects, and MiSTer cores are
directly applicable. Verified by cross-checking 16 GPIO/LED/KEY/clock balls
between the schematic and the DE10-Nano GHRD (all matched, incl.
`CLOCK_50 = V11`).

Fitted FPGA: `5CSXFC6C6U23I7` — Cyclone V SX, 41,910 ALMs, 553 M10K,
112 DSP, 484-ball UBGA, industrial, slowest speed grade (-I7).

## Sheet-by-sheet inventory

| Sheet | Contents |
|---|---|
| 1 | Differential trace impedance notes; connectors J2/J3/J8/J24–J28 ◐ (power/jacks; not individually identified) |
| 2 | HPS Gigabit Ethernet, RGMII PHY (EMAC1) ✅ — used, working in defconfig |
| 3 | **ADV7513 HDMI transmitter (U16)** ◐ — 24-bit parallel RGB from fabric pins (`HDMI_TX_D0..23`, CLK/DE/HSYNC/VSYNC), config I2C + interrupt on fabric pins, I2S audio inputs. Unused by this project |
| 4 | Boot configuration: **BOOTSEL[2:0]=101 = SD card boot** ✅, CLKSEL=00, MSEL pins; SD slot (8-bit HPS SDIO) ✅; 25 MHz system clocks |
| 5 | FPGA fabric banks: GPIO_0/GPIO_1 headers, **2× AS4C32M16SB SDRAM sharing GPIO_0 pins** ✅, Arduino-style header, **LTC2308-class SPI ADC** ◐ (`ADC_CONVST/SCK/SDI/SDO`), LED0–7 ✅, KEY0/KEY1 ✅, 50 MHz oscillators (SYS_CLK1/2/3_50M), JTAG |
| 6 | **J1 = 40-pin FPC connector** ◐ sharing the `HDMI_TX_*` RGB bus — standard 40-pin RGB TFT panel interface (800×480-class) |
| 7 | SW0–SW3 push buttons ◐ (nets G16/G27/G38/G49 — NOT DE10-Nano balls; treat as unverified), **CH340N USB-UART on J4 mini-USB → HPS UART0 console** ✅ |
| 8 | Power tree: regulated 5 V input (VIN), 3V3/2V5/1V5/1V1 rails ◐ |
| 9 | USB: HPS USB1 ULPI PHY ✅ (host port used for WiFi dongle) |

## Resources usable by future work

### Fabric-side SDRAM (2× AS4C32M16SB, 64 MB total) ◐
MiSTer-style: shares the GPIO_0 header balls (MiSTer `sys.tcl` has the exact
mapping). **Mutually exclusive with using GPIO_0 as GPIO** — this project
uses GPIO_0 for the SPI display and holds both SDRAM chip selects deasserted
(`SDRAM_CS0_n = Y18`, `SDRAM_CS1_n = AD20` — the CS1 ball is read from the
schematic adjacency only ◐, but driving it high is safe under either
interpretation). If a future design wants this SDRAM (e.g., a frame buffer),
the display must move to GPIO_1.

### GPIO_1 header (J12 area) — fully free ✅ balls from DE10-Nano GHRD
36 user I/O, no sharing. First pins: D0=Y15, D1=AG28, D2=AA15, D3=AH27,
D4=AG26, D5=AH24, D6=AF23, D7=AE22, D8=AF21, D9=AG20 … (full list in any
DE10-Nano GHRD qsf). Use this header for any additional hardware
(temperature sensor, relays, fans).

### Arduino header + ADC ◐
`Arduino_IO0..15`, `Arduino_Reset_n`, and an LTC2308-compatible SPI ADC
(8-ch, 12-bit). The natural path for **analog temperature sensing**: a
thermistor divider into an ADC channel + a small fabric SPI master (or
bit-bang) → would give the temps the Cyclone V die sensor can't (no internal
TSD ADC on this family).

### HDMI out (ADV7513) + J1 RGB-LCD ◐
A full video path exists in hardware: DDR3 framebuffer → fabric scanout →
24-bit RGB → either HDMI or a 40-pin FPC panel. Documented as the upgrade
path beyond the SPI TFT (docs/DISPLAY_WIRING.md covers why SPI was chosen:
zero fabric video logic, mainline drivers).

### Console / recovery ✅
J4 mini-USB → CH340N → HPS UART0, 115200n8. This is the always-works path
when network and display are both down.

## Known unknowns (check before relying on)
- GPIO header physical pin numbering (1↔ball order, power pin positions
  11/12/29/30) follows the DE10-Nano convention but has not been verified
  against the QMTECH silkscreen — **meter-check before wiring** (also called
  out in DISPLAY_WIRING.md).
- SW0–SW3 ball locations (sheet 7 nets G16/G27/G38/G49 don't decode to
  sensible U23 balls from text extraction). KEY0/KEY1 (AH17/AH16 ✅) are the
  buttons this project uses instead.
- J1 FPC pinout order and whether it carries touch lines.
- Which of J2/J3/J8/J24–J28 are power vs expansion.
- Exact Ethernet PHY part and ADC part numbers (function clear, marking not
  extracted).

## Power-on / boot chain (as configured) ✅
1. BootROM (BOOTSEL=101) loads U-Boot SPL from SD raw partition (A2).
2. SPL → U-Boot → `boot.scr`: loads `fpga.rbf`, `fpga load`, `bridge enable`,
   then `zImage` + `socfpga_cyclone5_qmtech_odo.dtb`, boots Linux.
3. BusyBox init: dhcpcd → S45wifi (if configured) → S90odod (miner) →
   S95odoui (TFT panel) → S96odowebd (web dashboard, port 80).
