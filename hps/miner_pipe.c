/*
 * miner_pipe.c — Stratum mining daemon for the PIPELINED OdoCrypt FPGA core.
 *
 * Counterpart to miner.c (sequential FSM). The pipelined bitstream bakes the
 * epoch in and free-runs, so this daemon is much simpler than the FSM one:
 *   - no epoch-table streaming (verify the baked-in REG_PIPE_SEED instead),
 *   - no nonce-range allocation (the core sweeps all nonces continuously),
 *   - on each new job: build the header, write header+target+COMMIT,
 *   - poll the found-FIFO, validate each nonce against the current job with the
 *     oracle (== upstream odocrypt.cpp), and submit the ones that meet target.
 *
 * Validating against the *current* job is also the stale-job guard: a nonce
 * computed for a previous header (one that slipped past the wrapper's settle
 * window) recomputes to a non-qualifying hash and is dropped.
 *
 * Usage: odo-miner-pipe <host> <port> <worker> [pass]
 *   (or STRATUM_HOST / STRATUM_PORT / STRATUM_WORKER env vars)
 */

#define _POSIX_C_SOURCE 200809L

#include "stratum.h"
#include "job.h"
#include "odocrypt_header.h"
#include "odocrypt_state.h"
#include "KeccakP-800-SnP.h"
#include "miner_io_pipe.h"
#include "thermal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <pthread.h>

static volatile sig_atomic_t g_term = 0;
static void on_sig(int s) { (void)s; g_term = 1; }

/* Epoch state for share validation — generated once to match the bitstream. */
static odo_epoch_state_t g_epoch;

static void sleep_ms(unsigned ms)
{
    struct timespec ts = { ms / 1000u, (long)(ms % 1000u) * 1000000L };
    nanosleep(&ts, NULL);
}

/* OdoCrypt + Keccak PoW for (header, nonce), nonce injected at bytes 76..79. */
static void compute_pow(const uint8_t header[80], uint32_t nonce, uint8_t hash[32])
{
    uint8_t st[KeccakP800_stateSizeInBytes];
    memset(st, 0, sizeof(st));
    memcpy(st, header, 80);
    st[76] = (uint8_t)(nonce);       st[77] = (uint8_t)(nonce >> 8);
    st[78] = (uint8_t)(nonce >> 16); st[79] = (uint8_t)(nonce >> 24);
    st[80] = 1;
    odo_encrypt(&g_epoch, st, st);
    KeccakP800_Permute_12rounds(st);
    memcpy(hash, st, 32);
}

/* uint256 hash <= target (little-endian, byte[31] = MSB). */
static int target_met(const uint8_t hash[32], const uint8_t target[32])
{
    for (int i = 31; i >= 0; i--) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 1;
}

/* -----------------------------------------------------------------------
 * Status JSON — same schema odod writes, so odo-ui / odo-webd render the
 * pipelined miner on the screen + web dashboard with no changes.
 * ---------------------------------------------------------------------- */
static struct {
    char     pool[80];
    int      connected;
    char     job_id[JOB_MAX_JOBID_LEN];
    uint32_t epoch;             /* CURRENT JOB's epoch (overwritten per job)  */
    uint32_t bitstream_epoch;   /* FPGA's baked-in epoch (fixed at startup) -
                                  * the authoritative epoch-renewal trigger is
                                  * epoch != bitstream_epoch, not a wall-clock
                                  * guess (see epoch-update.sh) */
    uint32_t epoch_interval;
    uint64_t found;
    uint64_t shares;
    uint64_t shares_accepted;   /* pool-confirmed result:true (H3)  */
    uint64_t shares_rejected;   /* pool-confirmed result:false (H3) */
    time_t   last_share;
    time_t   started;
    double   work_acc;        /* cumulative expected hashes from accepted shares */
    double   hashrate;        /* H/s = work_acc / uptime (pool-style estimate)   */
    double   best_diff_session; /* highest difficulty share this run */
    double   best_diff_alltime; /* highest difficulty share ever (persisted) */
    uint64_t blocks_found;      /* shares that ALSO met the network target,
                                  * ever (persisted) — a genuine found block,
                                  * not just a pool share */
    time_t   last_block;        /* unix time of the most recent block (0 = none yet) */
    int      temp_c;            /* DS18B20 reading, -1 = no sensor/no reading yet */
    int      fan_pct;           /* current commanded fan speed, 0-100 (%) */
    int      fan_rpm;           /* tach-measured RPM, -1 = no tach */
} g_st;

/* -----------------------------------------------------------------------
 * Thermal monitoring runs on its own thread so a tach-sampling window
 * (thermal_tach_rpm blocks for its full duration) never delays draining
 * the FPGA's 1-deep found-FIFO. g_therm_mu only guards the three fields
 * above between this thread and status_write() on the main thread.
 * ---------------------------------------------------------------------- */
static pthread_mutex_t g_therm_mu = PTHREAD_MUTEX_INITIALIZER;

/* Reset button (pio_thermal bit2): hold ~2 s to reboot. Polled at 10 Hz during
 * the thermal thread's idle window; the line idles high, so a floating/unpressed
 * pin never triggers, and the long hold rules out accidental brushes. */
#define RESET_HOLD_TICKS  20   /* 20 x 100 ms = ~2 s held */

static void *thermal_thread(void *arg)
{
    (void)arg;
    if (thermal_init() != 0)
        fprintf(stderr, "[pipe] thermal_init failed; fan control disabled\n");

    int reset_held = 0;
    while (!g_term) {
        int t;
        if (thermal_read_c(&t) == 0) {
            thermal_fan_update(t);
            int rpm = thermal_tach_rpm(200);
            pthread_mutex_lock(&g_therm_mu);
            g_st.temp_c  = t;
            g_st.fan_pct = thermal_fan_state();
            g_st.fan_rpm = rpm;
            pthread_mutex_unlock(&g_therm_mu);
        }
        /* Idle window doubles as the reset-button poll (10 Hz). */
        for (int i = 0; i < 20 && !g_term; i++) {
            if (thermal_reset_pressed()) {
                if (++reset_held >= RESET_HOLD_TICKS) {
                    fprintf(stderr, "[pipe] reset button held -- rebooting\n");
                    if (system("sync; reboot") != 0) { /* best effort */ }
                    reset_held = 0;
                }
            } else {
                reset_held = 0;
            }
            sleep_ms(100);
        }
    }
    thermal_shutdown();
    return NULL;
}

/* -----------------------------------------------------------------------
 * best_diff_alltime / blocks_found persistence — separate file from the FSM
 * daemon's /var/lib/odod/stats (different share-counting semantics; only
 * the all-time records would make sense to share, not worth the format
 * coordination between two independently-evolving daemons).
 * ---------------------------------------------------------------------- */
#define PIPE_STATS_PATH "/var/lib/odod/stats_pipe"

static void stats_load(void)
{
    FILE *f = fopen(PIPE_STATS_PATH, "r");
    if (!f) return;
    double best = 0.0;
    unsigned long long blocks = 0;
    int n = fscanf(f, "%lf %llu", &best, &blocks);
    if (n >= 1)
        g_st.best_diff_alltime = best;
    if (n >= 2)
        g_st.blocks_found = blocks;
    fclose(f);
}

static void stats_save(void)
{
    FILE *f = fopen(PIPE_STATS_PATH ".tmp", "w");
    if (!f) return;
    fprintf(f, "%.6g %" PRIu64 "\n", g_st.best_diff_alltime, g_st.blocks_found);
    fclose(f);
    rename(PIPE_STATS_PATH ".tmp", PIPE_STATS_PATH);
}

/* Difficulty of a 32-byte LE hash relative to the OdoCrypt diff-1 target
 * (0xFFFF << 208). Uses the top bytes for a good double approximation.
 * Mirrors miner.c's hash_to_difficulty exactly (same diff-1 convention). */
static double hash_to_difficulty(const uint8_t hash_le[32])
{
    double h = 0.0;
    int i;
    for (i = 31; i >= 24; i--)
        h = h * 256.0 + (double)hash_le[i];
    if (h < 1.0) {
        for (i = 23; i >= 16; i--)
            h = h * 256.0 + (double)hash_le[i];
        if (h < 1.0) return 1e15;
        return (double)0xFFFF0000U / h * 18446744073709551616.0;
    }
    return (double)0xFFFF0000U / h;
}

/* Expected number of hashes represented by one share at this target:
 * P(hash <= target) = target / 2^256, so each accepted share is ~2^256/target
 * hashes of work. The free-running core has no hardware hash counter, so this
 * statistical estimate (summed over accepted shares / uptime) is the only sound
 * hashrate measure — the found nonces themselves are random, not a sweep count.
 * target is little-endian (byte[31] = MSB). */
static double share_work(const uint8_t target[32])
{
    double tv = 0.0;
    for (int i = 31; i >= 0; i--) tv = tv * 256.0 + (double)target[i];
    if (tv <= 0.0) return 0.0;
    return ldexp(1.0, 256) / tv;          /* 2^256 / target */
}

/* Monotonic seconds — immune to the wall-clock step when the board's clock
 * syncs after boot (using time(NULL) for elapsed gave uptime ~= now and
 * hashrate ~= 0 because g_st.started was captured at ~unix 0). */
static double g_mono_start;
static double mono_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void status_write(void)
{
    const char *path = getenv("ODOD_STATUS_FILE");
    if (!path) path = "/run/odod/status.json";
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    time_t now = time(NULL);
    double up = mono_s() - g_mono_start;          /* elapsed, clock-step safe */
    g_st.hashrate = (up > 0.0) ? g_st.work_acc / up : 0.0;
    long enext = (g_st.epoch && g_st.epoch_interval)
               ? (long)g_st.epoch + (long)g_st.epoch_interval : 0L;
    pthread_mutex_lock(&g_therm_mu);
    int temp_c = g_st.temp_c, fan_pct = g_st.fan_pct, fan_rpm = g_st.fan_rpm;
    pthread_mutex_unlock(&g_therm_mu);
    fprintf(f,
        "{\n"
        "  \"pool\": \"%s\",\n"
        "  \"connected\": %s,\n"
        "  \"core\": \"pipelined\",\n"
        "  \"job_id\": \"%s\",\n"
        "  \"epoch\": %" PRIu32 ",\n"
        "  \"bitstream_epoch\": %" PRIu32 ",\n"
        "  \"epoch_interval\": %" PRIu32 ",\n"
        "  \"epoch_next\": %ld,\n"
        "  \"hashrate\": %.1f,\n"
        "  \"hashes_total\": 0,\n"
        "  \"shares_found\": %" PRIu64 ",\n"
        "  \"shares_submitted\": %" PRIu64 ",\n"
        "  \"shares_accepted\": %" PRIu64 ",\n"
        "  \"shares_rejected\": %" PRIu64 ",\n"
        "  \"last_share\": %ld,\n"
        "  \"best_diff_session\": %.6g,\n"
        "  \"best_diff_alltime\": %.6g,\n"
        "  \"blocks_found\": %" PRIu64 ",\n"
        "  \"last_block\": %ld,\n"
        "  \"temp_c\": %d,\n"
        "  \"fan_duty_pct\": %d,\n"
        "  \"fan_rpm\": %d,\n"
        "  \"uptime\": %ld,\n"
        "  \"updated\": %ld\n"
        "}\n",
        g_st.pool, g_st.connected ? "true" : "false", g_st.job_id,
        g_st.epoch, g_st.bitstream_epoch, g_st.epoch_interval, enext, g_st.hashrate,
        g_st.found, g_st.shares, g_st.shares_accepted, g_st.shares_rejected,
        (long)g_st.last_share,
        g_st.best_diff_session, g_st.best_diff_alltime,
        g_st.blocks_found, (long)g_st.last_block,
        temp_c, fan_pct, fan_rpm,
        (long)up, (long)now);
    fclose(f);
    rename(tmp, path);
}

int main(int argc, char **argv)
{
    const char *host   = argc > 1 ? argv[1] : getenv("STRATUM_HOST");
    const char *port   = argc > 2 ? argv[2] : getenv("STRATUM_PORT");
    const char *worker = argc > 3 ? argv[3] : getenv("STRATUM_WORKER");
    const char *pass   = argc > 4 ? argv[4] : "x";
    if (!host || !port || !worker) {
        fprintf(stderr, "usage: %s <host> <port> <worker> [pass]\n", argv[0]);
        return 1;
    }

    signal(SIGINT,  on_sig);
    signal(SIGTERM, on_sig);

    if (miner_io_pipe_init() != 0) {
        fprintf(stderr, "[pipe] miner_io_pipe_init failed (run as root?)\n");
        return 1;
    }
    uint32_t seed = miner_io_pipe_seed();
    uint32_t ver  = miner_io_pipe_version();
    printf("[pipe] FPGA epoch=%" PRIu32 " (0x%08" PRIx32 ") version=0x%08" PRIx32 "\n",
           seed, seed, ver);
    odo_epoch_generate(&g_epoch, seed);   /* validation uses the baked-in epoch */

    /* Optional backup pool: tried alternately after each failed connect. */
    const char *hosts[2] = { host, getenv("ODOD_POOL_HOST2") };
    const char *ports[2] = { port, getenv("ODOD_POOL_PORT2") };
    int n_pools  = (hosts[1] && hosts[1][0] && ports[1] && ports[1][0]) ? 2 : 1;
    int pool_idx = 0;
    if (n_pools > 1)
        printf("[pipe] backup pool configured: %s:%s\n", hosts[1], ports[1]);

    /* Seed the status struct: pool string, epoch params, start time. */
    snprintf(g_st.pool, sizeof(g_st.pool), "%s:%s", host, port);
    g_st.epoch           = seed;   /* overwritten per job below */
    g_st.bitstream_epoch = seed;   /* fixed: what's actually baked into the FPGA */
    g_st.started = time(NULL);
    g_st.temp_c  = -1;             /* no reading yet */
    g_st.fan_rpm = -1;
    g_mono_start = mono_s();       /* clock-step-safe uptime baseline */
    stats_load();                  /* best_diff_alltime, survives reboots */
    status_write();

    pthread_t therm_tid;
    int have_therm = (pthread_create(&therm_tid, NULL, thermal_thread, NULL) == 0);
    if (!have_therm)
        fprintf(stderr, "[pipe] failed to start thermal thread\n");

    stratum_ctx_t st;
    if (stratum_init(&st, host, port, worker, pass) != 0) {
        fprintf(stderr, "[pipe] stratum_init failed\n");
        miner_io_pipe_shutdown();
        return 1;
    }
    g_st.epoch_interval = st.odo_interval;   /* from ODO_TESTNET/ODO_EPOCH_INTERVAL */

    job_t cur; job_init(&cur);
    int have_cur = 0;
    uint64_t found = 0, shares = 0, stale = 0;
    time_t last_status = 0;

    while (!g_term) {
        if (stratum_connect(&st) != 0) {
            fprintf(stderr, "[pipe] connect %s:%s failed; retry in 5 s\n",
                    hosts[pool_idx], ports[pool_idx]);
            g_st.connected = 0;
            status_write();
            if (n_pools > 1) {
                pool_idx = (pool_idx + 1) % n_pools;
                stratum_init(&st, hosts[pool_idx], ports[pool_idx], worker, pass);
                g_st.epoch_interval = st.odo_interval;
                snprintf(g_st.pool, sizeof(g_st.pool), "%s:%s",
                         hosts[pool_idx], ports[pool_idx]);
                printf("[pipe] switching to pool %s:%s\n",
                       hosts[pool_idx], ports[pool_idx]);
            }
            sleep_ms(5000);
            continue;
        }
        printf("[pipe] connected to %s:%s\n", hosts[pool_idx], ports[pool_idx]);
        have_cur = 0;
        g_st.connected = 1;
        status_write();

        while (!g_term) {
            /* WS3b: pace the loop on the found-nonce wait, then service stratum
             * non-blocking. The UIO backend blocks on the found-nonce IRQ (waking
             * the drain the instant a nonce lands); the /dev/mem backend does a
             * bounded ~5 ms nap (returning early if one is already pending), so
             * both keep the ~200/s drain that the 1-deep found-latch needs (a
             * 50 ms cap previously dropped most finds, incl. potential blocks). */
            miner_io_pipe_wait(5);
            if (stratum_poll(&st, 0) < 0) {
                fprintf(stderr, "[pipe] poll error; reconnecting\n");
                break;
            }

            job_t nj;
            if (stratum_get_job(&st, &nj)) {
                int same = have_cur &&
                    strncmp(nj.job_id, cur.job_id, sizeof(cur.job_id)) == 0;
                if (!same) {
                    cur = nj;
                    have_cur = 1;
                    if (cur.epoch != seed) {
                        fprintf(stderr, "[pipe] WARN job epoch %" PRIu32
                                " != bitstream epoch %" PRIu32 " — bitstream stale;"
                                " shares invalid until reconfigure (Phase 2)\n",
                                cur.epoch, seed);
                    }
                    odocrypt_build_header(&cur, cur.header);
                    miner_io_pipe_dispatch(cur.header, cur.share_target);
                    snprintf(g_st.job_id, sizeof(g_st.job_id), "%s", cur.job_id);
                    g_st.epoch = cur.epoch;
                    printf("[pipe] new job id=%s epoch=%" PRIu32 " dispatched\n",
                           cur.job_id, cur.epoch);
                }
            }
            if (!have_cur) goto status_tick;

            /* Drain the found-FIFO; validate each nonce against the current job. */
            uint32_t nonce;
            while (miner_io_pipe_poll(&nonce) == 0) {
                found++;
                g_st.found = found;
                uint8_t h[32];
                compute_pow(cur.header, nonce, h);
                if (target_met(h, cur.share_target)) {
                    if (stratum_submit_share(&st, &cur, nonce) == 0) {
                        shares++;
                        g_st.shares     = shares;
                        g_st.last_share = time(NULL);
                        g_st.work_acc  += share_work(cur.share_target);
                        double d = hash_to_difficulty(h);
                        if (d > g_st.best_diff_session)
                            g_st.best_diff_session = d;
                        int new_best = (d > g_st.best_diff_alltime);
                        if (new_best)
                            g_st.best_diff_alltime = d;
                        int is_block = target_met(h, cur.target);
                        if (is_block) {
                            g_st.blocks_found++;
                            g_st.last_block = time(NULL);
                            printf("[pipe] *** BLOCK FOUND *** job=%s nonce=0x%08"
                                   PRIx32 " diff=%.6g (blocks_found=%" PRIu64 ")\n",
                                   cur.job_id, nonce, d, g_st.blocks_found);
                        }
                        if (new_best || is_block)
                            stats_save();
                        printf("[pipe] SHARE job=%s nonce=0x%08" PRIx32
                               " diff=%.6g (found=%" PRIu64 " shares=%" PRIu64 ")\n",
                               cur.job_id, nonce, d, found, shares);
                    } else {
                        fprintf(stderr, "[pipe] stratum_submit_share failed\n");
                    }
                } else {
                    stale++;   /* old-header nonce past the settle window — drop */
                }
            }

        status_tick:
            /* Refresh status.json ~every 3 s for odo-ui / odo-webd. */
            {
                time_t now = time(NULL);
                if (now - last_status >= 3) {
                    last_status = now;
                    stratum_share_stats(&st, &g_st.shares_accepted,
                                        &g_st.shares_rejected);
                    status_write();
                }
            }
        }
        g_st.connected = 0;
        status_write();
        stratum_disconnect(&st);
    }

    stratum_destroy(&st);
    miner_io_pipe_shutdown();
    if (have_therm)
        pthread_join(therm_tid, NULL);
    printf("[pipe] exit: found=%" PRIu64 " shares=%" PRIu64 " stale=%" PRIu64 "\n",
           found, shares, stale);
    return 0;
}
