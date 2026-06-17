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

    stratum_ctx_t st;
    if (stratum_init(&st, host, port, worker, pass) != 0) {
        fprintf(stderr, "[pipe] stratum_init failed\n");
        miner_io_pipe_shutdown();
        return 1;
    }

    job_t cur; job_init(&cur);
    int have_cur = 0;
    uint64_t found = 0, shares = 0, stale = 0;

    while (!g_term) {
        if (stratum_connect(&st) != 0) {
            fprintf(stderr, "[pipe] connect %s:%s failed; retry in 5 s\n", host, port);
            sleep_ms(5000);
            continue;
        }
        printf("[pipe] connected to %s:%s\n", host, port);
        have_cur = 0;

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
                    printf("[pipe] new job id=%s epoch=%" PRIu32 " dispatched\n",
                           cur.job_id, cur.epoch);
                }
            }
            if (!have_cur) continue;

            /* Drain the found-FIFO; validate each nonce against the current job. */
            uint32_t nonce;
            while (miner_io_pipe_poll(&nonce) == 0) {
                found++;
                uint8_t h[32];
                compute_pow(cur.header, nonce, h);
                if (target_met(h, cur.share_target)) {
                    if (stratum_submit_share(&st, &cur, nonce) == 0) {
                        shares++;
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
        }
        stratum_disconnect(&st);
    }

    stratum_destroy(&st);
    miner_io_pipe_shutdown();
    printf("[pipe] exit: found=%" PRIu64 " shares=%" PRIu64 " stale=%" PRIu64 "\n",
           found, shares, stale);
    return 0;
}
