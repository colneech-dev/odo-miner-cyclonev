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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
#include <signal.h>
#include <time.h>

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
    uint32_t epoch;
    uint32_t epoch_interval;
    uint64_t found;
    uint64_t shares;
    time_t   last_share;
    time_t   started;
    double   hashrate;        /* H/s, estimated from the free-running nonce */
} g_st;

/* Hashrate from the free-running nonce counter: between found events the
 * nonce advances by the number of nonces swept. EMA-smoothed. */
static void hashrate_sample(uint32_t nonce)
{
    static uint32_t prev_nonce;
    static time_t   prev_time;
    static int      have_prev;
    time_t now = time(NULL);
    if (have_prev && now > prev_time) {
        uint32_t dn = nonce - prev_nonce;             /* wraps mod 2^32 */
        double inst = (double)dn / (double)(now - prev_time);
        g_st.hashrate = g_st.hashrate ? (0.7 * g_st.hashrate + 0.3 * inst) : inst;
    }
    prev_nonce = nonce; prev_time = now; have_prev = 1;
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
    long enext = (g_st.epoch && g_st.epoch_interval)
               ? (long)g_st.epoch + (long)g_st.epoch_interval : 0L;
    fprintf(f,
        "{\n"
        "  \"pool\": \"%s\",\n"
        "  \"connected\": %s,\n"
        "  \"core\": \"pipelined\",\n"
        "  \"job_id\": \"%s\",\n"
        "  \"epoch\": %" PRIu32 ",\n"
        "  \"epoch_interval\": %" PRIu32 ",\n"
        "  \"epoch_next\": %ld,\n"
        "  \"hashrate\": %.1f,\n"
        "  \"hashes_total\": 0,\n"
        "  \"shares_found\": %" PRIu64 ",\n"
        "  \"shares_submitted\": %" PRIu64 ",\n"
        "  \"last_share\": %ld,\n"
        "  \"best_diff_session\": 0,\n"
        "  \"best_diff_alltime\": 0,\n"
        "  \"uptime\": %ld,\n"
        "  \"updated\": %ld\n"
        "}\n",
        g_st.pool, g_st.connected ? "true" : "false", g_st.job_id,
        g_st.epoch, g_st.epoch_interval, enext, g_st.hashrate,
        g_st.found, g_st.shares, (long)g_st.last_share,
        (long)(now - g_st.started), (long)now);
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

    /* Seed the status struct: pool string, epoch params, start time. */
    snprintf(g_st.pool, sizeof(g_st.pool), "%s:%s", host, port);
    g_st.epoch          = seed;
    g_st.epoch_interval = 86400;          /* testnet OdoCrypt epoch length */
    g_st.started        = time(NULL);
    status_write();

    stratum_ctx_t st;
    if (stratum_init(&st, host, port, worker, pass) != 0) {
        fprintf(stderr, "[pipe] stratum_init failed\n");
        miner_io_pipe_shutdown();
        return 1;
    }

    job_t cur; job_init(&cur);
    int have_cur = 0;
    uint64_t found = 0, shares = 0, stale = 0;
    time_t last_status = 0;

    while (!g_term) {
        if (stratum_connect(&st) != 0) {
            fprintf(stderr, "[pipe] connect %s:%s failed; retry in 5 s\n", host, port);
            g_st.connected = 0;
            status_write();
            sleep_ms(5000);
            continue;
        }
        printf("[pipe] connected to %s:%s\n", host, port);
        have_cur = 0;
        g_st.connected = 1;
        status_write();

        while (!g_term) {
            if (stratum_poll(&st, 50) < 0) {
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
                hashrate_sample(nonce);
                uint8_t h[32];
                compute_pow(cur.header, nonce, h);
                if (target_met(h, cur.share_target)) {
                    if (stratum_submit_share(&st, &cur, nonce) == 0) {
                        shares++;
                        g_st.shares     = shares;
                        g_st.last_share = time(NULL);
                        printf("[pipe] SHARE job=%s nonce=0x%08" PRIx32
                               " (found=%" PRIu64 " shares=%" PRIu64 ")\n",
                               cur.job_id, nonce, found, shares);
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
    printf("[pipe] exit: found=%" PRIu64 " shares=%" PRIu64 " stale=%" PRIu64 "\n",
           found, shares, stale);
    return 0;
}
