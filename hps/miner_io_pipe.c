/*
 * miner_io_pipe.c — FPGA MMIO bridge for the PIPELINED OdoCrypt miner.
 *
 * Reuses the generic LWH2F mmap (miner_io_open/close + reg_rd/reg_wr from
 * hps_regs.h); the pipelined miner sits at the same bridge base (offset 0).
 * Register offsets come from hps_regs_pipe.h. See miner_io_pipe.h for the API.
 */

#define _POSIX_C_SOURCE 200809L

#include "miner_io_pipe.h"
#include "hps_regs.h"        /* miner_io_t, reg_rd/reg_wr, FPGA_BASE, MINER_SPAN */
#include "hps_regs_pipe.h"   /* REG_PIPE_*, PIPE_* bit fields */

#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>

/* Self-contained LWH2F mmap (no dependency on the FSM miner_io.c). The
 * pipelined miner sits at the same bridge base (FPGA_BASE, offset 0). */
static miner_io_t g_pio = { 0 };

int miner_io_pipe_init(void)
{
    g_pio.fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_pio.fd < 0) {
        fprintf(stderr, "miner_io_pipe_init: open(/dev/mem): %s\n", strerror(errno));
        return -1;
    }
    g_pio.map_base = mmap(NULL, MINER_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED,
                          g_pio.fd, (off_t)FPGA_BASE);
    if (g_pio.map_base == MAP_FAILED) {
        fprintf(stderr, "miner_io_pipe_init: mmap: %s\n", strerror(errno));
        close(g_pio.fd);
        g_pio.fd = -1;
        g_pio.map_base = NULL;
        return -1;
    }
    g_pio.regs = (volatile uint8_t *)g_pio.map_base;
    return 0;
}

void miner_io_pipe_shutdown(void)
{
    if (g_pio.map_base && g_pio.map_base != MAP_FAILED)
        munmap(g_pio.map_base, MINER_SPAN);
    if (g_pio.fd >= 0)
        close(g_pio.fd);
    g_pio.map_base = NULL;
    g_pio.fd = -1;
    g_pio.regs = NULL;
}

uint32_t miner_io_pipe_seed(void)
{
    return reg_rd(&g_pio, REG_PIPE_SEED);
}

uint32_t miner_io_pipe_version(void)
{
    return reg_rd(&g_pio, REG_PIPE_VERSION);
}

static inline uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

int miner_io_pipe_dispatch(const uint8_t header[80], const uint8_t target[32])
{
    if (g_pio.regs == NULL) return -1;

    /* 19 header words = bytes 0..75 (bytes 76..79 are swept as the nonce). */
    for (int i = 0; i < REG_PIPE_HEADER_WORDS; i++)
        reg_wr(&g_pio, REG_PIPE_HEADER_BASE + 4u * (uint32_t)i, le32(header + 4 * i));

    /* 8 target words (little-endian uint256, same order as cmp_256 / share_target). */
    for (int i = 0; i < REG_PIPE_TARGET_WORDS; i++)
        reg_wr(&g_pio, REG_PIPE_TARGET_BASE + 4u * (uint32_t)i, le32(target + 4 * i));

    /* Snapshot header+target into the 150 MHz domain (also arms the wrapper's
     * settle window, which drains stale old-header pipeline results). */
    reg_wr(&g_pio, REG_PIPE_COMMIT, 1u);
    return 0;
}

int miner_io_pipe_poll(uint32_t *out_nonce)
{
    if (g_pio.regs == NULL) return -1;
    if (!(reg_rd(&g_pio, REG_PIPE_FSTATUS) & PIPE_FSTAT_VALID))
        return 1;                                   /* nothing pending */
    uint32_t n = reg_rd(&g_pio, REG_PIPE_FNONCE);   /* read consumes the entry */
    if (out_nonce) *out_nonce = n;
    return 0;
}

int miner_io_pipe_wait(int timeout_ms)
{
    if (g_pio.regs == NULL) return -1;
    /* A pending nonce means no need to wait at all. */
    if (reg_rd(&g_pio, REG_PIPE_FSTATUS) & PIPE_FSTAT_VALID)
        return 0;
    /* The /dev/mem path has no interrupt: nap a bounded amount, then let the
     * caller poll. Cap the nap at 5 ms (the daemon's historical poll cadence)
     * so found-nonce latency stays low, and never sleep "forever". */
    unsigned ms = (timeout_ms < 0 || timeout_ms > 5) ? 5u : (unsigned)timeout_ms;
    struct timespec ts = { .tv_sec  = ms / 1000,
                           .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
    return 1;   /* always "timeout" — there is no IRQ to wake on */
}

const char *miner_io_pipe_backend(void) { return "devmem"; }
