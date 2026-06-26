# Fan & Temperature Sensor Wiring — J10 ("GPIO_1" header, FPGA fabric)

Covers the DS18B20 one-wire temperature sensor, 4-wire PWM fan, and optional
reset button, all on the **J10** header.

> **Architecture history:** this feature was originally built against
> **J12** (the connector that mixes Arduino-shield signals with the genuine
> HPS dedicated pins `HPS_SPIM_MOSI/SS/CLK/MISO`), driven through Linux GPIO
> sysfs + the kernel `w1-gpio` driver. That path hit a hard wall: those HPS
> balls also need correct **IOCSR** scan-chain configuration (separate from
> the pin-mux selector) — an opaque ~20,000-bit chain with no per-pin
> structure, not safely hand-patchable without the original Quartus
> pin-assignment project for this board (see
> `reference_hps_pinmux_and_gpio` in project memory). The harness was moved
> to **J10** instead — wired entirely to FPGA fabric I/O (`GPIO_1_Dn`
> signals, no HPS pins involved at all) — and is now driven through two
> Qsys Avalon-MM peripherals, the same well-understood mechanism this
> project already uses for the display (`pio_lcd`/`pio_in`/`pio_led`). This
> sidesteps SPL pin-mux/IOCSR entirely.
>
> Fan speed control was then upgraded a second time, from a simple GPIO
> on/off bit to a real PWM generator (`hdl/src/pwm_fan.v`) for proportional
> speed ramping — see "4-wire PWM fan" below.

---

## J10 header power pins (same convention as J11/J12, user-verified by meter)

| J10 pin | Rail | Status |
|---------|------|--------|
| 11 | VIN (5 V) | Fan VCC |
| 29 | 3.3 V | DS18B20 VDD + top of pull-up resistors |
| 30 | GND | Shared ground |

---

## Complete J10 pin assignment

| J10 pin | Net | FPGA ball | Peripheral | Connected to |
|---------|-----|-----------|------------|--------------|
| 35 | `GPIO_1_D32` | AF18 | `pio_thermal` bit0 (`THERMAL_BIT_DATA`) | DS18B20 DATA |
| 36 | `GPIO_1_D33` | AF20 | `pwm_fan` DUTY output | Fan PWM (blue wire) |
| 37 | `GPIO_1_D34` | AG15 | `pio_thermal` bit1 (`THERMAL_BIT_TACH`) | Fan tach (yellow wire) |
| 38 | `GPIO_1_D35` | AE20 | `pio_thermal` bit2 (`THERMAL_BIT_RESET`) | Reset button (one side, deferred) |

`pio_thermal` is a 3-bit Bidirectional `altera_avalon_pio` at LWH2F offset
`0x1500`. `pwm_fan` is a separate single-register Avalon-MM peripheral
(`hdl/src/pwm_fan.v`) at LWH2F offset `0x1600` — see
`hdl/qsys/add_pio_thermal.tcl` and `hdl/qsys/add_pwm_fan.tcl` for the exact
Qsys wiring, and `hps/thermal.h`/`hps/thermal.c` for the register-level
driver. Both peripherals fall inside the same 4 KB page so the HPS driver
maps them with a single `mmap()` call.

---

## Passive components

```
Pin 29 (3.3V) ─┬─ 4.7 kΩ ──── Pin 35  (DS18B20 one-wire pull-up)
               ├─ 10 kΩ  ──── Pin 37  (fan tach pull-up)
               └─ 10 kΩ  ──── Pin 38  (reset button pull-up)

Pin 38 ── momentary switch ── Pin 30 (GND)   [reset button]
```

Pins 29, 35, 37, and 38 — check header row/column spacing on J10 before
bending resistor legs; this was not re-measured after the J12→J10 pin
renumbering (see Pending tasks).

---

## DS18B20 sensor (3-wire mode)

| DS18B20 pin | J10 pin |
|-------------|---------|
| VDD | 29 (3.3 V) |
| GND | 30 (GND) |
| DATA | 35 |

4.7 kΩ pull-up between DATA (pin 35) and VDD (pin 29). Driven by a
software-bit-banged one-wire protocol from userspace (`hps/thermal.c`):
reset/presence pulse, skip-ROM (single-drop bus), Convert T, ~750 ms
conversion wait, Read Scratchpad + CRC-8 (retried up to 5×, since the
conversion result sits stable in the scratchpad and a marginal bus bit only
needs a re-read, not a re-convert).

---

## 4-wire PWM fan

| Fan wire | J10 pin | Notes |
|----------|---------|-------|
| Red (VCC) | 11 (VIN/5 V) | |
| Black (GND) | 30 | Shared with DS18B20 GND |
| Blue (PWM) | 36 | Driven by `pwm_fan` (FPGA fabric), push-pull 3.3 V LVTTL, ~26.9 kHz carrier |
| Yellow (tach) | 37 | Open-collector; 10 kΩ pull-up to pin 29 |

`pwm_fan` (`hdl/src/pwm_fan.v`) is an 11-bit free-running counter clocked
off `clk_fab` (~55 MHz) compared against an 8-bit duty register, giving
55 MHz / 2048 ≈ **26.9 kHz** carrier — above the 21-28 kHz convention for
4-pin PC fans and above human hearing. Duty is commanded as a 0-255 register
value; the HPS driver exposes it as a 0-100% API
(`thermal_fan_set_pct()`/`thermal_fan_update()` in `hps/thermal.c`/`.h`).
0% is a genuine off (unlike the old GPIO on/off scheme, where 0 still left
the fan at its electrical minimum speed on this particular fan). Speed
ramps linearly from `THERMAL_FAN_MIN_PCT` (30%) at `THERMAL_FAN_ON_C`
(50°C) up to 100% at `THERMAL_FAN_MAX_C` (65°C); once running, the fan only
drops back to 0% below `THERMAL_FAN_OFF_C` (45°C), preserving a hysteresis
gap against chatter at the threshold.

Tach pulses twice per revolution; RPM = (falling edges / 2) × 60000 /
window_ms (`thermal_tach_rpm()`).

---

## Reset button

Wire a momentary normally-open push button between J10 pin 38 and pin 30
(GND). 10 kΩ pull-up from pin 38 to pin 29 (3.3 V) holds the line high at
rest; pressing the button pulls it to GND. Hardware-allocated
(`THERMAL_BIT_RESET`, `pio_thermal` bit2, direction fixed input) but
**software handling not implemented** — deferred, see Pending tasks.

---

## FPGA/Qsys/kernel notes

- **Qsys**: `hdl/qsys/add_pio_thermal.tcl` adds `pio_thermal`;
  `hdl/qsys/add_pwm_fan.tcl` adds `pwm_fan` and shrinks `pio_thermal` from
  4-bit to 3-bit (the fan bit moved off it). Both are small standalone
  incremental scripts run against the live `soc_system.qsys` — *not*
  `hdl/qsys/qsys_add_peripherals.tcl`, which is a documentation-only
  cumulative spec and is never re-run once a system exists.
- **soc_top.v / odo_miner.qsf**: `THERMAL_IO[2:0]` (balls AF18/AG15/AE20)
  and `FAN_PWM` (ball AF20), both `3.3-V LVTTL`.
- **No kernel/DTS involvement at all** — this is pure FPGA-fabric I/O
  accessed by the HPS via direct `/dev/mem` mmap of the LWH2F bridge, the
  same mechanism the display peripherals use. No `w1-gpio` driver, no
  `CONFIG_GPIO_SYSFS`, no DTS node, no U-Boot SPL pinmux patch — all of
  those J12-era kernel/SPL changes were reverted.

---

## Software/hardware task status

**Hardware-verified end-to-end on 2026-06-22** (board booted with the PWM
bitstream + binaries; watched the full thermal loop under live mining load):

| # | What | Status |
|---|------|--------|
| 1 | DS18B20 read over `pio_thermal` (one-wire bit-bang) | ✅ verified — real readings tracked load 34→49→45 °C (no 85/-127 error sentinels). CRC-retry in `thermal.c` handles intermittent one-wire noise; no bad readings observed this run. |
| 2 | Fan tach over `pio_thermal` | ✅ verified — read **2700 RPM** while the fan ran at 30% duty. |
| 3 | `pwm_fan` proportional speed control | ✅ verified — at 50 °C the daemon wrote `DUTY=0x4C` (76/255 ≈ 30% = `THERMAL_FAN_MIN_PCT`) to `0xFF201600` and the fan spun; off at 45 °C. Higher-duty points (toward `THERMAL_FAN_MAX_C` 65 °C) not yet exercised — idle-mining tops out ~50 °C. |
| 4 | UI: `fan_duty_pct` on touch UI + web dashboard | ✅ done; `status.json` carries `temp_c`/`fan_duty_pct`/`fan_rpm`. |
| 5 | Reset button polling (`pio_thermal` bit2) | ✅ **DONE 2026-06-24** — active-low input on J10 pin 36/AE20; `thermal.c` polls `pio_thermal` bit2 in the thermal thread; ~2 s hold → `reboot` syscall. |

Verified hysteresis: fan **ON at `THERMAL_FAN_ON_C` (50 °C)**, **OFF at
`THERMAL_FAN_OFF_C` (45 °C)**, no chatter. `THERMAL_FAN_MIN_PCT` = 30%,
ramping to full by `THERMAL_FAN_MAX_C` (65 °C).

All items complete. No remaining tasks for this subsystem.
