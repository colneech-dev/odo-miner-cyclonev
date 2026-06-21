/*
 * thermal.h - DS18B20 one-wire temperature sensor + GPIO fan/tach control
 *
 * Driven through the `pio_thermal` Avalon-MM PIO peripheral (Qsys,
 * hdl/qsys/add_pio_thermal.tcl) on the J10 "GPIO_1" header — FPGA-fabric
 * I/O, accessed directly via /dev/mem mmap (hps_regs.h-style), NOT Linux
 * GPIO sysfs or a kernel one-wire driver.
 *
 * This replaces an earlier J12 (real HPS dedicated pins) implementation
 * that used /sys/class/gpio + the kernel w1-gpio driver. That approach was
 * abandoned: those HPS balls also require U-Boot SPL IOCSR scan-chain
 * configuration (separate from the pin-mux selector), which is an opaque
 * ~20,000-bit chain with no per-pin structure and isn't safely
 * hand-patchable for this board. Moving the harness to J10's FPGA-fabric
 * pins sidesteps SPL pin-mux/IOCSR entirely — same mechanism this project
 * already uses for the display (pio_lcd/pio_in/pio_led).
 *
 * pio_thermal is a 3-bit Bidirectional altera_avalon_pio instance at
 * LWH2F offset 0x1500. Register layout (standard Avalon PIO core):
 *   offset 0x0 = data      (per-bit read/write)
 *   offset 0x4 = direction (per-bit: 1=output, 0=input)
 * Bit assignment:
 *   bit0 = DS18B20 one-wire data (direction toggled dynamically by the
 *          bit-banged protocol below)
 *   bit1 = fan tach, open-collector (direction fixed input)
 *   bit2 = reset button (direction fixed input; hardware-allocated only,
 *          software handling deferred)
 *
 * Fan speed is NOT driven through pio_thermal anymore -- it's a separate
 * pwm_fan Avalon-MM peripheral (hdl/src/pwm_fan.v) at LWH2F offset 0x1600,
 * a single 8-bit DUTY register (0=off, 255=full speed) driving a ~26.9 kHz
 * PWM carrier. Same physical pin pio_thermal's old fan bit used to own.
 *
 * J10 pin 35 -> THERMAL_BIT_DATA, pin 36 -> pwm_fan DUTY,
 * pin 37 -> THERMAL_BIT_TACH, pin 38 -> THERMAL_BIT_RESET (FPGA balls
 * AF18/AF20/AG15/AE20 -- see docs/FAN_SENSOR_WIRING.md).
 *
 * One-wire is software bit-banged from userspace (no kernel w1 driver
 * involved): reset/presence pulse, skip-ROM (single-drop bus), Convert T,
 * ~750 ms conversion wait, Read Scratchpad + CRC-8. thermal_read_c() blocks
 * for the conversion time, so it must only ever be called from the
 * background thermal thread (hps/miner_pipe.c), never the hot mining loop.
 */

#ifndef THERMAL_H
#define THERMAL_H

/* pio_thermal bit assignment within the 3-bit data/direction registers */
#define THERMAL_BIT_DATA    0   /* DS18B20 one-wire (bidirectional) */
#define THERMAL_BIT_TACH    1   /* fan tach, open-collector (input) */
#define THERMAL_BIT_RESET   2   /* reset button (input, unused for now) */

/* Fan speed ramp: 0% below THERMAL_FAN_ON_C, linear THERMAL_FAN_MIN_PCT..100
 * between THERMAL_FAN_ON_C and THERMAL_FAN_MAX_C, then held at 100%. Once
 * running, only drops back to 0% below THERMAL_FAN_OFF_C (hysteresis gap
 * prevents chatter right at the threshold). */
#define THERMAL_FAN_ON_C     50
#define THERMAL_FAN_OFF_C    45
#define THERMAL_FAN_MAX_C    65
#define THERMAL_FAN_MIN_PCT  30

/*
 * thermal_init - map the pio_thermal register block and set fixed pin
 * directions (fan=output, tach/reset=input, one-wire starts released).
 * Returns 0 on success, -1 if /dev/mem open or mmap fails.
 */
int  thermal_init(void);

/*
 * thermal_read_c - run a full DS18B20 conversion cycle and read the
 * temperature into *temp_c (°C). Blocks for ~750 ms (conversion time) —
 * only call from the background thermal thread.
 * Returns 0 on success, -1 on no presence pulse or CRC failure.
 */
int  thermal_read_c(int *temp_c);

/* thermal_fan_set_pct - command fan speed as a duty-cycle percentage
 * (0-100). 0 = off. Clamped to [0,100]. */
void thermal_fan_set_pct(int pct);

/*
 * thermal_fan_update - apply the speed ramp from the latest reading: 0%
 * below THERMAL_FAN_ON_C, linear ramp up to 100% at THERMAL_FAN_MAX_C, and
 * (once running) held on until temp drops below THERMAL_FAN_OFF_C.
 * Call this after every successful thermal_read_c().
 */
void thermal_fan_update(int temp_c);

/* thermal_fan_state - current commanded fan speed, 0-100 (%). */
int  thermal_fan_state(void);

/*
 * thermal_tach_rpm - sample the tach bit for window_ms and return RPM.
 * Blocks the calling thread for window_ms. Fan tach pulses twice per
 * revolution: RPM = (falling edges / 2) * 60000 / window_ms.
 * Returns -1 if pio_thermal isn't mapped.
 */
int  thermal_tach_rpm(int window_ms);

/* thermal_shutdown - turn the fan off and unmap the register block. */
void thermal_shutdown(void);

#endif /* THERMAL_H */
