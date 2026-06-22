/*
 * thermal.c - DS18B20 one-wire temperature sensor + GPIO fan/tach control
 *
 * Driven through the pio_thermal Avalon-MM PIO peripheral via direct
 * /dev/mem mmap. See thermal.h for the register layout and bit assignment.
 */

#define _POSIX_C_SOURCE 200809L

#include "thermal.h"
#include "hps_regs.h"   /* LWHPS2FPGA_BASE */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/mman.h>

/* pio_thermal / pwm_fan byte offsets within the LWH2F bridge — MUST match
 * the baseAddress values in hdl/qsys/add_pio_thermal.tcl and
 * hdl/qsys/add_pwm_fan.tcl. Both fall within the same 4 KB page, so one
 * mmap covers both register blocks. */
#define THERMAL_PIO_OFFSET   0x1500UL
#define PWM_FAN_OFFSET       0x1600UL
#define PAGE_SIZE_           0x1000UL
#define THERMAL_MAP_BASE     (THERMAL_PIO_OFFSET & ~(PAGE_SIZE_ - 1))
#define THERMAL_REG_INPAGE   (THERMAL_PIO_OFFSET - THERMAL_MAP_BASE)
#define PWM_FAN_REG_INPAGE   (PWM_FAN_OFFSET - THERMAL_MAP_BASE)

/* altera_avalon_pio register offsets (Bidirectional core) */
#define PIO_REG_DATA   0x0
#define PIO_REG_DIR    0x4

/* pwm_fan register offset (hdl/src/pwm_fan.v) */
#define PWM_REG_DUTY   0x0

static struct {
    int                fd;
    void              *map_base;
    volatile uint8_t  *regs;       /* pio_thermal block base */
    volatile uint8_t  *pwm_regs;   /* pwm_fan block base */
} g_th = { .fd = -1, .map_base = NULL, .regs = NULL, .pwm_regs = NULL };

static int  g_fan_pct = 0;

/* ---------- register helpers ------------------------------------------ */

static inline uint32_t pio_rd(uint32_t off)
{
    return *(volatile uint32_t *)(g_th.regs + off);
}

static inline void pio_wr(uint32_t off, uint32_t val)
{
    *(volatile uint32_t *)(g_th.regs + off) = val;
}

static void pio_set_dir_bit(int bit, int as_output)
{
    uint32_t dir = pio_rd(PIO_REG_DIR);
    if (as_output)
        dir |= (1u << bit);
    else
        dir &= ~(1u << bit);
    pio_wr(PIO_REG_DIR, dir);
}

static void pio_write_bit(int bit, int val)
{
    uint32_t data = pio_rd(PIO_REG_DATA);
    if (val)
        data |= (1u << bit);
    else
        data &= ~(1u << bit);
    pio_wr(PIO_REG_DATA, data);
}

static int pio_read_bit(int bit)
{
    return (pio_rd(PIO_REG_DATA) >> bit) & 1u;
}

/* nanosleep() has 50-100+ us of scheduler jitter on a non-RT kernel --
 * fine for the coarse reset pulse, but it corrupts the individual
 * 2-60 us one-wire bit slots. Busy-wait those on CLOCK_MONOTONIC instead. */
static void delay_us(unsigned us)
{
    if (us >= 2000) {
        struct timespec ts;
        ts.tv_sec  = us / 1000000U;
        ts.tv_nsec = (long)(us % 1000000U) * 1000L;
        nanosleep(&ts, NULL);
        return;
    }

    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed_us = (now.tv_sec - start.tv_sec) * 1000000L +
                           (now.tv_nsec - start.tv_nsec) / 1000L;
        if (elapsed_us >= (long)us)
            break;
    }
}

/* ---------- one-wire bit-bang primitives -------------------------------
 * Open-drain emulation: "low" = direction=output, data=0; "release" =
 * direction=input, relying on the external 4.7 kOhm pull-up to bring the
 * line high. Never drive the line high directly.
 * ---------------------------------------------------------------------- */

static void ow_low(void)
{
    pio_set_dir_bit(THERMAL_BIT_DATA, 1);
    pio_write_bit(THERMAL_BIT_DATA, 0);
}

static void ow_release(void)
{
    pio_set_dir_bit(THERMAL_BIT_DATA, 0);
}

/* Reset pulse + presence detect. Returns 1 if a device responded. */
static int ow_reset(void)
{
    ow_low();
    delay_us(480);
    ow_release();
    delay_us(70);
    int presence = !pio_read_bit(THERMAL_BIT_DATA);
    delay_us(410);
    return presence;
}

static void ow_write_bit(int b)
{
    if (b) {
        ow_low();
        delay_us(6);
        ow_release();
        delay_us(64);
    } else {
        ow_low();
        delay_us(60);
        ow_release();
        delay_us(10);
    }
}

static int ow_read_bit(void)
{
    ow_low();
    delay_us(2);
    ow_release();
    delay_us(10);
    int b = pio_read_bit(THERMAL_BIT_DATA);
    delay_us(53);
    return b;
}

static void ow_write_byte(uint8_t v)
{
    for (int i = 0; i < 8; i++) {
        ow_write_bit(v & 1);
        v >>= 1;
    }
}

static uint8_t ow_read_byte(void)
{
    uint8_t v = 0;
    for (int i = 0; i < 8; i++)
        v |= (uint8_t)(ow_read_bit() << i);
    return v;
}

/* CRC-8/MAXIM, as used by the DS18B20 scratchpad. */
static uint8_t ow_crc8(const uint8_t *data, int len)
{
    uint8_t crc = 0;
    for (int i = 0; i < len; i++) {
        uint8_t b = data[i];
        for (int j = 0; j < 8; j++) {
            uint8_t mix = (crc ^ b) & 0x01;
            crc >>= 1;
            if (mix)
                crc ^= 0x8C;
            b >>= 1;
        }
    }
    return crc;
}

/* ---------- public API -------------------------------------------------- */

int thermal_init(void)
{
    g_th.fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_th.fd < 0) {
        fprintf(stderr, "[thermal] open(/dev/mem): %s\n", strerror(errno));
        return -1;
    }

    g_th.map_base = mmap(NULL, PAGE_SIZE_, PROT_READ | PROT_WRITE, MAP_SHARED,
                          g_th.fd, (off_t)(LWHPS2FPGA_BASE + THERMAL_MAP_BASE));
    if (g_th.map_base == MAP_FAILED) {
        fprintf(stderr, "[thermal] mmap: %s\n", strerror(errno));
        close(g_th.fd);
        g_th.fd       = -1;
        g_th.map_base = NULL;
        return -1;
    }
    g_th.regs     = (volatile uint8_t *)g_th.map_base + THERMAL_REG_INPAGE;
    g_th.pwm_regs = (volatile uint8_t *)g_th.map_base + PWM_FAN_REG_INPAGE;

    /* Fixed directions: tach/reset=input, one-wire starts released (input)
     * until a transaction drives it. */
    pio_wr(PIO_REG_DIR, 0);
    thermal_fan_set_pct(0);

    fprintf(stderr, "[thermal] pio_thermal mapped at LWH2F+0x%lx, pwm_fan at LWH2F+0x%lx\n",
            (unsigned long)THERMAL_PIO_OFFSET, (unsigned long)PWM_FAN_OFFSET);
    return 0;
}

int thermal_read_c(int *temp_c)
{
    if (!temp_c || !g_th.regs)
        return -1;

    if (!ow_reset()) {
        fprintf(stderr, "[thermal] no presence pulse (convert reset)\n");
        return -1;
    }
    ow_write_byte(0xCC); /* Skip ROM (single-drop bus) */
    ow_write_byte(0x44); /* Convert T */
    ow_release();

    /* Worst-case 12-bit conversion time */
    delay_us(750000);

    /* The conversion result sits stable in the scratchpad, so a marginal
     * bus bit that flips a CRC on one read can simply be re-read a few
     * times without re-converting. */
    uint8_t scratch[9];
    int ok = 0;
    for (int attempt = 0; attempt < 5 && !ok; attempt++) {
        if (!ow_reset()) {
            fprintf(stderr, "[thermal] no presence pulse (read reset)\n");
            return -1;
        }
        ow_write_byte(0xCC); /* Skip ROM */
        ow_write_byte(0xBE); /* Read Scratchpad */

        for (int i = 0; i < 9; i++)
            scratch[i] = ow_read_byte();

        if (ow_crc8(scratch, 8) == scratch[8]) {
            ok = 1;
        } else {
            fprintf(stderr, "[thermal] CRC mismatch (attempt %d): %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
                    attempt, scratch[0], scratch[1], scratch[2], scratch[3], scratch[4],
                    scratch[5], scratch[6], scratch[7], scratch[8]);
        }
    }
    if (!ok)
        return -1;

    int16_t raw = (int16_t)((scratch[1] << 8) | scratch[0]);
    *temp_c = raw / 16;
    return 0;
}

void thermal_fan_set_pct(int pct)
{
    if (!g_th.pwm_regs)
        return;
    if (pct < 0)   pct = 0;
    if (pct > 100) pct = 100;
    uint8_t duty = (uint8_t)(pct * 255 / 100);
    *(volatile uint32_t *)(g_th.pwm_regs + PWM_REG_DUTY) = duty;
    g_fan_pct = pct;
}

/* Linear ramp between THERMAL_FAN_ON_C/MIN_PCT and THERMAL_FAN_MAX_C/100%. */
static int fan_ramp_pct(int temp_c)
{
    if (temp_c <= THERMAL_FAN_ON_C)
        return THERMAL_FAN_MIN_PCT;
    if (temp_c >= THERMAL_FAN_MAX_C)
        return 100;
    int span_c   = THERMAL_FAN_MAX_C - THERMAL_FAN_ON_C;
    int span_pct = 100 - THERMAL_FAN_MIN_PCT;
    return THERMAL_FAN_MIN_PCT + (temp_c - THERMAL_FAN_ON_C) * span_pct / span_c;
}

void thermal_fan_update(int temp_c)
{
    if (g_fan_pct == 0) {
        if (temp_c >= THERMAL_FAN_ON_C)
            thermal_fan_set_pct(fan_ramp_pct(temp_c));
    } else {
        if (temp_c <= THERMAL_FAN_OFF_C)
            thermal_fan_set_pct(0);
        else
            thermal_fan_set_pct(fan_ramp_pct(temp_c));
    }
}

int thermal_fan_state(void)
{
    return g_fan_pct;
}

int thermal_tach_rpm(int window_ms)
{
    if (!g_th.regs || window_ms <= 0)
        return -1;

    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);

    int last  = 1; /* open-collector + pull-up: idle high */
    int edges = 0;

    for (;;) {
        int v = pio_read_bit(THERMAL_BIT_TACH);
        if (last == 1 && v == 0)
            edges++;
        last = v;

        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed_ms = (now.tv_sec - start.tv_sec) * 1000 +
                          (now.tv_nsec - start.tv_nsec) / 1000000;
        if (elapsed_ms >= window_ms)
            break;
        delay_us(1000); /* 1 kHz sample rate; fan tach tops out a few hundred Hz */
    }

    /* two pulses per revolution */
    return (edges / 2) * 60000 / window_ms;
}

void thermal_shutdown(void)
{
    thermal_fan_set_pct(0);

    if (g_th.map_base && g_th.map_base != MAP_FAILED) {
        munmap(g_th.map_base, PAGE_SIZE_);
        g_th.map_base = NULL;
    }
    if (g_th.fd >= 0) {
        close(g_th.fd);
        g_th.fd = -1;
    }
    g_th.regs = NULL;
}
