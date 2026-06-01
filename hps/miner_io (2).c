/*
 * miner_io.c
 *
 * UIO-backed miner I/O for odo-miner-cyclonev.
 *
 * - Maps /dev/uioX region to access Avalon-MM registers
 * - Writes header + nonce range, issues dispatch command
 * - Waits for completion via UIO interrupt (if provided) or polls status
 *
 * Adjust register offsets/clear semantics to match your HDL / register-map.
 */

#define _POSIX_C_SOURCE 200809L
#include "miner_io.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <sys/poll.h>
#include <errno.h>
#include <time.h>

/* Defaults */
#define DEFAULT_UIO_DEV "/dev/uio0"
#define MMIO_MAP_SIZE 0x10000U /* 64 KiB mapping - adjust if needed */

/* Register offsets (assumed) */
#define REG_CONTROL        0x00
#define REG_NONCE_START    0x04
#define REG_NONCE_COUNT    0x08
#define REG_STATUS         0x0C
#define REG_RESULT_NONCE   0x10
#define REG_RESULT_DIGEST  0x20
#define REG_HEADER_BASE    0x80
#define REG_EPOCH_BASE     0xC0

/* Commands */
#define CMD_DISPATCH       1
#define CMD_LOAD_EPOCH     2

/* Status bits */
#define STAT_RESULT_READY  0x1
#define STAT_BUSY          0x2
#define STAT_FAULT         0x4

/* Header area max we will copy (safe upper bound) */
#define HEADER_MAX_BYTES 256

/* Internal state */
static int g_uio_fd = -1;
static volatile uint8_t *g_mmio = NULL;
static size_t g_map_size = 0;
static int g_have_irq = 0;

/* Helpers to read/write little-endian 32-bit regs */
static inline void mmio_write32(uint32_t off, uint32_t val) {
    if (!g_mmio) return;
    *((volatile uint32_t *)(g_mmio + off)) = val;
    __sync_synchronize();
}
static inline uint32_t mmio_read32(uint32_t off) {
    if (!g_mmio) return 0;
    uint32_t v = *((volatile uint32_t *)(g_mmio + off));
    __sync_synchronize();
    return v;
}

/* Write arbitrary bytes to mmio header area */
static int mmio_write_bytes(uint32_t off, const void *buf, size_t len) {
    if (!g_mmio) return -ENODEV;
    if (off + len > g_map_size) return -EINVAL;
    memcpy((void *)(g_mmio + off), buf, len);
    /* Ensure write-back before issuing command */
    __sync_synchronize();
    return 0;
}

/* Wait for status bit(s) with timeout (ms). Polling loop at 5ms intervals. */
static int wait_status_mask(uint32_t mask, uint32_t timeout_ms) {
    const uint32_t poll_interval_ms = 5;
    uint32_t waited = 0;
    while (1) {
        uint32_t s = mmio_read32(REG_STATUS);
        if (s & mask) return 0;
        if (timeout_ms != UINT32_MAX && waited >= timeout_ms) return ETIMEDOUT;
        usleep(poll_interval_ms * 1000);
        waited += poll_interval_ms;
    }
}

/* Public API */

int miner_io_init(const char *uio_dev) {
    if (!uio_dev) uio_dev = DEFAULT_UIO_DEV;

    /* Open UIO device */
    g_uio_fd = open(uio_dev, O_RDWR | O_CLOEXEC);
    if (g_uio_fd < 0) {
        perror("open uio device");
        return -errno;
    }

    /* Map MMIO region */
    g_map_size = MMIO_MAP_SIZE;
    void *map = mmap(NULL, g_map_size, PROT_READ | PROT_WRITE, MAP_SHARED, g_uio_fd, 0);
    if (map == MAP_FAILED) {
        perror("mmap uio");
        close(g_uio_fd);
        g_uio_fd = -1;
        return -errno;
    }
    g_mmio = (volatile uint8_t *)map;

    /* Check if device supports interrupts by attempting a non-blocking poll/read.
     * If reads on uio_fd block until interrupts, we will use read/poll for IRQs.
     * Heuristic: file is openable and mmap succeeded -> consider IRQ available.
     */
    /* We won't block here; we'll detect at poll time. */
    g_have_irq = 1; /* optimistic, fallback to polling on error */

    return 0;
}

int miner_io_dispatch_range(const uint8_t *header, size_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count) {
    if (!g_mmio) return -ENODEV;
    if (!header || header_len == 0) return -EINVAL;
    if (header_len > HEADER_MAX_BYTES) header_len = HEADER_MAX_BYTES;

    /* Copy header into device header area */
    int rc = mmio_write_bytes(REG_HEADER_BASE, header, header_len);
    if (rc) return rc;

    /* Write nonce start/count */
    mmio_write32(REG_NONCE_START, nonce_start);
    mmio_write32(REG_NONCE_COUNT, nonce_count);

    /* Issue dispatch command */
    mmio_write32(REG_CONTROL, CMD_DISPATCH);

    return 0;
}

/* Helper: try waiting via interrupt (read on uio fd). Returns:
 *   0 on IRQ received,
 *   >0 on no irq or timeout (we'll fall back to polling),
 *   <0 on error
 */
static int wait_for_irq_fd(int timeout_ms) {
    if (g_uio_fd < 0) return -ENODEV;
    struct pollfd pfd = { .fd = g_uio_fd, .events = POLLIN };
    int to = (timeout_ms == UINT32_MAX) ? -1 : (int)timeout_ms;
    int pr = poll(&pfd, 1, to);
    if (pr == 0) return ETIMEDOUT;
    if (pr < 0) return -errno;
    /* consume the IRQ counter by reading 4 bytes (uio interface) */
    uint32_t irq_count = 0;
    ssize_t r = read(g_uio_fd, &irq_count, sizeof(irq_count));
    if (r < 0) {
        /* Some UIO setups require reading from /dev/uioX to re-enable IRQs */
        return -errno;
    }
    (void)irq_count;
    return 0;
}

int miner_io_poll_result(uint32_t *out_nonce, uint8_t out_digest[32], uint32_t timeout_ms) {
    if (!g_mmio) return -ENODEV;
    if (!out_nonce || !out_digest) return -EINVAL;

    int rc = 0;

    /* First try interrupt wait if available */
    if (g_have_irq && g_uio_fd >= 0) {
        int irq_rc = wait_for_irq_fd(timeout_ms);
        if (irq_rc == 0) {
            /* An IRQ occurred; fall through to read status */
        } else if (irq_rc == ETIMEDOUT) {
            /* no irq in timeout period */
            return ETIMEDOUT;
        } else {
            /* disable IRQ path and fall back to polling */
            g_have_irq = 0;
        }
    }

    /* Poll status until RESULT_READY or timeout */
    const uint32_t poll_interval_ms = 5;
    uint32_t elapsed = 0;
    while (1) {
        uint32_t s = mmio_read32(REG_STATUS);
        if (s & STAT_RESULT_READY) {
            /* Read result */
            uint32_t nonce = mmio_read32(REG_RESULT_NONCE);
            /* Read 32-byte digest - copy 32 bytes starting at RESULT_DIGEST */
            memcpy(out_digest, (const void *)(g_mmio + REG_RESULT_DIGEST), 32);
            *out_nonce = nonce;

            /* Acknowledge/clear result-ready bit.
             * NOTE: many designs require writing a specific ACK value or clear-on-read.
             * This implementation writes the bit to STATUS to request clear; adapt if your
             * hardware expects a different sequence (e.g. write to CONTROL or separate ACK reg).
             */
            mmio_write32(REG_STATUS, STAT_RESULT_READY);

            return 0;
        }

        if (timeout_ms != UINT32_MAX && elapsed >= timeout_ms) {
            return ETIMEDOUT;
        }

        /* If interrupts are not available, sleep a bit */
        usleep(poll_interval_ms * 1000);
        elapsed += poll_interval_ms;
    }

    return rc;
}

void miner_io_shutdown(void) {
    if (g_mmio) {
        munmap((void *)g_mmio, g_map_size);
        g_mmio = NULL;
    }
    if (g_uio_fd >= 0) {
        close(g_uio_fd);
        g_uio_fd = -1;
    }
}