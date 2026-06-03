/*
 * miner_io_uio.c — FPGA MMIO bridge via UIO kernel driver (alternative to /dev/mem)
 *
 * Implements the same miner_io.h API as miner_io.c but accesses the FPGA
 * through a UIO device (/dev/uio0 by default).  UIO allows non-root access
 * (via udev rules) and supports hardware interrupt notification instead of
 * busy-polling.
 *
 * To use this implementation instead of miner_io.c, change the Makefile to
 * substitute miner_io_uio.c for miner_io.c in the relevant targets.
 *
 * Prerequisites:
 *   1. A UIO kernel driver bound to the miner Avalon-MM peripheral.
 *   2. A udev rule granting the miner user read/write access to /dev/uio0.
 *      Example: KERNEL=="uio0", GROUP=="miner", MODE="0660"
 *   3. The UIO device mapping size must cover at least MINER_SPAN (0x1000).
 *
 * Register map: all offsets come from hps_regs.h — see docs/register-map.md.
 */

#define _POSIX_C_SOURCE 200809L

#include "miner_io.h"
#include "hps_regs.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <poll.h>

#define DEFAULT_UIO_DEV  "/dev/uio0"
#define UIO_MAP_SIZE     MINER_SPAN   /* 4 KiB — covers all miner registers */

/* -----------------------------------------------------------------------
 * Module state
 * ---------------------------------------------------------------------- */
static int              g_fd       = -1;
static volatile uint8_t *g_regs   = NULL;
static int              g_have_irq = 0;

/* -----------------------------------------------------------------------
 * Low-level helpers
 * ---------------------------------------------------------------------- */
static inline void reg_wr_u(uint32_t off, uint32_t val)
{
    if (!g_regs) return;
    *((volatile uint32_t *)(g_regs + off)) = val;
    __sync_synchronize();
}
static inline uint32_t reg_rd_u(uint32_t off)
{
    if (!g_regs) return 0;
    __sync_synchronize();
    return *((volatile uint32_t *)(g_regs + off));
}

static void sleep_ms(unsigned ms)
{
    struct timespec ts = { .tv_sec = ms / 1000,
                           .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* Try to receive one UIO interrupt with timeout_ms. Returns 0 on IRQ,
 * ETIMEDOUT on timeout, negative errno on error. */
static int uio_wait_irq(int timeout_ms)
{
    struct pollfd pfd = { .fd = g_fd, .events = POLLIN };
    int rc = poll(&pfd, 1, timeout_ms < 0 ? -1 : timeout_ms);
    if (rc == 0) return ETIMEDOUT;
    if (rc < 0)  return -errno;
    uint32_t count;
    if (read(g_fd, &count, sizeof(count)) != sizeof(count))
        return -errno;
    return 0;
}

/* -----------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- */

int miner_io_init(const char *dev)
{
    if (!dev) dev = DEFAULT_UIO_DEV;

    g_fd = open(dev, O_RDWR | O_CLOEXEC);
    if (g_fd < 0) {
        perror("miner_io_uio: open");
        return -errno;
    }

    void *m = mmap(NULL, UIO_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, 0);
    if (m == MAP_FAILED) {
        perror("miner_io_uio: mmap");
        close(g_fd); g_fd = -1;
        return -errno;
    }
    g_regs     = (volatile uint8_t *)m;
    g_have_irq = 1;  /* optimistic; fall back to polling on read errors */
    return 0;
}

void miner_io_shutdown(void)
{
    if (g_regs)  { munmap((void *)g_regs, UIO_MAP_SIZE); g_regs = NULL; }
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
}

int miner_io_load_epoch(uint32_t epoch_key)
{
    if (!g_regs) return -ENODEV;

    odo_epoch_state_t st;
    odo_epoch_generate(&st, epoch_key);

    reg_wr_u(REG_EPOCH, epoch_key);

    /* Stream 5964 words via the streaming write register */
#define WR(val) reg_wr_u(REG_EPOCH_WR_DATA, (uint32_t)(val))

    for (int si = 0; si < ODO_SMALL_SBOX_COUNT; si++)
        for (int e = 0; e < ODO_SMALL_SBOX_ENTRIES; e += 4)
            WR((uint32_t)st.sbox1[si][e+0] | ((uint32_t)st.sbox1[si][e+1] << 8)
               | ((uint32_t)st.sbox1[si][e+2] << 16) | ((uint32_t)st.sbox1[si][e+3] << 24));

    for (int si = 0; si < ODO_LARGE_SBOX_COUNT; si++)
        for (int e = 0; e < ODO_LARGE_SBOX_ENTRIES; e += 2)
            WR((uint32_t)st.sbox2[si][e+0] | ((uint32_t)st.sbox2[si][e+1] << 16));

    for (int p = 0; p < 2; p++) {
        for (int j = 0; j < ODO_PBOX_SUBROUNDS; j++)
            for (int k = 0; k < ODO_STATE_SIZE / 2; k++) {
                uint64_t m = st.pbox[p].mask[j][k];
                WR((uint32_t)m); WR((uint32_t)(m >> 32));
            }
        for (int j = 0; j < ODO_PBOX_SUBROUNDS - 1; j++)
            for (int k = 0; k < ODO_STATE_SIZE / 2; k++)
                WR((uint32_t)st.pbox[p].rotation[j][k]);
    }

    for (int r = 0; r < ODO_ROTATION_COUNT; r++)
        WR((uint32_t)st.rotations[r]);

    for (int r = 0; r < ODO_ROUNDS; r += 3) {
        uint32_t w = (uint32_t)st.round_key[r];
        if (r+1 < ODO_ROUNDS) w |= (uint32_t)st.round_key[r+1] << 10;
        if (r+2 < ODO_ROUNDS) w |= (uint32_t)st.round_key[r+2] << 20;
        WR(w);
    }
#undef WR

    reg_wr_u(REG_EPOCH_COMMIT, 1);

    for (int tries = 0; tries < 200; tries++) {
        if (reg_rd_u(REG_STATUS) & STAT_TABLES_VALID)
            return 0;
        sleep_ms(1);
    }
    fprintf(stderr, "miner_io_uio: timed out waiting for TABLES_VALID\n");
    return -ETIMEDOUT;
}

int miner_io_dispatch_job(const uint8_t *header, size_t header_len,
                          const uint8_t *target,
                          uint32_t nonce_start, uint32_t nonce_count)
{
    if (!g_regs) return -ENODEV;
    if (!header || header_len != REG_HEADER_WORDS * 4) return -EINVAL;

    reg_wr_u(REG_CONTROL, CTRL_RESET);
    reg_wr_u(REG_CONTROL, CTRL_CLEAR_FOUND);
    reg_wr_u(REG_CONTROL, 0);

    for (uint32_t i = 0; i < REG_HEADER_WORDS; i++) {
        uint32_t w = (uint32_t)header[i*4]
                   | ((uint32_t)header[i*4+1] <<  8)
                   | ((uint32_t)header[i*4+2] << 16)
                   | ((uint32_t)header[i*4+3] << 24);
        reg_wr_u(REG_HEADER_BASE + i*4, w);
    }

    for (uint32_t i = 0; i < REG_TARGET_WORDS; i++) {
        uint32_t w = target
            ? ((uint32_t)target[i*4] | ((uint32_t)target[i*4+1] << 8)
               | ((uint32_t)target[i*4+2] << 16) | ((uint32_t)target[i*4+3] << 24))
            : 0xFFFFFFFFu;
        reg_wr_u(REG_TARGET_BASE + i*4, w);
    }

    reg_wr_u(REG_NONCE_START, nonce_start);
    reg_wr_u(REG_NONCE_END,   nonce_start + (nonce_count > 0 ? nonce_count - 1 : 0));
    reg_wr_u(REG_CONTROL,     CTRL_ENABLE | CTRL_START);
    return 0;
}

int miner_io_dispatch_range(const uint8_t *header, size_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count)
{
    return miner_io_dispatch_job(header, header_len, NULL, nonce_start, nonce_count);
}

int miner_io_poll_result(uint32_t *out_nonce, uint8_t out_hash[32],
                         uint32_t timeout_ms)
{
    if (!g_regs || !out_nonce) return -ENODEV;

    const uint32_t poll_ms = 5;
    uint32_t elapsed = 0;

    while (1) {
        /* Try interrupt path first; fall back to polling on failure */
        if (g_have_irq && g_fd >= 0) {
            int rc = uio_wait_irq((int)poll_ms);
            if (rc == ETIMEDOUT || rc == -EAGAIN) {
                /* no interrupt — check status manually */
            } else if (rc < 0) {
                g_have_irq = 0;  /* disable IRQ path */
            }
        } else {
            sleep_ms(poll_ms);
        }

        if (reg_rd_u(REG_STATUS) & STAT_FOUND) {
            *out_nonce = reg_rd_u(REG_NONCE_FOUND);
            if (out_hash) {
                for (uint32_t i = 0; i < REG_HASH_WORDS; i++) {
                    uint32_t w = reg_rd_u(REG_HASH_BASE + i*4);
                    out_hash[i*4+0] = (uint8_t)(w);
                    out_hash[i*4+1] = (uint8_t)(w >> 8);
                    out_hash[i*4+2] = (uint8_t)(w >> 16);
                    out_hash[i*4+3] = (uint8_t)(w >> 24);
                }
            }
            reg_wr_u(REG_CONTROL, CTRL_CLEAR_FOUND);
            reg_wr_u(REG_CONTROL, 0);
            return 0;
        }

        elapsed += poll_ms;
        if (timeout_ms != UINT32_MAX && elapsed >= timeout_ms)
            return ETIMEDOUT;
    }
}

void miner_io_stop(void)   { if (g_regs) reg_wr_u(REG_CONTROL, CTRL_RESET); }
void miner_io_start(void)  { if (g_regs) reg_wr_u(REG_CONTROL, CTRL_ENABLE | CTRL_START); }
uint32_t miner_io_status(void) { return g_regs ? reg_rd_u(REG_STATUS) : 0; }
