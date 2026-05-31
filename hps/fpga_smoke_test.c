#define _POSIX_C_SOURCE 199309L

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>

#include "hps_regs.h"

static volatile uint32_t *g_regs = NULL;
static int g_memfd = -1;

static int fpga_map(void)
{
    g_memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_memfd < 0) {
        fprintf(stderr, "[smoke] open(/dev/mem) failed: %s\n", strerror(errno));
        return -1;
    }

    void *addr = mmap(NULL, FPGA_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, g_memfd, (off_t)FPGA_BASE);
    if (addr == MAP_FAILED) {
        fprintf(stderr, "[smoke] mmap failed: %s\n", strerror(errno));
        close(g_memfd);
        g_memfd = -1;
        return -1;
    }

    g_regs = (volatile uint32_t *)addr;
    return 0;
}

static void fpga_unmap(void)
{
    if (g_regs && g_regs != (volatile uint32_t *)MAP_FAILED) {
        munmap((void *)g_regs, FPGA_SPAN);
    }
    if (g_memfd >= 0) {
        close(g_memfd);
    }
    g_regs = NULL;
    g_memfd = -1;
}


/*
 * Use distinct names for the local MMIO helpers to avoid colliding with the
 * `reg_rd`/`reg_wr` inline helpers defined in `hps_regs.h`.
 */
static inline uint32_t mmio_rd32(uint32_t off)
{
    return g_regs[off >> 2];
}

static inline void mmio_wr32(uint32_t off, uint32_t value)
{
    g_regs[off >> 2] = value;
}

static bool check_u32(const char *label, uint32_t expected, uint32_t actual)
{
    if (expected != actual) {
        fprintf(stderr, "[smoke] FAIL %s: expected 0x%08X, got 0x%08X\n", label, expected, actual);
        return false;
    }
    printf("[smoke] PASS %s = 0x%08X\n", label, actual);
    return true;
}

int main(void)
{
    if (fpga_map() != 0)
        return 1;

    printf("[smoke] mapped FPGA registers at 0x%08lX\n", (unsigned long)FPGA_BASE);

    mmio_wr32(REG_CONTROL, CTRL_RESET);
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 1000000 };
    nanosleep(&ts, NULL);
    mmio_wr32(REG_CONTROL, 0);

    mmio_wr32(REG_EPOCH, 0xDEADBEEF);
    mmio_wr32(REG_NONCE_START, 0x0000CAFE);
    mmio_wr32(REG_NONCE_END, 0x0000D000);

    for (uint32_t i = 0; i < REG_TARGET_WORDS; ++i) {
        mmio_wr32(REG_TARGET_BASE + (i * 4), 0x11110000u | i);
    }

    for (uint32_t i = 0; i < REG_HEADER_WORDS; ++i) {
        mmio_wr32(REG_HEADER_BASE + (i * 4), 0xA5A50000u | i);
    }

    bool ok = true;
    ok &= check_u32("EPOCH", 0xDEADBEEF, mmio_rd32(REG_EPOCH));
    ok &= check_u32("NONCE_START", 0x0000CAFE, mmio_rd32(REG_NONCE_START));
    ok &= check_u32("NONCE_END", 0x0000D000, mmio_rd32(REG_NONCE_END));

    for (uint32_t i = 0; i < REG_TARGET_WORDS; ++i) {
        char label[32];
        uint32_t expected = 0x11110000u | i;
        snprintf(label, sizeof(label), "TARGET[%u]", i);
        ok &= check_u32(label, expected, mmio_rd32(REG_TARGET_BASE + (i * 4)));
    }

    for (uint32_t i = 0; i < REG_HEADER_WORDS; ++i) {
        char label[32];
        uint32_t expected = 0xA5A50000u | i;
        snprintf(label, sizeof(label), "HEADER[%u]", i);
        ok &= check_u32(label, expected, mmio_rd32(REG_HEADER_BASE + (i * 4)));
    }

    uint32_t status = mmio_rd32(REG_STATUS);
    printf("[smoke] STATUS = 0x%08X\n", status);
    printf("[smoke] NONCE_FOUND = 0x%08X\n", mmio_rd32(REG_NONCE_FOUND));
    printf("[smoke] HASH[0] = 0x%08X\n", mmio_rd32(REG_HASH_BASE));
    printf("[smoke] PERF_HASHES_LO = 0x%08X\n", mmio_rd32(REG_PERF_HASHES_LO));

    if (!ok) {
        fprintf(stderr, "[smoke] register validation failed\n");
    } else {
        printf("[smoke] register validation succeeded\n");
    }

    fpga_unmap();
    return ok ? 0 : 1;
}
