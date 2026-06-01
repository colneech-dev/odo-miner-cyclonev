/* hps/miner_io.c
 * Compact UIO-backed miner I/O for odo-miner-cyclonev.
 * Single-file combined header+implementation for quick integration.
 *
 * Note: This is a concise implementation using polling (no IRQs) to keep it short.
 * Adjust register offsets and ACK behavior to match register-map.md in the repo.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <errno.h>
#include <time.h>
#include <inttypes.h>

/* Public API */
int miner_io_init(const char *uio_dev);
int miner_io_dispatch_range(const uint8_t *header, size_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count);
int miner_io_poll_result(uint32_t *out_nonce, uint8_t out_digest[32], uint32_t timeout_ms);
void miner_io_shutdown(void);

/* Defaults and register map (adjust if needed) */
#define DEFAULT_UIO_DEV "/dev/uio0"
#define MMIO_MAP_SIZE 0x4000
#define REG_CONTROL     0x00
#define REG_NONCE_START 0x04
#define REG_NONCE_COUNT 0x08
#define REG_STATUS      0x0C
#define REG_RESULT_NONCE 0x10
#define REG_RESULT_DIGEST 0x20
#define REG_HEADER_BASE 0x80

#define CMD_DISPATCH 1
#define STAT_RESULT_READY 0x1

static int g_fd = -1;
static volatile uint8_t *g_mmio = NULL;
static size_t g_map_size = 0;

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

int miner_io_init(const char *uio_dev) {
    if (!uio_dev) uio_dev = DEFAULT_UIO_DEV;
    g_fd = open(uio_dev, O_RDWR | O_CLOEXEC);
    if (g_fd < 0) {
        perror("open uio");
        return -errno;
    }
    g_map_size = MMIO_MAP_SIZE;
    void *m = mmap(NULL, g_map_size, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, 0);
    if (m == MAP_FAILED) {
        perror("mmap");
        close(g_fd); g_fd = -1;
        return -errno;
    }
    g_mmio = (volatile uint8_t *)m;
    return 0;
}

int miner_io_dispatch_range(const uint8_t *header, size_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count) {
    if (!g_mmio) return -ENODEV;
    if (!header || header_len == 0) return -EINVAL;
    if (header_len > 256) header_len = 256;
    if (REG_HEADER_BASE + header_len > g_map_size) return -EINVAL;
    memcpy((void *)(g_mmio + REG_HEADER_BASE), header, header_len);
    __sync_synchronize();
    mmio_write32(REG_NONCE_START, nonce_start);
    mmio_write32(REG_NONCE_COUNT, nonce_count);
    mmio_write32(REG_CONTROL, CMD_DISPATCH);
    return 0;
}

int miner_io_poll_result(uint32_t *out_nonce, uint8_t out_digest[32], uint32_t timeout_ms) {
    if (!g_mmio) return -ENODEV;
    if (!out_nonce || !out_digest) return -EINVAL;
    const uint32_t poll_ms = 5;
    uint32_t waited = 0;
    while (1) {
        uint32_t s = mmio_read32(REG_STATUS);
        if (s & STAT_RESULT_READY) {
            uint32_t nonce = mmio_read32(REG_RESULT_NONCE);
            memcpy(out_digest, (const void *)(g_mmio + REG_RESULT_DIGEST), 32);
            *out_nonce = nonce;
            /* clear result-ready if needed: write 1 to STATUS (adapt if hardware differs) */
            mmio_write32(REG_STATUS, STAT_RESULT_READY);
            return 0;
        }
        if (timeout_ms != UINT32_MAX && waited >= timeout_ms) return ETIMEDOUT;
        usleep(poll_ms * 1000);
        waited += poll_ms;
    }
}

void miner_io_shutdown(void) {
    if (g_mmio) munmap((void *)g_mmio, g_map_size);
    g_mmio = NULL;
    if (g_fd >= 0) close(g_fd);
    g_fd = -1;
}
