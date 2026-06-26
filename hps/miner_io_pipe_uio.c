/*
 * miner_io_pipe_uio.c — UIO backend for the PIPELINED OdoCrypt miner.
 *
 * Drop-in replacement for miner_io_pipe.c: implements the exact same
 * miner_io_pipe.h API, but reaches the miner register block through a UIO
 * device (/dev/uioN) instead of /dev/mem. Two wins over the /dev/mem path:
 *
 *   1. Non-root. /dev/mem exposes ALL physical memory and needs root; a UIO
 *      device exposes only the miner's ~4 KiB register window and is gated by
 *      a normal udev rule (KERNEL=="uio0", GROUP=="miner", MODE="0660").
 *   2. Interrupt-driven completion. miner_io_pipe_wait() blocks on the
 *      wrapper's found_valid interrupt (f2h_irq0 line 3, added in WS1) instead
 *      of polling FSTATUS on a fixed cadence — zero latency, zero busy-poll.
 *
 * This supersedes the older hps/miner_io_uio.c, which targeted the retired FSM
 * register map (hps_regs.h), was missing API functions (would not link), and
 * whose IRQ path never re-armed the interrupt (so it silently degraded to 5 ms
 * polling after the first IRQ — see docs/review-action-plan.md H3/H4).
 *
 * Prerequisites (WS2, not yet on the board):
 *   - kernel CONFIG_UIO + CONFIG_UIO_PDRV_GENIRQ
 *   - a devicetree node: compatible = "generic-uio", reg = the miner LW-bridge
 *     window, interrupts = the f2h_irq0 line wired to odo_0.irq (GIC 75).
 *   - the udev rule above + a non-root `miner` user.
 *
 * Register contract: hps_regs_pipe.h (identical offsets to the /dev/mem path).
 * Override the device node with the ODOD_UIO_DEV env var (default /dev/uio0).
 */

#define _POSIX_C_SOURCE 200809L

#include "miner_io_pipe.h"
#include "hps_regs_pipe.h"   /* REG_PIPE_*, PIPE_* bit fields, PIPE_MINER_SPAN */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <sys/mman.h>

#define DEFAULT_UIO_DEV  "/dev/uio0"

/* ------------------------------------------------------------------- state */
static int               g_fd   = -1;
static volatile uint8_t *g_regs = NULL;

/* ----------------------------------------------------------- reg accessors */
static inline void reg_wr(uint32_t off, uint32_t val)
{
    *((volatile uint32_t *)(g_regs + off)) = val;
    __sync_synchronize();
}
static inline uint32_t reg_rd(uint32_t off)
{
    __sync_synchronize();
    return *((volatile uint32_t *)(g_regs + off));
}

/* (Re)enable UIO interrupt delivery. uio_pdrv_genirq masks the IRQ in its
 * kernel handler on each event; userspace re-arms by writing a 1 to the device
 * fd before waiting again. This is the step the old miner_io_uio.c omitted —
 * without it, poll() never fires after the first interrupt. Writing 1 when the
 * IRQ is already unmasked is a no-op in the driver, so it is safe to call every
 * wait. Returns 0 on success, -1 on error. */
static int uio_irq_enable(void)
{
    uint32_t one = 1;
    if (g_fd < 0) return -1;
    return (write(g_fd, &one, sizeof(one)) == (ssize_t)sizeof(one)) ? 0 : -1;
}

/* ------------------------------------------------------------------- API */
int miner_io_pipe_init(void)
{
    const char *dev = getenv("ODOD_UIO_DEV");
    if (!dev || !*dev) dev = DEFAULT_UIO_DEV;

    g_fd = open(dev, O_RDWR | O_CLOEXEC);
    if (g_fd < 0) {
        fprintf(stderr, "miner_io_pipe_uio: open(%s): %s\n", dev, strerror(errno));
        return -1;
    }

    /* UIO memory region 0 is at mmap offset 0. */
    void *m = mmap(NULL, PIPE_MINER_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, 0);
    if (m == MAP_FAILED) {
        fprintf(stderr, "miner_io_pipe_uio: mmap: %s\n", strerror(errno));
        close(g_fd);
        g_fd = -1;
        return -1;
    }
    g_regs = (volatile uint8_t *)m;

    /* Best-effort arm. If the DTS wired no interrupt, the write/poll simply
     * never wakes and miner_io_pipe_wait() falls back to its timeout — the
     * daemon still works, just polled. */
    uio_irq_enable();
    return 0;
}

void miner_io_pipe_shutdown(void)
{
    if (g_regs)    { munmap((void *)g_regs, PIPE_MINER_SPAN); g_regs = NULL; }
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
}

uint32_t miner_io_pipe_seed(void)    { return g_regs ? reg_rd(REG_PIPE_SEED)    : 0; }
uint32_t miner_io_pipe_version(void) { return g_regs ? reg_rd(REG_PIPE_VERSION) : 0; }

static inline uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

int miner_io_pipe_dispatch(const uint8_t header[80], const uint8_t target[32])
{
    if (g_regs == NULL) return -1;

    /* 19 header words = bytes 0..75 (bytes 76..79 are swept as the nonce). */
    for (int i = 0; i < REG_PIPE_HEADER_WORDS; i++)
        reg_wr(REG_PIPE_HEADER_BASE + 4u * (uint32_t)i, le32(header + 4 * i));

    /* 8 target words (little-endian uint256, same order as share_target). */
    for (int i = 0; i < REG_PIPE_TARGET_WORDS; i++)
        reg_wr(REG_PIPE_TARGET_BASE + 4u * (uint32_t)i, le32(target + 4 * i));

    /* Snapshot header+target into the 150 MHz domain (arms the settle window). */
    reg_wr(REG_PIPE_COMMIT, 1u);
    return 0;
}

int miner_io_pipe_poll(uint32_t *out_nonce)
{
    if (g_regs == NULL) return -1;
    if (!(reg_rd(REG_PIPE_FSTATUS) & PIPE_FSTAT_VALID))
        return 1;                                   /* nothing pending */
    uint32_t n = reg_rd(REG_PIPE_FNONCE);           /* read consumes the entry */
    if (out_nonce) *out_nonce = n;
    return 0;
}

int miner_io_pipe_wait(int timeout_ms)
{
    if (g_regs == NULL || g_fd < 0) return -1;

    /* Fast path: a nonce is already waiting — don't sleep. */
    if (reg_rd(REG_PIPE_FSTATUS) & PIPE_FSTAT_VALID)
        return 0;

    /* Re-arm the interrupt before blocking. */
    if (uio_irq_enable() < 0)
        return -1;

    /* Re-check after the unmask to close the lost-wakeup window: found_valid
     * may have asserted between the FSTATUS read above and the re-arm, in which
     * case the level is already high and we must not block on it. */
    if (reg_rd(REG_PIPE_FSTATUS) & PIPE_FSTAT_VALID)
        return 0;

    /* Bound the wait: a negative timeout is capped (NOT infinite) so a missing
     * or stuck IRQ degrades to polling instead of hanging (scope risk #3). */
    int wait_ms = (timeout_ms < 0) ? 1000 : timeout_ms;
    struct pollfd pfd = { .fd = g_fd, .events = POLLIN };
    int rc = poll(&pfd, 1, wait_ms);
    if (rc < 0)
        return (errno == EINTR) ? 1 : -1;   /* signal: let the caller re-poll */
    if (rc == 0)
        return 1;                           /* timeout — caller drains defensively */

    /* Consume the interrupt event (the 4-byte UIO event count). */
    uint32_t count;
    if (read(g_fd, &count, sizeof(count)) != (ssize_t)sizeof(count))
        return -1;
    return 0;                               /* woken — a nonce is likely pending */
}

const char *miner_io_pipe_backend(void) { return "uio"; }
