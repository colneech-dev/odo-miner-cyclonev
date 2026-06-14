# Fan & Temperature Sensor Wiring — J12 (GPIO_1)

Covers the DS18B20 one-wire temperature sensor, 4-wire PWM fan, and optional
reset button, all on the J12 (GPIO_1) header.  J12 is fully free — no signals
shared with the display (display is on GPIO_0).

---

## J12 header power pins (DE10-Nano / MiSTer convention, verified)

| J12 pin | Rail | Status |
|---------|------|--------|
| 11 | 5 V | **Confirmed 5.4 V by meter** — within 5 V fan tolerance |
| 12 | GND | Available |
| 29 | 3.3 V | Available |
| 30 | GND | Available |

GPIO_0 pins 29 and 30 are occupied by the display — J12 pins 29/30 are separate.

---

## Complete J12 pin assignment

| J12 pin | HPS signal | portA | GPIO# | Connected to |
|---------|-----------|-------|-------|--------------|
| 11 | 5 V | — | — | Fan VCC (red wire) |
| 12 | GND | — | — | Fan GND (black) + DS18B20 GND, shared |
| 29 | 3.3 V | — | — | DS18B20 VDD + top of all pull-up resistors |
| 33 | HPS_SPIM_MOSI | portA.1 | 462 | DS18B20 DATA |
| 34 | HPS_SPIM_SS | portA.0 | 461 | Fan PWM (blue wire) |
| 35 | HPS_SPIM_CLK | portA.2 | 463 | Fan tach (yellow wire) |
| 36 | HPS_SPIM_MISO | portA.3 | 464 | Reset button (one side) |

---

## Passive components

```
Pin 29 (3.3V) ─┬─ 4.7 kΩ ──── Pin 33  (DS18B20 one-wire pull-up)
               ├─ 10 kΩ  ──── Pin 35  (fan tach pull-up)
               └─ 10 kΩ  ──── Pin 36  (reset button pull-up)

Pin 36 ── momentary switch ── Pin 12 (GND)   [reset button]
```

Pins 29, 33, 35, and 36 are all odd-numbered (same row of the header).
Physical span for resistors:

| Resistor | Pins | Span |
|----------|------|------|
| 4.7 kΩ (DS18B20) | 29 → 33 | 10 mm (2 positions) |
| 10 kΩ (tach) | 29 → 35 | 15 mm (3 positions) |
| 10 kΩ (reset btn) | 29 → 36 | 18 mm (3.5 positions, crosses rows) |

Standard ¼W through-hole resistors fit with legs bent directly into header sockets.

---

## DS18B20 sensor (3-wire mode)

| DS18B20 pin | J12 pin |
|-------------|---------|
| VDD | 29 (3.3 V) |
| GND | 12 (GND) |
| DATA | 33 |

4.7 kΩ pull-up between DATA (pin 33) and VDD (pin 29).

---

## 4-wire PWM fan

| Fan wire | J12 pin | Notes |
|----------|---------|-------|
| Red (VCC) | 11 | 5.4 V measured |
| Black (GND) | 12 | Shared with DS18B20 GND |
| Blue (PWM) | 34 | Open-drain input on fan; HPS drives low = min speed |
| Yellow (tach) | 35 | Open-collector; 10 kΩ pull-up to pin 29 |

Fan PWM note: at 0 % duty cycle (GPIO low) the fan runs at minimum speed,
not fully off.  For simple thermal on/off control this is acceptable.
Tach pulses twice per revolution; RPM = (falling edges / 2) × 60 / interval.

---

## Reset button

Wire a momentary normally-open push button between J12 pin 36 and J12 pin 12
(GND).  10 kΩ pull-up from pin 36 to pin 29 (3.3 V) holds the line high at
rest; pressing the button pulls it to GND.

GPIO 464 (portA.3) is read from Linux userspace via `/sys/class/gpio/gpio464/`.
odo-ui polls this pin and triggers miner restart or board reboot depending on
press duration (short = restart miner, long ≥ 3 s = reboot).

---

## Kernel config requirements (DTS overlay)

File: `boot/devicetree/w1_fan_overlay.dts`

The overlay claims portA.1 for the one-wire bus master.  Fan PWM (portA.0),
tach (portA.2), and reset button (portA.3) are managed from userspace via
sysfs — no DTS node needed for those.

```
CONFIG_W1=y
CONFIG_W1_MASTER_GPIO=y
CONFIG_W1_SLAVE_THERM=y
```

Pinmux: the base DTS must not activate the altera_spi driver on SPIM0 or
those pads will be claimed before the GPIO driver can use them.  Disable
`spi0` in the base DTS or add a pinmux override to set those pads to GPIO mode.

---

## Pending software tasks

| # | File | What |
|---|------|------|
| 1 | `boot/devicetree/w1_fan_overlay.dts` | Fix comment: pin 27 → 29 (3V3), pin 31 → 12 (GND) |
| 2 | `hps/thermal.h` | Remove stale "default 433 = bank-B" comment; update to 461 / portA |
| 3 | `hps/thermal.h/.c` | Add `TACH_GPIO_NUM 463`; `thermal_tach_rpm()` — export GPIO 463 as input, count falling edges over 1 s window |
| 4 | `hps/thermal.h/.c` | Add `thermal_fan_state()` getter; fix `push_status()` to use it instead of threshold comparison |
| 5 | `hps/thermal.h/.c` | Add `RESET_BTN_GPIO_NUM 464`; export as input with poll on falling edge |
| 6 | `sw/odo-ui/odo_ui.c` | Poll GPIO 464; short press → restart miner, long press (≥ 3 s) → reboot |
| 7 | `hps/Makefile` | Remove `thermal.c http_status.c` from `MINER_SRCS` until `miner.c` actually calls them |
| 8 | `services/S90odod` | ~~Add `mkdir -p /run/odod` before starting miner~~ — **DONE** (already present in S90odod line 23) |
| 9 | `sw/odo-webd/odo_webd.c` | Expose tach RPM and reset button state in `/status.json` |

---

## Branch to merge first

`claude/18b20-fan-gpio-setup-r4bm1f` contains `thermal.h/c`, `http_status.h/c`,
`miner_daemon.c`, `w1_fan_overlay.dts`, and `hps/Makefile` changes.
Review findings are in the session notes.  Items 1–5 above address the open
bugs in that branch before merge.
