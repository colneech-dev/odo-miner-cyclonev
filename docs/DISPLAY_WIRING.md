# SPI Touch Display — Wiring & Bring-up

**Target module:** ILI9341-class SPI TFT (2.2"–3.2", 320×240) with XPT2046
resistive touch — the common 14-pin red breakout modules.

**Board connector:** `GPIO_0` header (J10/J12 area per the KFB schematic).
The board is ball-compatible with the Terasic DE10-Nano, verified against the
QMTECH KFB dual-SDRAM schematic (16 pins cross-checked). Header pin numbering
below follows the DE10-Nano convention — **verify pins 11/12/29/30 (power) on
the QMTECH silkscreen with a meter before connecting the module.**

## Wiring table

| Module pin | Function        | Net        | GPIO_0 index | Header pin | FPGA ball |
|-----------|------------------|------------|--------------|------------|-----------|
| VCC       | 3.3 V            | 3V3        | —            | 29         | —         |
| GND       | Ground           | GND        | —            | 12 or 30   | —         |
| SCK       | Display SPI clk  | LCD_SCLK   | D0           | 1          | V12       |
| SDI/MOSI  | Display data in  | LCD_MOSI   | D1           | 2          | E8        |
| SDO/MISO  | Display data out | LCD_MISO   | D2           | 3          | W12       |
| CS        | Display select   | LCD_CS_n   | D3           | 4          | D11       |
| DC        | Data/command     | LCD_DC     | D4           | 5          | D8        |
| RESET     | Display reset    | LCD_RST_n  | D5           | 6          | AH13      |
| LED       | Backlight        | LCD_BL     | D6           | 7          | AF7       |
| T_CLK     | Touch SPI clk    | TP_SCLK    | D7           | 8          | AH14      |
| T_DIN     | Touch data in    | TP_MOSI    | D8           | 9          | AF4       |
| T_DO      | Touch data out   | TP_MISO    | D9           | 10         | AH3       |
| T_CS      | Touch select     | TP_CS_n    | D10          | 13         | AD5       |
| T_IRQ     | Pen interrupt    | TP_IRQ_n   | D11          | 14         | AG14      |

Notes:
- All signals are 3.3 V LVTTL. Most ILI9341 modules are 3.3 V-native — do
  **not** feed VCC from the 5 V pin unless your module has a regulator and
  level shifters.
- The backlight LED pin on some modules needs a series resistor; many have
  one onboard. `LCD_BL` is driven as a plain on/off GPIO.
- `GPIO_0` is shared with the two onboard MiSTer-style SDRAM chips. The
  bitstream holds both SDRAM chip-selects high (`SDRAM_CS0_n`=Y18,
  `SDRAM_CS1_n`=AD20), so the chips stay quiet. Don't use this display setup
  together with a design that drives the fabric SDRAM.

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

## LEDs and buttons

- `KEY0`/`KEY1` (AH17/AH16) arrive as `gpio-keys` (KEY_UP/KEY_DOWN).
- Board LEDs: `odo:green:status` has the kernel heartbeat trigger by default;
  the rest are free via `/sys/class/leds/`.
