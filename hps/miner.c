/*
 * miner.c — High-level mining control loop for odo-miner-cyclonev HPS.
 *
 * Responsibilities:
 *   1. Open the FPGA bridge via miner_io_init().
 *   2. Load the initial epoch tables via miner_io_load_epoch().
 *   3. Connect to the Stratum pool via stratum_ctx_t / stratum_connect().
 *   4. On each new job: dispatch the header + nonce range to the FPGA.
 *   5. Poll for a found nonce and submit the share.
 *   6. Reload epoch tables when the epoch changes.
 *   7. Restart cleanly on network disconnects.
 *
 * Build:
 *   make odo-miner
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>
#include <inttypes.h>

#include "stratum.h"
#include "miner_io.h"
#include "job.h"
#include "epoch_watcher.h"

/* -----------------------------------------------------------------------
 * Configuration (from environment variables or defaults)
 * ---------------------------------------------------------------------- */
static uint32_t get_env_u32(const char *var, uint32_t def)
{
    const char *val = getenv(var);
    return val ? (uint32_t)strtoul(val, NULL, 10) : def;
}

/* Read at startup; can be overridden via environment variables:
 *   ODOMIN_NONCE_RANGE=2000000
 *   ODOMIN_POLL_TIMEOUT_MS=3000
 *   ODOMIN_EPOCH_POLL_S=5
 *   ODOMIN_HEARTBEAT_S=60
 */
#define NONCE_RANGE_SIZE      1000000u   /* nonces dispatched per batch */
#define POLL_TIMEOUT_MS       2000u      /* max wait for an FPGA result */
#define EPOCH_POLL_INTERVAL_S 10u        /* how often to check epoch */
#define HEARTBEAT_INTERVAL_S  30         /* status log interval */

/* -----------------------------------------------------------------------
 * Globals
 * ---------------------------------------------------------------------- */
static volatile sig_atomic_t g_terminate   = 0;
static uint32_t              g_cur_epoch   = UINT32_MAX;
static pthread_mutex_t       g_epoch_lock  = PTHREAD_MUTEX_INITIALIZER;

/* -----------------------------------------------------------------------
 * Logging
 * ---------------------------------------------------------------------- */
static void log_msg(FILE *f, const char *tag, const char *fmt, va_list ap)
{
    fprintf(f, "[%s] ", tag);
    vfprintf(f, fmt, ap);
    fputc('\n', f);
    fflush(f);
}
static void log_info(const char *fmt, ...)
    { va_list ap; va_start(ap, fmt); log_msg(stdout, "INFO",  fmt, ap); va_end(ap); }
static void log_warn(const char *fmt, ...)
    { va_list ap; va_start(ap, fmt); log_msg(stderr, "WARN",  fmt, ap); va_end(ap); }
static void log_error(const char *fmt, ...)
    { va_list ap; va_start(ap, fmt); log_msg(stderr, "ERROR", fmt, ap); va_end(ap); }

/* -----------------------------------------------------------------------
 * Sleep helper
 * ---------------------------------------------------------------------- */
static void sleep_ms_local(unsigned ms)
{
    struct timespec ts = { .tv_sec = ms / 1000,
                           .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* -----------------------------------------------------------------------
 * Signal handling
 * ---------------------------------------------------------------------- */
static void handle_signal(int sig) { (void)sig; g_terminate = 1; }

/* -----------------------------------------------------------------------
 * Epoch getter for epoch_watcher (reads from stratum job / external source)
 * Returns the current epoch based on the job we last processed.
 * A more robust implementation would track block height from the pool.
 * ---------------------------------------------------------------------- */
static uint32_t epoch_getter(void *ctx)
{
    (void)ctx;
    pthread_mutex_lock(&g_epoch_lock);
    uint32_t e = g_cur_epoch;
    pthread_mutex_unlock(&g_epoch_lock);
    return e;
}

/* -----------------------------------------------------------------------
 * Target comparison: returns 1 if hash <= target (both big-endian, 32 B)
 * ---------------------------------------------------------------------- */
static int target_met(const uint8_t hash[32], const uint8_t target[32])
{
    for (int i = 0; i < 32; i++) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 1;  /* equal counts as met */
}

/* -----------------------------------------------------------------------
 * Nonce allocator — simple linear counter
 * ---------------------------------------------------------------------- */
typedef struct { uint32_t next; } nonce_alloc_t;

static void   nonce_init(nonce_alloc_t *a)              { a->next = 0; }
static uint32_t nonce_get(nonce_alloc_t *a, uint32_t *cnt)
{
    uint32_t s = a->next;
    *cnt = NONCE_RANGE_SIZE;
    uint32_t next = s + NONCE_RANGE_SIZE;
    if (next < s) {
        log_warn("nonce counter wrapped (searched 0x00000000–0x%08x, restarting)", s);
        a->next = 0;
    } else {
        a->next = next;
    }
    return s;
}

/* -----------------------------------------------------------------------
 * main
 * ---------------------------------------------------------------------- */
int main(int argc, char **argv)
{
    const char *pool_host = argc > 1 ? argv[1] : getenv("STRATUM_HOST");
    const char *pool_port = argc > 2 ? argv[2] : getenv("STRATUM_PORT");
    const char *worker    = argc > 3 ? argv[3] : getenv("STRATUM_WORKER");
    const char *password  = argc > 4 ? argv[4] : "x";

    if (!pool_host) pool_host = "127.0.0.1";
    if (!pool_port) pool_port = "3333";
    if (!worker)    worker    = "miner";

    /* Read tuning parameters from environment (optional) */
    uint32_t nonce_range_size      = get_env_u32("ODOMIN_NONCE_RANGE", NONCE_RANGE_SIZE);
    uint32_t poll_timeout_ms       = get_env_u32("ODOMIN_POLL_TIMEOUT_MS", POLL_TIMEOUT_MS);
    uint32_t epoch_poll_interval_s = get_env_u32("ODOMIN_EPOCH_POLL_S", EPOCH_POLL_INTERVAL_S);
    uint32_t heartbeat_interval_s  = get_env_u32("ODOMIN_HEARTBEAT_S", HEARTBEAT_INTERVAL_S);

    /* Signals */
    struct sigaction sa = {0};
    sa.sa_handler = handle_signal;
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    log_info("odo-miner starting (pool=%s:%s worker=%s)", pool_host, pool_port, worker);

    /* FPGA bridge */
    if (miner_io_init(NULL) != 0) {
        log_error("miner_io_init failed");
        return 1;
    }
    log_info("FPGA bridge opened");

    /* Epoch watcher — will load tables when epoch is known */
    log_info("configuration: nonce_range=%u poll_timeout_ms=%u epoch_poll_s=%u heartbeat_s=%u",
             nonce_range_size, poll_timeout_ms, epoch_poll_interval_s, heartbeat_interval_s);
    epoch_watcher_start(epoch_getter, NULL, epoch_poll_interval_s);

    /* Stratum context */
    stratum_ctx_t st;
    if (stratum_init(&st, pool_host, pool_port, worker, password) != 0) {
        log_error("stratum_init failed");
        return 1;
    }

    nonce_alloc_t alloc;
    nonce_init(&alloc);
    time_t last_hb = time(NULL);
    job_t  job;
    int    have_job = 0;

    while (!g_terminate) {
        /* Heartbeat */
        time_t now = time(NULL);
        if (now - last_hb >= heartbeat_interval_s) {
            log_info("heartbeat: epoch=%" PRIu32 " nonce_next=%" PRIu32,
                     g_cur_epoch, alloc.next);
            last_hb = now;
        }

        /* Connect / reconnect */
        if (stratum_connect(&st) != 0) {
            log_warn("stratum connect failed; retrying in 5 s");
            sleep(5);
            continue;
        }
        log_info("connected to %s:%s", pool_host, pool_port);
        have_job = 0;

        /* Inner work loop */
        while (!g_terminate) {
            int n = stratum_poll(&st, 100 /*ms*/);
            if (n < 0) {
                log_warn("stratum poll error; reconnecting");
                break;
            }

            /* Check for new job */
            job_t new_job;
            if (stratum_get_job(&st, &new_job)) {
                memcpy(&job, &new_job, sizeof(job));
                have_job = 1;
                nonce_init(&alloc);  /* reset nonce on clean job */
                log_info("new job id=%s epoch=%" PRIu32, job.job_id, job.epoch);

                /* Update epoch tracking for watcher */
                pthread_mutex_lock(&g_epoch_lock);
                if (job.epoch != g_cur_epoch) {
                    g_cur_epoch = job.epoch;
                    log_info("epoch set to %" PRIu32, g_cur_epoch);
                }
                pthread_mutex_unlock(&g_epoch_lock);
            }

            if (!have_job) continue;

            /* Wait for epoch tables to be valid */
            if (!(miner_io_status() & STAT_TABLES_VALID)) {
                sleep_ms_local(50);
                continue;
            }

            /* Dispatch next nonce batch */
            uint32_t cnt, start = nonce_get(&alloc, &cnt);
            if (miner_io_dispatch_job(job.header, sizeof(job.header),
                                      job.target, start, cnt) != 0) {
                log_error("dispatch_job failed");
                sleep(1);
                continue;
            }

            /* Poll for a result */
            uint32_t found_nonce;
            uint8_t  found_hash[32];
            int rc = miner_io_poll_result(&found_nonce, found_hash, poll_timeout_ms);
            if (rc == 0) {
                log_info("found nonce=0x%08" PRIx32, found_nonce);
                if (target_met(found_hash, job.target)) {
                    char ntime_hex[16], en2_hex[64];
                    snprintf(ntime_hex, sizeof(ntime_hex), "%08x", job.ntime);
                    /* extranonce2 as hex */
                    for (size_t i = 0; i < job.extranonce2_len && i < 8; i++)
                        snprintf(en2_hex + i*2, 3, "%02x", job.extranonce2[i]);
                    en2_hex[job.extranonce2_len * 2] = '\0';

                    if (stratum_submit_share(&st, &job, found_nonce) == 0)
                        log_info("share submitted (job=%s nonce=0x%08" PRIx32 ")",
                                 job.job_id, found_nonce);
                    else
                        log_warn("stratum_submit_share failed");
                } else {
                    log_info("hash did not meet target; continuing");
                }
            }
            /* ETIMEDOUT or no result — loop and dispatch next range */
        }

        stratum_disconnect(&st);
        if (!g_terminate) sleep(5);
    }

    log_info("shutting down");
    epoch_watcher_stop();
    stratum_disconnect(&st);
    miner_io_shutdown();
    return 0;
}
