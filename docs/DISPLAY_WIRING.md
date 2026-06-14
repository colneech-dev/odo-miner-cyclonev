# SPI Touch Display — Wiring & Bring-up

**Module:** **KMRTM28028-SPI** — 2.8″ 240×320 SPI TFT, controller **ILI9341**,
resistive touch **XPT2046**, 14-pin single-row header. (Any ILI9341 + XPT2046
module with the same 14-pin layout is identical for this build.)

**Board connector:** `GPIO_0` header (J10/J12 area per the KFB schematic).
The board is ball-compatible with the Terasic DE10-Nano, verified against the
QMTECH KFB dual-SDRAM schematic (16 pins cross-checked). Header pin numbering
below follows the DE10-Nano convention — see "Pins to test first".

## Wiring table (KMRTM28028-SPI, in module pin order 1→14)

The first column is the silkscreen label / physical pin number on the module;
wire it straight down the module header.

| # | Module label | Function        | Board net  | GPIO_0 idx | Header pin | FPGA ball |
|---|--------------|-----------------|------------|------------|------------|-----------|
| 1 | VCC          | 3.3 V power     | 3V3        | —          | **29** ✓   | —         |
| 2 | GND          | Ground          | GND        | —          | **12/30** ✓| —         |
| 3 | CS           | LCD chip select | LCD_CS_n   | D3         | 4          | D11       |
| 4 | RESET        | LCD reset       | LCD_RST_n  | D5         | 6          | AH13      |
| 5 | DC (RS)      | data/command    | LCD_DC     | D4         | 5          | D8        |
| 6 | SDI (MOSI)   | LCD data in     | LCD_MOSI   | D1         | 2          | E8        |
| 7 | SCK          | LCD SPI clock   | LCD_SCLK   | D0         | 1          | V12       |
| 8 | LED          | backlight       | LCD_BL     | D6         | 7          | AF7       |
| 9 | SDO (MISO)   | LCD data out    | LCD_MISO   | D2         | 3          | W12       |
| 10| T_CLK        | touch SPI clock | TP_SCLK    | D7         | 8          | AH14      |
| 11| T_CS         | touch select    | TP_CS_n    | D10        | 13         | AD5       |
| 12| T_DIN        | touch data in   | TP_MOSI    | D8         | 9          | AF4       |
| 13| T_DO         | touch data out  | TP_MISO    | D9         | 10         | AH3       |
| 14| T_IRQ        | pen interrupt   | TP_IRQ_n   | D11        | 14         | AG14      |

✓ = **confirmed on hardware** (pin 29 = 3.30 V, pins 12 & 30 = GND). The
procedure that verified them is kept below for other board revisions.

Notes:
- The KMRTM28028-SPI is **3.3 V**. Feed VCC and all logic from 3.3 V. Some
  copies carry an AMS1117 regulator + 74HC125 level shifter (then VCC is
  3.3–5 V tolerant); with our 3.3 V header, just use 3.3 V either way.
- The `LED`/backlight pin is driven as a plain on/off GPIO (`LCD_BL`). On this
  module the backlight has its onboard drive; no external resistor needed.
- The module's micro-SD slot is unused — leave its pins unconnected.
- `GPIO_0` is shared with the two onboard MiSTer-style SDRAM chips. The
  bitstream holds both SDRAM chip-selects high (`SDRAM_CS0_n`=Y18,
  `SDRAM_CS1_n`=AD20), so the chips stay quiet. Don't combine this display
  setup with a design that drives the fabric SDRAM.

## Pins to test first (do this BEFORE connecting the module)

> **Status on this board:** confirmed — pin 29 = 3.30 V, pins 12 & 30 = GND.
> Note: with **no bitstream loaded**, signal pins (e.g. pin 1 / SCLK) read
> ~**3.1 V steady** — that is the Cyclone V configuration-time weak pull-up,
> not a power rail. Once `fpga.rbf` loads, the SPI core drives SCLK and it
> idles low. A steady 3.1 V on a signal pin is only a concern if it persists
> *after* the design is configured.

The DE10-Nano-style ball-out is verified, but the **power pins** on the GPIO_0
header are the one thing assumed from convention, so confirm them with a meter.
The signal pins don't need testing (they're driven by the FPGA at 3.3 V), but a
mis-identified VCC/GND can kill the panel instantly.

**With the board powered on, FPGA configured, nothing connected to the header:**

1. **Find a true GND reference** — meter on continuity/diode mode, one probe on
   a known chassis/board ground (e.g. a USB shell or a mounting hole), the other
   on header **pin 12** and **pin 30**. Both should read continuity to GND
   (≈0 Ω). These are your GND pins.
2. **Verify the 3.3 V pin** — meter on DC volts, black on a confirmed GND from
   step 1, red on header **pin 29**. Expect **3.30 V ±0.1**. If it reads 5 V,
   0 V, or anything else, **stop** — do not use it as VCC.
3. **Sanity-check a couple of signal balls are NOT power** — black on GND, red
   on header **pin 1** (LCD_SCLK / ball V12): it should sit near 0 V or toggle,
   **not** a steady 3.3 V or 5 V rail. Confirms you're not about to feed a
   signal pin into the module's VCC.
4. **After wiring, before power-on:** with the board OFF, meter continuity
   between the module's **VCC and GND** pins — it should be high resistance
   (no dead short). A near-0 Ω reading means a wiring short; fix before powering.

If pin 29 isn't 3.3 V on your board revision, take 3.3 V from any other
confirmed 3V3 header pin and GND from pin 12/30 — only VCC/GND placement varies;
the signal balls in the table are fixed by the FPGA pin assignment.

## What drives it

| Layer | Component |
|---|---|
| FPGA  | `spi_lcd` (Avalon SPI, ~25 MHz SCLK) @ `0xFF201000`, `spi_touch` (~1.56 MHz) @ `0xFF201100`, `pio_lcd` (D/C, RESET, BL) @ `0xFF201200`, `pio_in` (PENIRQ, KEY0/1) @ `0xFF201300`, `pio_led` @ `0xFF201400` |
| Kernel | `spi-altera-platform`, `fbtft`/`fb_ili9341` (→ `/dev/fb0`), `ads7846` (→ `/dev/input/event*`), `gpio-altera`, `gpio-keys`, `gpio-leds` — see [linux-display.fragment](../linux/linux-display.fragment) and [socfpga_cyclone5_qmtech_odo.dts](../linux/socfpga_cyclone5_qmtech_odo.dts) |
| Userspace | `odo-ui` ([sw/odo-ui](../sw/odo-ui/odo_ui.c)): dashboard + touch RESTART/REBOOT buttons, reads `/run/odod/status.json` written by `odo-miner` |

## Bring-up checklist

1. Boot the SD image (U-Boot loads `fpga.rbf` and enables the bridges before
   Linux — display drivers need the fabric alive at probe time).
2. `dmesg | grep -E "ili9341|ads7846|altera"` — expect the SPI masters, the
   panel (`graphics fb0: fb_ili9341 frame buffer`), and the touchscreen.
3. Panel test: `cat /dev/urandom > /dev/fb0` → static. Console test: add
   `fbcon=map:0` to bootargs to get the Linux console on the TFT.
4. Touch test: `evtest /dev/input/event0` and prod the screen.
5. `odo-ui` starts automatically (`/etc/init.d/S95odoui`). Calibration
   constants live in `touch_open()` in `odo_ui.c`; tweak `min/max/swap/inv`
   if taps land in the wrong place (panel orientation varies by module).

   **Confirmed calibration values (2026-06-11, KMRTM28028-SPI, rotate=270):**
   `swap_xy=1, inv_y=1` — verified on hardware; taps land correctly with
   these settings. The T_IRQ line (GPIO_0 D11 / header pin 14) is wired but
   SPI interrupts **do not reach the ARM GIC** on this board. The ads7846
   driver must run in **polling mode** (no `interrupts` property in DTS, or
   `pendown-gpio` left unset). Interrupt mode will cause the touch driver to
   silently stop delivering events.

## LEDs and buttons

- `KEY0`/`KEY1` (AH17/AH16) arrive as `gpio-keys` (KEY_UP/KEY_DOWN).
- Board LEDs: `odo:green:status` has the kernel heartbeat trigger by default;
  the rest are free via `/sys/class/leds/`.
