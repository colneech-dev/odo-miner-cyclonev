/*
 * miner_io.c — FPGA MMIO bridge via /dev/mem (LWH2F bridge)
 *
 * Implements the miner_io.h API using the HPS-to-FPGA Lightweight bridge
 * at the Cyclone V SoC physical address 0xFF200000.  No kernel driver
 * required; runs as root or with appropriate /dev/mem permissions.
 *
 * Register map: see hps_regs.h and docs/register-map.md.
 * All offsets, bit masks, and field names come from hps_regs.h — do not
 * hardcode register addresses here.
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

/* -----------------------------------------------------------------------
 * Module state
 * ---------------------------------------------------------------------- */
static miner_io_t g_io = { .fd = -1, .map_base = NULL, .regs = NULL };

/* -----------------------------------------------------------------------
 * miner_io_open / miner_io_close  (declared in hps_regs.h)
 *
 * These open /dev/mem and mmap the LWH2F bridge window.  They are used by
 * miner_daemon.c and fpga_smoke_test.c via the miner_io_t handle, and also
 * called by miner_io_init() for the global singleton above.
 * ---------------------------------------------------------------------- */
int miner_io_open(miner_io_t *io)
{
    if (!io) return -1;

    io->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (io->fd < 0) {
        fprintf(stderr, "miner_io_open: open(/dev/mem): %s\n", strerror(errno));
        return -1;
    }

    /* mmap the LWH2F window at FPGA_BASE (page-aligned by construction) */
    io->map_base = mmap(NULL, MINER_SPAN,
                        PROT_READ | PROT_WRITE, MAP_SHARED,
                        io->fd, (off_t)FPGA_BASE);
    if (io->map_base == MAP_FAILED) {
        fprintf(stderr, "miner_io_open: mmap: %s\n", strerror(errno));
        close(io->fd);
        io->fd       = -1;
        io->map_base = NULL;
        return -1;
    }

    io->regs = (volatile uint8_t *)io->map_base;
    return 0;
}

void miner_io_close(miner_io_t *io)
{
    if (!io) return;
    if (io->map_base && io->map_base != MAP_FAILED) {
        munmap(io->map_base, MINER_SPAN);
        io->map_base = NULL;
    }
    if (io->fd >= 0) {
        close(io->fd);
        io->fd = -1;
    }
    io->regs = NULL;
}

/* -----------------------------------------------------------------------
 * Helpers
 * ---------------------------------------------------------------------- */
static inline void io_wr(uint32_t off, uint32_t val)
{
    reg_wr(&g_io, off, val);
}
static inline uint32_t io_rd(uint32_t off)
{
    return reg_rd(&g_io, off);
}

/* Millisecond sleep helper */
static void sleep_ms(unsigned ms)
{
    struct timespec ts = { .tv_sec = ms / 1000,
                           .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* -----------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- */

int miner_io_init(const char *dev)
{
    /* dev is ignored for /dev/mem; the bridge base is fixed by the SoC. */
    (void)dev;
    return miner_io_open(&g_io);
}

void miner_io_shutdown(void)
{
    miner_io_close(&g_io);
}

/*
 * miner_io_load_epoch — generate OdoCrypt tables and stream to FPGA.
 *
 * Generates epoch tables from epoch_key using the same LCG as the network,
 * streams 5964 × 32-bit words to REG_EPOCH_WR_DATA, then commits.
 * Blocks until tables_valid is set in STATUS (or returns -ETIMEDOUT).
 *
 * Call this once per epoch change before dispatching any jobs.
 * Stop the core first (miner_io_stop) and restart after (miner_io_start).
 */
int miner_io_load_epoch(uint32_t epoch_key)
{
    odo_epoch_state_t st;
    odo_epoch_generate(&st, epoch_key);

    /* Write the epoch key to the epoch register (used by RTL for info) */
    io_wr(REG_EPOCH, epoch_key);

    /* Stream 5964 words to the FPGA */
    int rc = odo_fpga_load_epoch(&st, &g_io);
    if (rc != 0)
        return rc;

    /* Commit: activates the loading buffer as the active table set */
    io_wr(REG_EPOCH_COMMIT, 1);

    /* Poll STATUS.TABLES_VALID — must be set before we can start hashing */
    for (int tries = 0; tries < 200; tries++) {
        if (io_rd(REG_STATUS) & STAT_TABLES_VALID)
            return 0;
        sleep_ms(1);
    }
    fprintf(stderr, "miner_io: timed out waiting for TABLES_VALID after epoch load\n");
    return -ETIMEDOUT;
}

/*
 * miner_io_dispatch_job — write a complete job to the FPGA and start hashing.
 *
 * header     : 80-byte block header; nonce field (bytes 76-79) should be zero,
 *              the FPGA core sweeps it internally.
 * header_len : must be 80 (ODO_HEADER_LEN).
 * target     : 32-byte big-endian difficulty target, or NULL to use all-zeros
 *              (accepts every hash — useful for testing).
 * nonce_start: first nonce to try.
 * nonce_count: number of nonces to sweep (nonce_end = nonce_start + nonce_count - 1).
 */
int miner_io_dispatch_job(const uint8_t *header, size_t header_len,
                          const uint8_t *target,
                          uint32_t nonce_start, uint32_t nonce_count)
{
    if (!g_io.regs) return -ENODEV;
    if (!header || header_len != REG_HEADER_WORDS * 4) return -EINVAL;

    /* Refuse to clobber an unread result: the caller must consume the FOUND
     * nonce first (miner_io_check_result), otherwise the share is lost. */
    if (io_rd(REG_STATUS) & STAT_FOUND)
        return -EAGAIN;

    /* Stop any running operation and clear the found latch */
    io_wr(REG_CONTROL, CTRL_RESET);
    io_wr(REG_CONTROL, CTRL_CLEAR_FOUND);
    io_wr(REG_CONTROL, 0);

    /* Write 20 header words (80 bytes, little-endian) */
    for (uint32_t i = 0; i < REG_HEADER_WORDS; i++) {
        uint32_t w = (uint32_t)header[i*4 + 0]
                   | ((uint32_t)header[i*4 + 1] <<  8)
                   | ((uint32_t)header[i*4 + 2] << 16)
                   | ((uint32_t)header[i*4 + 3] << 24);
        io_wr(REG_HEADER_BASE + i * 4, w);
    }

    /* Write 8 target words. The target is a little-endian uint256 (byte 0 =
     * LSB, as produced by job_target_from_nbits / diff_to_target). TARGET[i]
     * holds bytes 4i..4i+3 as an LE word, so target_256 in the RTL ends up
     * with byte 31 as its most-significant byte — matching the byte order of
     * the Keccak hash it is compared against. */
    for (uint32_t i = 0; i < REG_TARGET_WORDS; i++) {
        uint32_t w = 0;
        if (target) {
            w = (uint32_t)target[i*4 + 0]
              | ((uint32_t)target[i*4 + 1] <<  8)
              | ((uint32_t)target[i*4 + 2] << 16)
              | ((uint32_t)target[i*4 + 3] << 24);
        }
        io_wr(REG_TARGET_BASE + i * 4, w);
    }

    /* Nonce range (inclusive end) */
    uint32_t nonce_end = nonce_start + (nonce_count > 0 ? nonce_count - 1 : 0);
    io_wr(REG_NONCE_START, nonce_start);
    io_wr(REG_NONCE_END,   nonce_end);

    /* Start: enable core and assert start pulse */
    io_wr(REG_CONTROL, CTRL_ENABLE | CTRL_START);

    return 0;
}

/* Simplified dispatch that takes nonce_start + nonce_count (miner_io.h API) */
int miner_io_dispatch_range(const uint8_t *header, size_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count)
{
    return miner_io_dispatch_job(header, header_len, NULL, nonce_start, nonce_count);
}

/*
 * miner_io_check_result — non-blocking result check.
 *
 * Returns:
 *   0        — nonce found; out_nonce/out_hash filled, FOUND latch cleared.
 *   1        — core idle and no find: the nonce range is exhausted.
 *   EAGAIN   — core still hashing.
 *   -ENODEV  — bridge not mapped.
 *
 * FOUND is checked before BUSY so a result latched just as the core goes
 * idle is never missed.
 */
int miner_io_check_result(uint32_t *out_nonce, uint8_t out_hash[32])
{
    if (!g_io.regs) return -ENODEV;
    if (!out_nonce) return -EINVAL;

    uint32_t status = io_rd(REG_STATUS);

    if (status & STAT_FOUND) {
        *out_nonce = io_rd(REG_NONCE_FOUND);

        /* Read 8 × 32-bit hash words from REG_HASH_BASE */
        if (out_hash) {
            for (uint32_t i = 0; i < REG_HASH_WORDS; i++) {
                uint32_t w = io_rd(REG_HASH_BASE + i * 4);
                out_hash[i*4 + 0] = (uint8_t)(w);
                out_hash[i*4 + 1] = (uint8_t)(w >>  8);
                out_hash[i*4 + 2] = (uint8_t)(w >> 16);
                out_hash[i*4 + 3] = (uint8_t)(w >> 24);
            }
        }

        /* Clear found latch for next use */
        io_wr(REG_CONTROL, CTRL_CLEAR_FOUND);
        io_wr(REG_CONTROL, 0);
        return 0;
    }

    if (!(status & STAT_BUSY))
        return 1;   /* range exhausted, nothing found */

    return EAGAIN;
}

/*
 * miner_io_poll_result — wait for the FPGA to finish the dispatched range.
 *
 * Returns:
 *   0          — valid nonce found; out_nonce and out_hash (32 bytes) filled.
 *   1          — range exhausted without a find.
 *   ETIMEDOUT  — core still busy after timeout_ms milliseconds.
 *   -ENODEV    — bridge not mapped.
 */
int miner_io_poll_result(uint32_t *out_nonce, uint8_t out_hash[32],
                         uint32_t timeout_ms)
{
    if (!g_io.regs)         return -ENODEV;
    if (!out_nonce)         return -EINVAL;

    const uint32_t poll_interval_ms = 5;
    uint32_t elapsed = 0;

    while (1) {
        int rc = miner_io_check_result(out_nonce, out_hash);
        if (rc != EAGAIN)
            return rc;

        if (timeout_ms != UINT32_MAX && elapsed >= timeout_ms)
            return ETIMEDOUT;

        sleep_ms(poll_interval_ms);
        elapsed += poll_interval_ms;
    }
}

/* Stop the core (stop hashing, leave registers intact) */
void miner_io_stop(void)
{
    if (g_io.regs)
        io_wr(REG_CONTROL, CTRL_RESET);
}

/* Assert start after stop, reusing the registers already programmed */
void miner_io_start(void)
{
    if (g_io.regs)
        io_wr(REG_CONTROL, CTRL_ENABLE | CTRL_START);
}

/* Read STATUS register */
uint32_t miner_io_status(void)
{
    return g_io.regs ? io_rd(REG_STATUS) : 0;
}

/* Read the performance counters (see miner_io.h) */
int miner_io_read_perf(uint64_t *hashes, uint32_t *shares, uint32_t *uptime_ticks)
{
    if (!g_io.regs) return -ENODEV;

    if (hashes) {
        /* Read hi twice around lo to catch a carry between the two reads */
        uint32_t hi1 = io_rd(REG_PERF_HASHES_HI);
        uint32_t lo  = io_rd(REG_PERF_HASHES_LO);
        uint32_t hi2 = io_rd(REG_PERF_HASHES_HI);
        if (hi1 != hi2)
            lo = io_rd(REG_PERF_HASHES_LO);
        *hashes = ((uint64_t)hi2 << 32) | lo;
    }
    if (shares)
        *shares = io_rd(REG_PERF_SHARES);
    if (uptime_ticks)
        *uptime_ticks = io_rd(REG_PERF_UPTIME);
    return 0;
}
