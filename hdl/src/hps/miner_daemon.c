/*
 * miner_daemon.c — Standalone OdoCrypt FPGA Miner (Cyclone V SoC)
 * -----------------------------------------------------------------
 * Main control loop running on the HPS (ARM Linux). Responsibilities:
 *   1. Open /dev/mem and mmap the FPGA register window (Avalon-MM).
 *   2. Maintain a stratum connection (see stratum.c) for jobs/shares.
 *   3. On new job: build the 80-byte OdoCrypt header + target, program
 *      the FPGA core array, assert START.
 *   4. Poll the FOUND flag, read the winning nonce, submit the share.
 *   5. Handle difficulty changes, epoch (mutation) boundaries, clean
 *      shutdown, and reconnection.
 *
 * Build: see Makefile (cross-compiled with arm-linux-gnueabihf-gcc).
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <sys/mman.h>

#include "stratum.h"
#include "job.h"
#include "odocrypt_header.h"
#include "fpga_regs.h"   /* register offsets + FPGA_BASE/FPGA_SPAN */

/* ----- globals ----- */
static volatile sig_atomic_t g_running = 1;
static volatile uint32_t    *g_regs    = NULL;  /* mmap'd register window */
static int                   g_memfd   = -1;

/* current mining state */
static job_t   g_current_job;
static int     g_have_job   = 0;
static uint8_t g_target[32];
static uint32_t g_cur_epoch = 0xFFFFFFFFu;

/* ----- forward declarations ----- */
static void  on_signal(int sig);
static int   fpga_map(void);
static void  fpga_unmap(void);
static inline uint32_t reg_rd(uint32_t off);
static inline void     reg_wr(uint32_t off, uint32_t val);
static void  fpga_load_job(const job_t *job, const uint8_t target[32]);
static void  fpga_start(void);
static void  fpga_stop(void);
static int   fpga_check_found(uint32_t *nonce_out);

/* stratum callbacks */
static void  cb_new_job(const job_t *job, void *ctx);
static void  cb_set_difficulty(double diff, const uint8_t target[32], void *ctx);
static void  cb_share_result(int accepted, const char *reason, void *ctx);

/* ====================================================================
 * main
 * ==================================================================== */
int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr,
            "usage: %s <pool_host> <pool_port> <wallet[.worker]> [password]\n",
            argv[0]);
        return 2;
    }
    const char *host = argv[1];
    const char *port = argv[2];
    const char *user = argv[3];
    const char *pass = (argc > 4) ? argv[4] : "x";

    install_signal_handlers();

    /* --- map the FPGA register window --- */
    if (fpga_map() != 0) {
        fprintf(stderr, "fatal: could not map FPGA register window\n");
        return 1;
    }
    fpga_stop();   /* ensure cores are idle before we start */
    fprintf(stderr, "[init] FPGA mapped; core array idle\n");

    /* --- wire up stratum --- */
    stratum_t st;
    stratum_callbacks_t cbs = {
        .on_new_job        = cb_new_job,
        .on_set_difficulty = cb_set_difficulty,
        .on_share_result   = cb_share_result,
        .ctx               = NULL,
    };
    stratum_init(&st, &cbs);

    /* --- main supervision loop --- */
    while (g_running) {
        if (stratum_connect(&st, host, port) != 0) {
            fprintf(stderr, "[net] connect failed; retrying in 5s\n");
            sleep(5);
            continue;
        }
        if (stratum_subscribe(&st) != 0 ||
            stratum_authorize(&st, user, pass) != 0) {
            fprintf(stderr, "[net] subscribe/authorize failed; reconnecting\n");
            stratum_disconnect(&st);
            sleep(5);
            continue;
        }
        fprintf(stderr, "[net] connected to %s:%s as %s\n", host, port, user);

        /* inner work loop for this connection */
        while (g_running) {
            /* Service pool messages (fills callbacks). Short timeout keeps
             * the nonce poll responsive. */
            if (stratum_poll(&st, 50 /*ms*/) < 0) {
                fprintf(stderr, "[net] connection lost; reconnecting\n");
                break;
            }

            /* Apply staged job to the FPGA. */
            if (g_have_job) {
                g_have_job = 0;
                fpga_load_job(&g_current_job, g_target);
                fpga_start();
                fprintf(stderr, "[fpga] mining job %s (epoch %u)\n",
                        g_current_job.job_id, g_cur_epoch);
            }

            /* Check for a winning nonce. */
            uint32_t nonce;
            if (fpga_check_found(&nonce)) {
                fprintf(stderr, "[fpga] FOUND nonce=0x%08x\n", nonce);
                stratum_submit_share(&st, &g_current_job, nonce);
            }
        }
        stratum_disconnect(&st);
    }

    /* --- clean shutdown --- */
    fprintf(stderr, "\n[exit] stopping cores and releasing resources\n");
    fpga_stop();
    stratum_disconnect(&st);
    stratum_free(&st);
    fpga_unmap();
    return 0;
}

/* ====================================================================
 * Signal handling
 * ==================================================================== */
static void on_signal(int sig)
{
    (void)sig;
    /* Async-signal-safe: only flip the flag. The main loop notices it,
     * stops the cores, unmaps the FPGA, and disconnects gracefully. */
    g_running = 0;
}

static void install_signal_handlers(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;                 /* no SA_RESTART: interrupt blocking I/O */
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    /* Don't die if the pool socket breaks mid-write. */
    signal(SIGPIPE, SIG_IGN);
}

/* ====================================================================
 * FPGA memory-mapped I/O
 * ==================================================================== */
static int fpga_map(void)
{
    g_memfd = open("/dev/mem", O_RDWR | O_SYNC);
    if (g_memfd < 0) {
        fprintf(stderr, "fpga_map: open(/dev/mem) failed: %s\n", strerror(errno));
        return -1;
    }

    /* FPGA_BASE must be page-aligned for mmap; fpga_regs.h guarantees this
     * by pointing at the lightweight HPS-to-FPGA bridge window base. */
    void *p = mmap(NULL, FPGA_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED,
                   g_memfd, (off_t)FPGA_BASE);
    if (p == MAP_FAILED) {
        fprintf(stderr, "fpga_map: mmap failed: %s\n", strerror(errno));
        close(g_memfd);
        g_memfd = -1;
        return -1;
    }

    g_regs = (volatile uint32_t *)p;
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

/* Word-addressed accessors. Offsets in fpga_regs.h are byte offsets,
 * so divide by 4 to index a uint32_t array. */
static inline uint32_t reg_rd(uint32_t off)
{
    return g_regs[off >> 2];
}

static inline void reg_wr(uint32_t off, uint32_t val)
{
    g_regs[off >> 2] = val;
}

/* ====================================================================
 * FPGA job programming + control
 * ==================================================================== */
static void fpga_load_job(const job_t *job, const uint8_t target[32])
{
    uint8_t hdr[ODO_HEADER_LEN];   /* 80-byte block header, nonce field = 0 */

    /* Halt the cores before reprogramming work registers. */
    fpga_stop();

    /* Build the canonical OdoCrypt header from the stratum job. The nonce
     * field is left zero; the FPGA core array sweeps it internally. */
    odocrypt_build_header(job, hdr);

    /* Header is 80 bytes = 20 words. Stream them little-endian into the
     * header register file. */
    for (int i = 0; i < ODO_HEADER_LEN / 4; i++) {
        uint32_t w = (uint32_t)hdr[i*4 + 0]
                   | ((uint32_t)hdr[i*4 + 1] << 8)
                   | ((uint32_t)hdr[i*4 + 2] << 16)
                   | ((uint32_t)hdr[i*4 + 3] << 24);
        reg_wr(REG_HEADER_BASE + (uint32_t)(i * 4), w);
    }

    /* 256-bit target = 8 words, most-significant first per difficulty_compare. */
    for (int i = 0; i < 8; i++) {
        uint32_t w = (uint32_t)target[i*4 + 0]
                   | ((uint32_t)target[i*4 + 1] << 8)
                   | ((uint32_t)target[i*4 + 2] << 16)
                   | ((uint32_t)target[i*4 + 3] << 24);
        reg_wr(REG_TARGET_BASE + (uint32_t)(i * 4), w);
    }

    /* Tell the round/mutation logic which OdoCrypt epoch this job belongs
     * to, so the S-box tweak constants match the network. */
    reg_wr(REG_EPOCH, job->epoch);
    g_cur_epoch = job->epoch;

    /* Latch the new work set atomically for all cores. */
    reg_wr(REG_CTRL, CTRL_LOAD);
}

static void fpga_start(void)
{
    reg_wr(REG_CTRL, CTRL_START);
}

static void fpga_stop(void)
{
    reg_wr(REG_CTRL, CTRL_STOP);
}

/* Returns 1 and fills *nonce_out when a core has found a qualifying hash,
 * 0 otherwise. Reading the nonce register clears the FOUND latch. */
static int fpga_check_found(uint32_t *nonce_out)
{
    uint32_t status = reg_rd(REG_STATUS);
    if (status & STATUS_FOUND) {
        *nonce_out = reg_rd(REG_NONCE_OUT);   /* read clears FOUND */
        return 1;
    }
    return 0;
}

/* ====================================================================
 * Stratum callbacks
 * ==================================================================== */
/* A new job arrived. Copy it into the staging slot; the main loop picks
 * it up and reprograms the FPGA. The clean_jobs flag (inside job_t) tells
 * us whether to abandon current work immediately. */
static void cb_new_job(const job_t *job, void *ctx)
{
    (void)ctx;
    memcpy(&g_current_job, job, sizeof(g_current_job));
    g_have_job = 1;
    fprintf(stderr, "[job] new work id=%s epoch=%u clean=%d\n",
            job->job_id, job->epoch, job->clean_jobs);
}

/* Pool changed our share difficulty. Cache the expanded 256-bit target so
 * the next job load (or an immediate retarget) uses it. */
static void cb_set_difficulty(double diff, const uint8_t target[32], void *ctx)
{
    (void)ctx;
    memcpy(g_target, target, sizeof(g_target));
    fprintf(stderr, "[diff] share difficulty set to %.6g\n", diff);
}

/* Result of a submitted share. */
static void cb_share_result(int accepted, const char *reason, void *ctx)
{
    (void)ctx;
    if (accepted)
        fprintf(stderr, "[share] ACCEPTED\n");
    else
        fprintf(stderr, "[share] REJECTED: %s\n", reason ? reason : "(no reason)");
}
