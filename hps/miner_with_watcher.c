/*
 * miner_with_watcher.c — Integrated mining loop with automatic epoch watcher
 *
 * Ties together: stratum client, miner_io (FPGA bridge), and epoch_watcher
 * (background thread that reloads epoch tables when the chain advances).
 *
 * Epoch source: reads the current epoch from the file ./current_epoch (a
 * plain text file containing an unsigned integer).  The epoch is also updated
 * from each stratum job's epoch field if available.
 *
 * Build:
 *   make odo-miner-watcher
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <inttypes.h>

#include "stratum.h"
#include "miner_io.h"
#include "epoch_watcher.h"
#include "job.h"

/* -----------------------------------------------------------------------
 * Configuration (from environment variables or defaults)
 * ---------------------------------------------------------------------- */
#define EPOCH_FILE          "./current_epoch"
#define NONCE_RANGE_SIZE    1000000u
#define HEARTBEAT_INTERVAL  30
#define EPOCH_POLL_S        10u

static uint32_t get_env_u32(const char *var, uint32_t def)
{
    const char *val = getenv(var);
    return val ? (uint32_t)strtoul(val, NULL, 10) : def;
}

/* -----------------------------------------------------------------------
 * Globals
 * ---------------------------------------------------------------------- */
static volatile sig_atomic_t g_terminate    = 0;
static uint32_t              g_current_epoch = UINT32_MAX;

static void handle_signal(int s) { (void)s; g_terminate = 1; }

/* -----------------------------------------------------------------------
 * Logging
 * ---------------------------------------------------------------------- */
static void mlog(const char *tag, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stdout, "[miner_watcher/%s] ", tag);
    vfprintf(stdout, fmt, ap);
    fputc('\n', stdout);
    fflush(stdout);
    va_end(ap);
}
#define LOG(fmt, ...) mlog("info",  fmt, ##__VA_ARGS__)
#define WARN(fmt, ...) mlog("warn", fmt, ##__VA_ARGS__)

/* Sleep helper */
static void sleep_ms(unsigned ms)
{
    struct timespec ts = { .tv_sec = ms / 1000,
                           .tv_nsec = (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* -----------------------------------------------------------------------
 * Epoch getter: read current epoch from a small text file.
 * epoch_watcher calls this at every poll interval.
 * ---------------------------------------------------------------------- */
static uint32_t file_epoch_getter(void *ctx)
{
    const char *path = ctx ? (const char *)ctx : EPOCH_FILE;
    FILE *f = fopen(path, "r");
    if (!f) return UINT32_MAX;
    unsigned long v = 0;
    int ok = fscanf(f, "%lu", &v) == 1;
    fclose(f);
    return ok ? (uint32_t)v : UINT32_MAX;
}

/* -----------------------------------------------------------------------
 * Target check: returns 1 if hash <= target (both big-endian 32 bytes)
 * ---------------------------------------------------------------------- */
static int target_met(const uint8_t hash[32], const uint8_t target[32])
{
    for (int i = 0; i < 32; i++) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 1;
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

    struct sigaction sa = {0};
    sa.sa_handler = handle_signal;
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    /* Read tuning parameters from environment (optional) */
    uint32_t heartbeat_interval  = get_env_u32("ODOMIN_HEARTBEAT_S", HEARTBEAT_INTERVAL);
    uint32_t epoch_poll_s        = get_env_u32("ODOMIN_EPOCH_POLL_S", EPOCH_POLL_S);
    uint32_t nonce_range_size    = get_env_u32("ODOMIN_NONCE_RANGE", NONCE_RANGE_SIZE);
    uint32_t poll_timeout_ms     = get_env_u32("ODOMIN_POLL_TIMEOUT_MS", 2000);

    LOG("starting (pool=%s:%s worker=%s)", pool_host, pool_port, worker);
    LOG("configuration: nonce_range=%u poll_timeout_ms=%u epoch_poll_s=%u heartbeat_s=%u",
        nonce_range_size, poll_timeout_ms, epoch_poll_s, heartbeat_interval);

    /* FPGA bridge */
    if (miner_io_init(NULL) != 0) {
        fprintf(stderr, "[miner_watcher] miner_io_init failed\n");
        return 1;
    }

    /* Epoch watcher (background thread) */
    epoch_watcher_start(file_epoch_getter, (void *)EPOCH_FILE, epoch_poll_s);
    LOG("epoch watcher started (source: %s)", EPOCH_FILE);

    /* Stratum */
    stratum_ctx_t st;
    if (stratum_init(&st, pool_host, pool_port, worker, password) != 0) {
        fprintf(stderr, "[miner_watcher] stratum_init failed\n");
        return 1;
    }

    uint32_t next_nonce = 0;
    time_t   last_hb    = time(NULL);
    job_t    job;
    int      have_job   = 0;

    while (!g_terminate) {
        /* Heartbeat */
        time_t now = time(NULL);
        if (now - last_hb >= heartbeat_interval) {
            uint32_t ep = epoch_watcher_current_epoch();
            LOG("heartbeat epoch=%" PRIu32 " next_nonce=%" PRIu32, ep, next_nonce);
            last_hb = now;
        }

        /* Connect / reconnect */
        if (stratum_connect(&st) != 0) {
            WARN("%s", "stratum connect failed; retry in 5 s");
            sleep(5);
            continue;
        }
        LOG("connected to %s:%s", pool_host, pool_port);
        have_job = 0;

        while (!g_terminate) {
            if (stratum_poll(&st, 100) < 0) {
                WARN("%s", "stratum poll error; reconnecting");
                break;
            }

            job_t new_job;
            if (stratum_get_job(&st, &new_job)) {
                memcpy(&job, &new_job, sizeof(job));
                have_job = 1;
                next_nonce = 0;
                LOG("new job id=%s epoch=%" PRIu32, job.job_id, job.epoch);

                /* If job carries a different epoch, trigger load immediately */
                if (job.epoch != g_current_epoch) {
                    g_current_epoch = job.epoch;
                    /* Write current_epoch file so watcher picks it up too */
                    FILE *f = fopen(EPOCH_FILE, "w");
                    if (f) { fprintf(f, "%" PRIu32 "\n", job.epoch); fclose(f); }
                }
            }

            if (!have_job) continue;

            /* Wait until epoch tables are loaded */
            if (!(miner_io_status() & STAT_TABLES_VALID)) {
                sleep_ms(50);
                continue;
            }

            /* Dispatch */
            uint32_t nonce_start = next_nonce;
            uint32_t new_next = next_nonce + NONCE_RANGE_SIZE;
            if (new_next < next_nonce) {
                WARN("nonce counter wrapped (searched 0x00000000–0x%08x, restarting)", next_nonce);
                next_nonce = 0;
            } else {
                next_nonce = new_next;
            }

            if (miner_io_dispatch_job(job.header, sizeof(job.header),
                                      job.target, nonce_start, NONCE_RANGE_SIZE) != 0) {
                WARN("%s", "dispatch_job failed");
                sleep(1);
                continue;
            }

            /* Poll for result */
            uint32_t found_nonce;
            uint8_t  found_hash[32];
            int rc = miner_io_poll_result(&found_nonce, found_hash, poll_timeout_ms);
            if (rc == 0) {
                LOG("found nonce=0x%08" PRIx32, found_nonce);
                if (target_met(found_hash, job.target)) {
                    char ntime_hex[16] = {0}, en2_hex[64] = {0};
                    snprintf(ntime_hex, sizeof(ntime_hex), "%08x", job.ntime);
                    for (size_t i = 0; i < job.extranonce2_len && i*2+2 < sizeof(en2_hex); i++)
                        snprintf(en2_hex + i*2, 3, "%02x", job.extranonce2[i]);

                    if (stratum_submit_share(&st, &job, found_nonce) == 0)
                        LOG("share submitted job=%s nonce=0x%08" PRIx32, job.job_id, found_nonce);
                    else
                        WARN("%s", "stratum_submit_share failed");
                }
            }
            /* ETIMEDOUT: no result — try next nonce range */
        }

        stratum_disconnect(&st);
        if (!g_terminate) sleep(5);
    }

    LOG("%s", "shutting down");
    epoch_watcher_stop();
    stratum_disconnect(&st);
    miner_io_shutdown();
    return 0;
}
