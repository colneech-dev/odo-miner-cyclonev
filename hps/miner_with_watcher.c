/* hps/miner_with_watcher.c
 *
 * Miner control loop that integrates the epoch_watcher module.
 * - Starts an epoch_watcher that reads current epoch from ./current_epoch
 *   and loads ./epochs/epoch_<N>.bin when the epoch changes.
 * - Uses the miner_io and stratum APIs (adapt names/signatures as needed)
 * - Demonstrates start/stop of the watcher and graceful shutdown
 *
 * Build: add to hps Makefile or compile with the project's existing build rules.
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <inttypes.h>

/* Project headers (adapt paths if necessary) */
#include "stratum.h"
#include "miner_io.h"
#include "odocrypt_state.h"

/* epoch_watcher has been added earlier; declare the start/stop prototypes
 * using compatible function-pointer types so we can call them here.
 */
int epoch_watcher_start(uint32_t (*getter)(void*), void *getter_ctx,
                        size_t (*data_getter)(uint32_t, void **, void *), void *data_ctx,
                        unsigned poll_seconds);
void epoch_watcher_stop(void);

/* --- Config */
#define EPOCH_DIR "./epochs"
#define EPOCH_FILE "./current_epoch"
#define HEARTBEAT_INTERVAL_S 5
#define NONCE_RANGE_SIZE 1000000U

static volatile sig_atomic_t g_terminate = 0;
static uint32_t g_current_epoch = UINT32_MAX;

static void handle_signal(int sig) { (void)sig; g_terminate = 1; }

/* epoch_getter: read epoch number from a small file containing an unsigned integer */
static uint32_t file_epoch_getter(void *ctx) {
    const char *path = (const char *)ctx;
    if (!path) path = EPOCH_FILE;
    FILE *f = fopen(path, "r");
    if (!f) return UINT32_MAX;
    unsigned long v = 0;
    if (fscanf(f, "%lu", &v) != 1) { fclose(f); return UINT32_MAX; }
    fclose(f);
    return (uint32_t)v;
}

/* epoch_data_getter: load ./epochs/epoch_<N>.bin into malloc'd buffer and return word count */
static size_t disk_epoch_data_getter(uint32_t epoch, void **out_epoch_data, void *ctx) {
    (void)ctx;
    char path[512];
    int n = snprintf(path, sizeof(path), "%s/epoch_%u.bin", EPOCH_DIR, epoch);
    if (n < 0 || (size_t)n >= sizeof(path)) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 0; }
    long sz = ftell(f);
    if (sz <= 0) { fclose(f); return 0; }
    rewind(f);
    void *buf = malloc((size_t)sz);
    if (!buf) { fclose(f); return 0; }
    size_t read = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if ((long)read != sz) { free(buf); return 0; }
    *out_epoch_data = buf;
    /* Return number of 32-bit words */
    return (size_t)sz / 4;
}

/* Helper: attempt to load epoch into FPGA using odocrypt_state API */
static int load_epoch_if_needed(uint32_t epoch, const void *epoch_data, size_t epoch_words) {
    if (g_current_epoch == epoch) return 0;
    int rc = odo_fpga_load_epoch(epoch, epoch_data, epoch_words);
    if (rc == 0) {
        g_current_epoch = epoch;
        fprintf(stdout, "[miner] epoch %" PRIu32 " loaded\n", epoch);
    } else {
        fprintf(stderr, "[miner] failed to load epoch %" PRIu32 " rc=%d\n", epoch, rc);
    }
    return rc;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    struct sigaction sa = {0};
    sa.sa_handler = handle_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    fprintf(stdout, "miner_with_watcher starting\n");

    if (miner_io_init(NULL) != 0) {
        fprintf(stderr, "miner_io_init failed\n");
        return 1;
    }

    const char *stratum_url = getenv("STRATUM_URL");
    if (!stratum_url) stratum_url = "stratum+tcp://127.0.0.1:3333";
    if (stratum_connect(stratum_url) != 0) {
        fprintf(stderr, "stratum_connect failed\n");
        miner_io_shutdown();
        return 2;
    }

    /* Start epoch watcher: reads ./current_epoch and loads epoch files from ./epochs */
    if (epoch_watcher_start(file_epoch_getter, (void *)EPOCH_FILE,
                            disk_epoch_data_getter, NULL, 10) != 0) {
        fprintf(stderr, "epoch_watcher_start failed\n");
        /* not fatal — we can still respond to job-based epoch loads */
    } else {
        fprintf(stdout, "epoch_watcher started\n");
    }

    /* Main mining loop (simplified) */
    uint32_t next_nonce = 0;
    time_t last_hb = time(NULL);

    job_t job;
    while (!g_terminate) {
        time_t now = time(NULL);
        if ((now - last_hb) >= HEARTBEAT_INTERVAL_S) {
            fprintf(stdout, "[miner] hb epoch=%" PRIu32 " next_nonce=%" PRIu32 "\n", g_current_epoch, next_nonce);
            last_hb = now;
        }

        memset(&job, 0, sizeof(job));
        int r = stratum_wait_job(&job);
        if (r <= 0) { sleep(1); continue; }

        fprintf(stdout, "[miner] got job id=%s epoch=%" PRIu32 "\n", job.job_id, job.epoch);

        /* Ensure epoch is loaded: try to get epoch file and load directly, else rely on watcher */
        void *epoch_buf = NULL;
        size_t epoch_words = disk_epoch_data_getter(job.epoch, &epoch_buf, NULL);
        if (epoch_words > 0) {
            load_epoch_if_needed(job.epoch, epoch_buf, epoch_words);
            free(epoch_buf);
        } else {
            /* fall back to calling loader with NULL data -- module may fetch itself */
            load_epoch_if_needed(job.epoch, NULL, 0);
        }

        uint32_t nonce_start = next_nonce;
        uint32_t nonce_count = NONCE_RANGE_SIZE;
        next_nonce += nonce_count;

        if (miner_io_dispatch_range(job.header, sizeof(job.header), nonce_start, nonce_count) != 0) {
            fprintf(stderr, "dispatch failed\n");
            sleep(1); continue;
        }

        uint32_t found_nonce = 0; uint8_t digest[32];
        int poll_rc = miner_io_poll_result(&found_nonce, digest, 2000);
        if (poll_rc == 0) {
            /* verify target locally (simple) */
            int valid = 1; /* assume stratum_submit will verify */
            if (valid) {
                if (stratum_submit(job.job_id, found_nonce, digest) == 0) {
                    fprintf(stdout, "[miner] share submitted job=%s nonce=%" PRIu32 "\n", job.job_id, found_nonce);
                } else {
                    fprintf(stderr, "[miner] stratum_submit failed\n");
                }
            }
        } else if (poll_rc == ETIMEDOUT) {
            /* no result in this range */
        } else {
            fprintf(stderr, "miner_io_poll_result error %d\n", poll_rc);
            sleep(1);
        }

        usleep(10000);
    }

    fprintf(stdout, "shutting down\n");
    epoch_watcher_stop();
    miner_io_shutdown();
#ifdef HAVE_STRATUM_DISCONNECT
    stratum_disconnect();
#endif
    return 0;
}
