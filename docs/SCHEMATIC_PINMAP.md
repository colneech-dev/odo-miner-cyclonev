# Schematic pin map — QMTECH Cyclone V SoC KFB (Dual SDRAM)

Extracted from `docs/QMTECH_Cyclone_V_SoC_KFB_Dual_SDRAM_Schematic_20240607_V01.pdf`
(9-page schematic, rev V01 2024-06-07) during the 2026-06-11 hardware bring-up,
and cross-checked against `hdl/quartus/odo_miner.qsf`. FPGA: `5CSXFC6C6U23I7`
(Cyclone V SX, 484-ball UBGA).

> Legend: ✅ verified against schematic · ◐ inferred (DE10-Nano convention,
> schematic text-extraction couldn't fully resolve the net↔ball routing) ·
> ⚠ concern flagged for follow-up.

---

## 1. Clock architecture ✅ (the decisive bring-up finding)

The board has **three 50 MHz** oscillators (`SYS_CLK1/2/3_50M`), **two 25 MHz**
(`SYS_CLK1/2_25M`), plus the HPS clocks and Ethernet PHY clocks. The Cyclone V
dedicated clock-capable balls present on the schematic:

| Ball | FPGA function (schematic) | Bank | Role |
|------|---------------------------|------|------|
| **V11** | `CLK0P, FPLL_BL_FBP` (DIFFIO_RX_B31P) | 3B | **CLOCK_50 = `SYS_CLK3_50M`** ✅ live 50 MHz osc, used by the design (verified visually) |
| W11 | `CLK0N, FPLL_BL_FBN` | 3B | → net `GPIO_0_D25` ✅ |
| V12 | `CLK0N`-pair / `CLK1` (DIFFIO_RX_B39) | 3B | → net `GPIO_0_D0` → LCD_SCLK ✅ (N-half, no osc) |
| W12 | `CLK1` (DIFFIO_RX_B39) | 3B | → net `GPIO_0_D2` → LCD_MISO ✅ |
| Y13 | `CLK2P` (DIFFIO_RX_B47P) | 4A | `SYS_CLK2_50M` ◐ |
| AA13 | `CLK2N` | 4A | |
| Y15 | `CLK3P` (DIFFIO_RX_B55P) | 4A | 25 MHz osc ◐ |
| AA15 | `CLK3N` | 4A | |
| **E11** | `CLK6P, FPLL_TL_FBP` (DIFFIO_RX_T9P) | 8A | **`SYS_CLK1_50M`** ✅ live 50 MHz osc (verified) |
| D11 | `CLK6N, FPLL_TL_FBN` | 8A | → net `GPIO_0_D3` → LCD_CS_n ✅ (N-half of E11 pair, no osc) |
| E8 | `FPLL_TL_CLKOUT0/P/FB` (DIFFIO_TX_T4P) | 8A | → net `GPIO_0_D1` → LCD_MOSI ✅ |
| D8 | `FPLL_TL_CLKOUT1/N` | 8A | → net `GPIO_0_D4` → LCD_DC ✅ |
| C12 | `CLK7P` (DIFFIO_RX_T1P) | 8A | → net `GPIO_0_D18` |
| Y24 | `CLK4P, FPLL_BR_FBP` | 5B | |
| W24 | `CLK4N, FPLL_BR_FBN` | 5B | |
| W21 | `CLK5P` | 5B | |
| W20 | `CLK5N` | 5B | |
| AB26 | `FPLL_BR_CLKOUT0/P/FB` | 5B | |
| AD12 | `FPLL_BL_CLKOUT0/P/FB` | 3B | |
| E20 | `HPS_CLK1` | 7A | HPS reference clock |
| D20 | `HPS_CLK2` | 7A | HPS reference clock |

**Bring-up conclusion:** `CLOCK_50 = PIN_V11` (the `.qsf` assignment) is the
`CLK0P` pin carrying `SYS_CLK1_50M` — **correct**, matching the DE10-Nano
`FPGA_CLK1_50 = V11`. The whole fabric, including the LWH2F bridge AXI clock
(`h2f_lw_axi_clock`/`h2f_axi_clock` ← `clk_0` ← CLOCK_50 in `soc_system.qsys`),
is clocked from here. This is why the internal power-on-reset added to
`soc_top.v` is sound — it has a live 50 MHz clock to release from.

---

## 2. FPGA configuration straps ✅

| Signal | Ball(s) | Note |
|--------|---------|------|
| MSEL0..4 | J10 / H9 / G6 / K10 / K9 | mode-select for FPGA config |
| nCONFIG | F7 | |
| CONF_DONE | J8 | |
| nSTATUS | H8 | |
| DCLK | AA8 | (3A) active-serial config clock |
| AS_DATA0 / ASDO | AD7 | (3A) |
| **NCEO** | **AE25** | (5A, `DIFFIO_TX_R3P`) — cascade config output |

**HPS boot select (strapped on-board, not a DIP switch):** the schematic states
*"Default Setting: BOOTSEL[2:0]=101 (Boot from SD CARD), CLKSEL[1:0]=00"*. The
strap bits are on HPS GPIO pins: BOOTSEL0=`HPS_GPIO60`(J17), BOOTSEL1=
`HPS_GPIO33`(A6), BOOTSEL2=`HPS_GPIO28`(D15); CLKSEL0=`HPS_GPIO66`(C16),
CLKSEL1=`HPS_GPIO62`(H17). So **SD-card boot is hardwired** — no jumper to set.

**Bring-up conclusion:** `RESET_n` was assigned to `PIN_AE25` in the `.qsf`, but
AE25 is the **NCEO configuration pin**, *not* any reset. Driving the fabric
reset from a config I/O is wrong — it floats / is held, freezing the fabric.
This is the root cause of the dead LWH2F access; fixed by the internal POR in
`soc_top.v` (AE25 ignored). There is **no dedicated fabric reset pin** on this
board — all true resets are HPS-side (below).

---

## 3. Reset signals ✅ (all HPS-side)

| Signal | Ball | Bank | Role |
|--------|------|------|------|
| HPS_NRST | A23 | 7A | HPS cold reset (nRST) |
| HPS_NPOR | H19 | 7A | HPS power-on reset |
| HPS_TRST | C22 | 7A | HPS JTAG TAP reset |
| HPS_PORSEL | E18 | 7A | POR select |
| HPS_RESET# | V28 | 6B | DDR3 reset (HPS hard memory controller) |

There is no fabric `RESET_n` net — confirming §2.

---

## 4. Buttons / LEDs

The schematic shows buttons `KEY0, KEY1, KEY2, KEY5` and an `HPS_KEY`, plus
fabric `LED0..7`, `HPS_LED`, and Ethernet `HPS_ENET_LED1/LED2`. The schematic
text extraction did not cleanly resolve their individual balls, but the `.qsf`
assignments (consistent with the DE10-Nano ball-out the rest of the board
follows) are:

| Signal | Ball (.qsf) | | Signal | Ball (.qsf) |
|--------|------|---|--------|------|
| KEY0 | AH17 | | LED0 | W15 |
| KEY1 | AH16 | | LED1 | AA24 |
| | | | LED2 | V16 |
| | | | LED3 | V15 |
| | | | LED4 | AF26 |
| | | | LED5 | AE26 |
| | | | LED6 | Y16 |
| | | | LED7 | AA23 |

(`KEY2/KEY5/HPS_KEY` are unused by this project; KEY0/KEY1 → `pio_in`.)

---

## 5. ✅ Resolved: LCD SPI pins are correctly on the GPIO_0 header

Originally flagged as a concern (the LCD SPI balls are all clock-capable pins
in banks 3B/8A). **Verified by visually tracing the FPGA pin table on schematic
sheet 5** — every LCD pin routes to a GPIO_0 header net, so they are *not*
stranded on clock/oscillator nets:

| `.qsf` signal | Ball | Schematic function | → net |
|---------------|------|--------------------|-------|
| LCD_SCLK | V12 | bank 3B clock pin (N-half) | **GPIO_0_D0** ✅ |
| LCD_MOSI | E8  | bank 8A FPLL_TL_CLKOUT0    | **GPIO_0_D1** ✅ |
| LCD_MISO | W12 | bank 3B CLK1               | **GPIO_0_D2** ✅ |
| LCD_CS_n | D11 | bank 8A CLK6N (N-half)     | **GPIO_0_D3** ✅ |
| LCD_DC   | D8  | bank 8A FPLL_TL_CLKOUT1    | **GPIO_0_D4** ✅ |
| LCD_RST_n | AH13 | regular I/O | (GPIO_0) |
| LCD_BL    | AF7  | regular I/O | (GPIO_0) |
| TP_SCLK/MOSI/MISO/CS_n | AH14/AF4/AH3/AD5 | regular I/O | (GPIO_0) |
| TP_IRQ_n | AG14 | regular I/O | (GPIO_0) |

The two LCD pins that share a differential pair with a 50 MHz oscillator —
`V12` (N-half of `V11=SYS_CLK3_50M`) and `D11` (N-half of `E11=SYS_CLK1_50M`) —
use only the free N-half as single-ended GPIO, which is electrically valid: the
oscillators are single-ended on the P-pins (V11/E11). **No contention, no
remap needed.** The display pin assignments in `odo_miner.qsf` are correct.

Remaining (cosmetic) follow-up for display bring-up: cross-check each
`GPIO_0_D0..D4` against its physical header pin number and `docs/DISPLAY_WIRING.md`
— but the fastest confirmation is a continuity check on real hardware when the
panel is wired. None of this affects the miner (LWH2F + DDR3 are independent).

---

## 6. Other documented blocks (from BOARD_REFERENCE.md, schematic sheets)

- Sheet 2: HPS Gigabit Ethernet, RGMII PHY on EMAC1 (`HPS_ENET_*`,
  GTX_CLK / RX_CLK / CLK125).
- Sheet 3: ADV7513 HDMI transmitter (24-bit RGB from fabric) — unused.
- Sheet 5: GPIO_0 / GPIO_1 headers (`GPIO_0_D0..D35`, `GPIO_1_D0..`), 2×
  AS4C32M16SB fabric SDRAM sharing GPIO_0 (`SDCS_0` on GPIO_0_D28 area; the
  design holds `SDRAM_CS0_n=Y18`, `SDRAM_CS1_n=AD20` high), LTC2308-class SPI
  ADC, LED0–7, KEY0/KEY1.
- Sheet 6: J1 40-pin FPC RGB-LCD (shares the HDMI RGB bus).
- Sheet 7: CH340N USB-UART on J4 mini-USB → HPS UART0 console (115200 8N1) —
  the always-works recovery path used throughout bring-up.

See `docs/BOARD_REFERENCE.md` for the sheet-by-sheet inventory and
`docs/DISPLAY_WIRING.md` for the physical TFT hookup.
