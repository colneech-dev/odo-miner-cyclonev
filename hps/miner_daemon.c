/*
 * miner_daemon.c - Standalone OdoCrypt FPGA miner daemon for Cyclone V SoC
 *
 * This daemon runs on the HPS under Linux, opens /dev/mem, maps the
 * lightweight HPS-to-FPGA bridge register window, programs the FPGA job
 * registers, and submits found nonces to a Stratum pool.
 */

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "stratum.h"
#include "job.h"
#include "odocrypt_header.h"
#include "hps_regs.h"

static volatile sig_atomic_t g_running = 1;
static volatile uint32_t *g_regs = NULL;
static int g_memfd = -1;

static job_t g_current_job;
static bool  g_job_loaded = false;

static void install_signal_handlers(void);
static void on_signal(int sig);
static int  fpga_map(void);
static void fpga_unmap(void);
static inline uint32_t mmio_rd(uint32_t off);
static inline void     mmio_wr(uint32_t off, uint32_t val);
static void fpga_stop(void);
static void fpga_start(void);
static int  fpga_load_job(const job_t *job);
static int  fpga_check_found(uint32_t *nonce_out);
static int  stage_new_job(stratum_ctx_t *ctx);

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr,
                "usage: %s <pool_host> <pool_port> <user.worker> [password]\n",
                argv[0]);
        return 2;
    }

    const char *host = argv[1];
    const char *port = argv[2];
    const char *user = argv[3];
    const char *pass = (argc > 4) ? argv[4] : "x";

    install_signal_handlers();

    if (fpga_map() != 0) {
        return 1;
    }

    fpga_stop();
    fprintf(stderr, "[init] FPGA mapped and cores stopped\n");

    stratum_ctx_t ctx;
    if (stratum_init(&ctx, host, port, user, pass) != 0) {
        fprintf(stderr, "[init] failed to initialize Stratum context\n");
        fpga_unmap();
        return 1;
    }

    while (g_running) {
        if (stratum_connect(&ctx) != 0) {
            fprintf(stderr, "[net] connection failed, retrying in 5s\n");
            sleep(5);
            continue;
        }

        fprintf(stderr, "[net] connected to %s:%s as %s\n", host, port, user);

        while (g_running) {
            if (stratum_poll(&ctx, 100) < 0) {
                fprintf(stderr, "[net] connection lost, reconnecting\n");
                break;
            }

            if (stage_new_job(&ctx) > 0) {
                if (fpga_load_job(&g_current_job) == 0) {
                    fpga_start();
                    fprintf(stderr, "[fpga] started job %s epoch=%u\n",
                            g_current_job.job_id,
                            g_current_job.epoch);
                } else {
                    fprintf(stderr, "[fpga] failed to load new job\n");
                }
            }

            if (g_job_loaded) {
                uint32_t nonce;
                if (fpga_check_found(&nonce)) {
                    fprintf(stderr, "[fpga] found nonce=0x%08x\n", nonce);
                    if (stratum_submit_share(&ctx, &g_current_job, nonce) != 0) {
                        fprintf(stderr, "[share] submit failed\n");
                    }
                }
            }
        }

        stratum_disconnect(&ctx);
    }

    fprintf(stderr, "[exit] stopping FPGA and cleaning up\n");
    fpga_stop();
    stratum_destroy(&ctx);
    fpga_unmap();
    return 0;
}

static void install_signal_handlers(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
}

static void on_signal(int sig)
{
    (void)sig;
    g_running = 0;
}

static int fpga_map(void)
{
    g_memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_memfd < 0) {
        fprintf(stderr, "[fpga] open(/dev/mem) failed: %s\n", strerror(errno));
        return -1;
    }

    void *addr = mmap(NULL, FPGA_SPAN, PROT_READ | PROT_WRITE,
                      MAP_SHARED, g_memfd, (off_t)FPGA_BASE);
    if (addr == MAP_FAILED) {
        fprintf(stderr, "[fpga] mmap failed: %s\n", strerror(errno));
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
        g_regs = NULL;
    }
    if (g_memfd >= 0) {
        close(g_memfd);
        g_memfd = -1;
    }
}

static inline uint32_t mmio_rd(uint32_t off)
{
    return g_regs[off >> 2];
}

static inline void mmio_wr(uint32_t off, uint32_t val)
{
    g_regs[off >> 2] = val;
}

static void fpga_stop(void)
{
    mmio_wr(REG_CONTROL, CTRL_RESET);
    mmio_wr(REG_CONTROL, 0);
    g_job_loaded = false;
}

static void fpga_start(void)
{
    /* Clear any previously latched found state before starting a new search. */
    mmio_wr(REG_CONTROL, CTRL_CLEAR_FOUND);
    mmio_wr(REG_CONTROL, CTRL_ENABLE | CTRL_START);
}

static int fpga_load_job(const job_t *job)
{
    uint8_t header[JOB_HEADER_BYTES];
    job_t job_copy;

    if (!job)
        return -1;

    memcpy(&job_copy, job, sizeof(job_copy));
    fpga_stop();

    if (job_target_from_nbits(&job_copy) != 0) {
        fprintf(stderr, "[fpga] invalid nbits in job %s\n", job_copy.job_id);
        return -1;
    }

    if (odocrypt_build_header(&job_copy, header) != 0) {
        fprintf(stderr, "[fpga] failed to build header\n");
        return -1;
    }

    for (int i = 0; i < JOB_HEADER_BYTES / 4; ++i) {
        uint32_t word = (uint32_t)header[i * 4 + 0] |
                        ((uint32_t)header[i * 4 + 1] << 8) |
                        ((uint32_t)header[i * 4 + 2] << 16) |
                        ((uint32_t)header[i * 4 + 3] << 24);
        mmio_wr(REG_HEADER_BASE + (uint32_t)(i * 4), word);
    }

    for (int i = 0; i < 8; ++i) {
        uint32_t word = (uint32_t)job->target[i * 4 + 0] |
                        ((uint32_t)job->target[i * 4 + 1] << 8) |
                        ((uint32_t)job->target[i * 4 + 2] << 16) |
                        ((uint32_t)job->target[i * 4 + 3] << 24);
        mmio_wr(REG_TARGET_BASE + (uint32_t)(i * 4), word);
    }

    mmio_wr(REG_EPOCH, job->epoch);
    mmio_wr(REG_NONCE_START, job->nonce_start);
    mmio_wr(REG_NONCE_END, job->nonce_end);
    g_job_loaded = true;
    return 0;
}

static int fpga_check_found(uint32_t *nonce_out)
{
    if (!nonce_out)
        return 0;

    uint32_t status = mmio_rd(REG_STATUS);
    if ((status & STAT_FOUND) == 0)
        return 0;

    *nonce_out = mmio_rd(REG_NONCE_FOUND);
    mmio_wr(REG_CONTROL, CTRL_CLEAR_FOUND);
    return 1;
}

static int stage_new_job(stratum_ctx_t *ctx)
{
    job_t job;
    if (!ctx)
        return -1;

    if (!stratum_get_job(ctx, &job))
        return 0;

    if (job_target_from_nbits(&job) != 0) {
        fprintf(stderr, "[job] invalid difficulty encoding for job %s\n", job.job_id);
        return -1;
    }

    memcpy(&g_current_job, &job, sizeof(job));
    g_job_loaded = false;
    fprintf(stderr, "[job] new job id=%s epoch=%u\n",
            g_current_job.job_id,
            g_current_job.epoch);
    return 1;
}
