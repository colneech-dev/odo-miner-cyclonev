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
#include <fcntl.h>
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
#define NONCE_RANGE_SIZE      250000u    /* nonces per batch (~few seconds at
                                            the sequential core's hashrate) */
#define POLL_TIMEOUT_MS       30000u     /* safety budget for one batch */
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
 * Hardware watchdog (opt-in: ODOD_WATCHDOG=1).
 * While enabled, the kernel reboots the board if this process stops
 * petting /dev/watchdog — a hung miner can't strand a headless rig.
 * On clean shutdown the magic 'V' write disarms the timer.
 * ---------------------------------------------------------------------- */
static int g_wd_fd = -1;

static void watchdog_open(void)
{
    const char *en = getenv("ODOD_WATCHDOG");
    if (!en || en[0] != '1')
        return;
    g_wd_fd = open("/dev/watchdog", O_WRONLY);
    if (g_wd_fd < 0)
        log_warn("ODOD_WATCHDOG=1 but /dev/watchdog unavailable: %s",
                 strerror(errno));
    else
        log_info("hardware watchdog armed");
}

static void watchdog_pet(void)
{
    if (g_wd_fd >= 0 && write(g_wd_fd, "\0", 1) < 0) { /* best effort */ }
}

static void watchdog_close(void)
{
    if (g_wd_fd >= 0) {
        if (write(g_wd_fd, "V", 1) < 0) { /* still closing */ }
        close(g_wd_fd);
        g_wd_fd = -1;
    }
}

/* -----------------------------------------------------------------------
 * Status export: small JSON snapshot for odo-ui / remote monitoring.
 * Written atomically (tmp + rename) on every heartbeat.
 * Path override: ODOD_STATUS_FILE (default /run/odod/status.json).
 * ---------------------------------------------------------------------- */
static struct {
    uint64_t shares_submitted;
    uint64_t shares_found;
    time_t   last_share;
    time_t   started;
    int      connected;
    uint32_t epoch_interval;   /* Odo shapechange interval (s) */
    char     pool[160];
    char     job_id[64];
} g_stat;

static void status_write(void)
{
    static const char *path;
    static uint64_t last_hashes;
    static time_t   last_time;
    static double   hashrate;

    if (!path) {
        path = getenv("ODOD_STATUS_FILE");
        if (!path) path = "/run/odod/status.json";
    }

    uint64_t hashes = 0;
    uint32_t fpga_shares = 0;
    miner_io_read_perf(&hashes, &fpga_shares, NULL);

    time_t now = time(NULL);
    if (last_time && now > last_time && hashes >= last_hashes)
        hashrate = (double)(hashes - last_hashes) / (double)(now - last_time);
    last_hashes = hashes;
    last_time   = now;

    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f,
        "{\n"
        "  \"pool\": \"%s\",\n"
        "  \"connected\": %s,\n"
        "  \"job_id\": \"%s\",\n"
        "  \"epoch\": %" PRIu32 ",\n"
        "  \"epoch_interval\": %" PRIu32 ",\n"
        "  \"epoch_next\": %ld,\n"
        "  \"hashrate\": %.1f,\n"
        "  \"hashes_total\": %" PRIu64 ",\n"
        "  \"shares_found\": %" PRIu64 ",\n"
        "  \"shares_submitted\": %" PRIu64 ",\n"
        "  \"last_share\": %ld,\n"
        "  \"uptime\": %ld,\n"
        "  \"updated\": %ld\n"
        "}\n",
        g_stat.pool,
        g_stat.connected ? "true" : "false",
        g_stat.job_id,
        g_cur_epoch == UINT32_MAX ? 0 : g_cur_epoch,
        g_stat.epoch_interval,
        (g_cur_epoch == UINT32_MAX || !g_stat.epoch_interval)
            ? 0L : (long)g_cur_epoch + (long)g_stat.epoch_interval,
        hashrate,
        hashes,
        g_stat.shares_found,
        g_stat.shares_submitted,
        (long)g_stat.last_share,
        (long)(now - g_stat.started),
        (long)now);
    fclose(f);
    rename(tmp, path);
}

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
 * Target comparison: returns 1 if hash <= target.
 * Both are little-endian uint256 byte arrays (byte 31 is most significant),
 * so the comparison walks from the most-significant byte downwards.
 * ---------------------------------------------------------------------- */
static int target_met(const uint8_t hash[32], const uint8_t target[32])
{
    for (int i = 31; i >= 0; i--) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 1;  /* equal counts as met */
}

/* -----------------------------------------------------------------------
 * Nonce allocator — simple linear counter
 * ---------------------------------------------------------------------- */
typedef struct { uint32_t next; uint32_t range; } nonce_alloc_t;

static void   nonce_init(nonce_alloc_t *a)              { a->next = 0; }
static uint32_t nonce_get(nonce_alloc_t *a, uint32_t *cnt)
{
    uint32_t s = a->next;
    *cnt = a->range;
    uint32_t next = s + a->range;
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

    memset(&g_stat, 0, sizeof(g_stat));
    g_stat.started = time(NULL);
    snprintf(g_stat.pool, sizeof(g_stat.pool), "%s:%s", pool_host, pool_port);

    watchdog_open();

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
    g_stat.epoch_interval = st.odo_interval;

    nonce_alloc_t alloc;
    nonce_init(&alloc);
    alloc.range = nonce_range_size > 0 ? nonce_range_size : NONCE_RANGE_SIZE;
    time_t last_hb = time(NULL);
    job_t  job;
    int    have_job = 0;

    while (!g_terminate) {
        watchdog_pet();

        /* Heartbeat */
        time_t now = time(NULL);
        if (now - last_hb >= heartbeat_interval_s) {
            log_info("heartbeat: epoch=%" PRIu32 " nonce_next=%" PRIu32,
                     g_cur_epoch, alloc.next);
            last_hb = now;
            status_write();
        }

        /* Connect / reconnect */
        if (stratum_connect(&st) != 0) {
            log_warn("stratum connect failed; retrying in 5 s");
            sleep(5);
            continue;
        }
        log_info("connected to %s:%s", pool_host, pool_port);
        g_stat.connected = 1;
        status_write();
        have_job = 0;

        /* Inner work loop.
         * State: batch_active tracks whether the FPGA is working on a range.
         * Stratum is serviced on every iteration so new jobs preempt the
         * current batch instead of waiting for it to finish. */
        int    batch_active   = 0;
        time_t batch_started  = 0;

        while (!g_terminate) {
            watchdog_pet();

            int n = stratum_poll(&st, batch_active ? 50 : 100 /*ms*/);
            if (n < 0) {
                log_warn("stratum poll error; reconnecting");
                break;
            }

            /* Heartbeat + status export (the outer-loop heartbeat only runs
             * between connections) */
            now = time(NULL);
            if (now - last_hb >= heartbeat_interval_s) {
                log_info("heartbeat: epoch=%" PRIu32 " nonce_next=%" PRIu32,
                         g_cur_epoch, alloc.next);
                last_hb = now;
                status_write();
            }

            /* Check for new job */
            job_t new_job;
            if (stratum_get_job(&st, &new_job)) {
                int same_gen = have_job && !new_job.clean_jobs &&
                               strncmp(new_job.job_id, job.job_id,
                                       sizeof(job.job_id)) == 0;
                memcpy(&job, &new_job, sizeof(job));
                have_job = 1;
                if (!same_gen) {
                    nonce_init(&alloc);
                    if (batch_active) {
                        miner_io_stop();   /* abort stale work */
                        batch_active = 0;
                    }
                }
                log_info("new job id=%s epoch=%" PRIu32, job.job_id, job.epoch);
                snprintf(g_stat.job_id, sizeof(g_stat.job_id), "%s", job.job_id);

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

            /* Harvest a finished/produced result */
            if (batch_active) {
                uint32_t found_nonce;
                uint8_t  found_hash[32];
                int rc = miner_io_check_result(&found_nonce, found_hash);

                if (rc == 0) {
                    batch_active = 0;
                    log_info("found nonce=0x%08" PRIx32, found_nonce);
                    g_stat.shares_found++;
                    g_stat.last_share = time(NULL);
                    if (target_met(found_hash, job.target))
                        log_info("*** BLOCK CANDIDATE (meets network target) ***");
                    if (target_met(found_hash, job.share_target)) {
                        if (stratum_submit_share(&st, &job, found_nonce) == 0) {
                            g_stat.shares_submitted++;
                            log_info("share submitted (job=%s nonce=0x%08" PRIx32 ")",
                                     job.job_id, found_nonce);
                        } else
                            log_warn("stratum_submit_share failed");
                    } else {
                        log_info("hash below share target rejected locally; continuing");
                    }
                } else if (rc == 1) {
                    batch_active = 0;   /* range exhausted, dispatch next */
                } else if (rc == EAGAIN) {
                    /* Safety net: if a batch runs far beyond expectations,
                     * reset and move on rather than hanging forever. */
                    if (poll_timeout_ms &&
                        time(NULL) - batch_started > (time_t)(poll_timeout_ms / 1000) + 1) {
                        log_warn("batch overran %u ms; resetting core", poll_timeout_ms);
                        miner_io_stop();
                        batch_active = 0;
                    }
                } else {
                    log_error("miner_io_check_result failed: %d", rc);
                    batch_active = 0;
                }
            }

            /* Dispatch the next nonce batch */
            if (!batch_active) {
                uint32_t cnt, start = nonce_get(&alloc, &cnt);
                int rc = miner_io_dispatch_job(job.header, sizeof(job.header),
                                               job.share_target, start, cnt);
                if (rc == -EAGAIN) {
                    /* Unread result still latched: mark the batch active so
                     * the harvest branch above consumes it on the next pass. */
                    batch_active  = 1;
                    batch_started = time(NULL);
                    continue;
                } else if (rc != 0) {
                    log_error("dispatch_job failed: %d", rc);
                    sleep(1);
                    continue;
                }
                batch_active  = 1;
                batch_started = time(NULL);
            }
        }

        stratum_disconnect(&st);
        g_stat.connected = 0;
        status_write();
        if (!g_terminate) sleep(5);
    }

    log_info("shutting down");
    watchdog_close();
    epoch_watcher_stop();
    stratum_disconnect(&st);
    miner_io_shutdown();
    return 0;
}
