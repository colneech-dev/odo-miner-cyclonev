/* miner.c
 *
 * High-level mining control loop for odo-miner-cyclonev HPS.
 *
 * Responsibilities:
 *  - Connect to stratum server and receive jobs
 *  - Ensure FPGA epoch tables are loaded when epoch changes
 *  - Dispatch nonce ranges to FPGA via miner_io
 *  - Poll FPGA for results and submit valid shares
 *  - Graceful shutdown on signals
 *
 * Integration notes:
 *  - Expects existing headers: stratum.h, miner_io.h, odocrypt_state.h, job.h
 *  - Where signatures differ, adapt the calls in dispatch/poll/epoch load areas.
 *
 * Build:
 *  - Add to existing HPS Makefile: hps/miner.c -> compiled into main miner binary
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>
#include <inttypes.h>

/* Project headers (adapt as needed) */
#include "stratum.h"         /* stratum_connect(), stratum_wait_job(), stratum_submit() */
#include "miner_io.h"        /* miner_io_init(), miner_io_dispatch_range(), miner_io_poll_result() */
#include "odocrypt_state.h"  /* odo_fpga_load_epoch() */
#include "job.h"             /* job_t structure (header, target, epoch, job_id, ...) */

/* --- Fallback minimal definitions if project headers differ --- */
/* Remove or adapt these if the real headers are present. */
#ifndef JOB_H
typedef struct {
    uint8_t header[80];    /* block header (up to 80 bytes) */
    uint8_t target[32];    /* target / difficulty bytes (big-endian) */
    uint32_t epoch;        /* epoch number for odocrypt */
    char job_id[64];       /* job identifier string */
    uint32_t extra_nonce;  /* extra nonce or nonce prefix */
} job_t;
#endif

#ifndef MINER_IO_H
/* miner_io functions (expected, adapt names if different) */
int miner_io_init(void);
int miner_io_dispatch_range(const uint8_t *header, uint32_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count);
int miner_io_poll_result(uint32_t *out_nonce, uint8_t *out_digest /* 32 bytes */, uint32_t timeout_ms);
#endif

#ifndef STRATUM_H
int stratum_connect(const char *url);
int stratum_wait_job(job_t *out_job); /* blocks until job available, or returns <=0 on error */
int stratum_submit(const char *job_id, uint32_t nonce, const uint8_t *digest);
#endif

#ifndef ODOCrypt_STATE_H
int odo_fpga_load_epoch(uint32_t epoch, const void *epoch_data, size_t epoch_words);
#endif

/* --- Configuration constants --- */
#define NONCE_RANGE_SIZE 1000000U    /* nonces to dispatch per batch (tune to FPGA geometry) */
#define POLL_TIMEOUT_MS 2000U        /* timeout for FPGA result polling */
#define EPOCH_LOAD_TIMEOUT_S 10      /* seconds to wait after epoch load */
#define HEARTBEAT_INTERVAL_S 5       /* log heartbeat interval */

/* --- Global runtime flags --- */
static volatile sig_atomic_t g_terminate = 0;
static pthread_mutex_t g_epoch_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_current_epoch = UINT32_MAX; /* unknown at startup */

/* --- Simple logging helpers --- */
static void log_info(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stdout, "[INFO] ");
    vfprintf(stdout, fmt, ap);
    fprintf(stdout, "\n");
    va_end(ap);
}
static void log_warn(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[WARN] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}
static void log_error(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[ERROR] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

/* --- Signal handling --- */
static void handle_signal(int sig) {
    (void)sig;
    g_terminate = 1;
}

/* --- Target check: compare 32-byte digest (big-endian) vs target (big-endian).
 * Returns 1 if digest <= target (i.e., valid), 0 otherwise.
 */
static int check_target_le(const uint8_t digest[32], const uint8_t target[32]) {
    for (int i = 0; i < 32; ++i) {
        if (digest[i] < target[i]) return 1;
        if (digest[i] > target[i]) return 0;
    }
    /* Equal counts as valid */
    return 1;
}

/* --- Load epoch tables into FPGA if epoch changed.
 * This wraps odo_fpga_load_epoch() and protects against concurrent loads.
 * epoch_data pointer and epoch_words are project-specific; here we expect
 * the caller to provide the epoch image (e.g., from odocrypt_state or disk).
 */
static int load_epoch_if_needed(uint32_t epoch, const void *epoch_data, size_t epoch_words) {
    int rc = 0;
    pthread_mutex_lock(&g_epoch_lock);
    if (g_current_epoch != epoch) {
        log_info("Epoch change detected: %" PRIu32 " -> %" PRIu32, g_current_epoch, epoch);
        /* Call into odocrypt state loader: adapt signature as needed */
        rc = odo_fpga_load_epoch(epoch, epoch_data, epoch_words);
        if (rc == 0) {
            g_current_epoch = epoch;
            log_info("Epoch %" PRIu32 " loaded successfully", epoch);
            /* Give FPGA a short time to stabilize/commit */
            sleep(EPOCH_LOAD_TIMEOUT_S);
        } else {
            log_error("Failed to load epoch %" PRIu32 " (rc=%d)", epoch, rc);
        }
    }
    pthread_mutex_unlock(&g_epoch_lock);
    return rc;
}

/* --- Simple nonce allocator: returns successive ranges on each call.
 * This is a single-threaded incrementing allocator. For multi-FPGA/core setups
 * replace with per-core allocation or atomic counters in shared memory.
 */
typedef struct {
    uint32_t next_nonce;
} nonce_allocator_t;

static void nonce_alloc_init(nonce_allocator_t *a, uint32_t start) {
    a->next_nonce = start;
}

static uint32_t nonce_alloc_get(nonce_allocator_t *a, uint32_t *out_count) {
    uint32_t start = a->next_nonce;
    uint32_t n = NONCE_RANGE_SIZE;
    /* wrap-around guard (simple) */
    if (start + n < start) { /* overflow */
        start = 0;
        a->next_nonce = n;
    } else {
        a->next_nonce = start + n;
    }
    *out_count = n;
    return start;
}

/* --- Main control loop */
int main(int argc, char **argv) {
    (void)argc; (void)argv;
    int rc;

    /* Setup signals */
    struct sigaction sa = {0};
    sa.sa_handler = handle_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    log_info("Starting odo-miner HPS controller");

    /* Initialize miner I/O (FPGA bridge / UIO / device) */
    rc = miner_io_init();
    if (rc != 0) {
        log_error("miner_io_init failed: %d", rc);
        return 1;
    }
    log_info("miner_io initialized");

    /* Connect to stratum */
    const char *stratum_url = getenv("STRATUM_URL");
    if (!stratum_url) stratum_url = "stratum+tcp://127.0.0.1:3333"; /* default test */
    rc = stratum_connect(stratum_url);
    if (rc != 0) {
        log_error("stratum_connect failed (%s): %d", stratum_url, rc);
        /* proceed in offline/test mode or exit — here we exit */
        return 2;
    }
    log_info("Connected to stratum server %s", stratum_url);

    /* Epoch state preload (optional): attempt to load epoch 0 / current known epoch */
    /* TODO: Replace with code to fetch epoch_data from odocrypt_state module or disk.
     * For now we assume odo_fpga_load_epoch() can handle NULL / on-demand loads.
     */
    uint32_t initial_epoch = 0;
    rc = load_epoch_if_needed(initial_epoch, NULL, 0);
    if (rc != 0) {
        log_warn("Initial epoch load returned %d; continuing (may be handled later)", rc);
    }

    /* Nonce allocator */
    nonce_allocator_t alloc;
    nonce_alloc_init(&alloc, 0);

    /* Main loop: wait for job -> dispatch -> poll results -> submit */
    job_t job;
    time_t last_heartbeat = time(NULL);

    while (!g_terminate) {
        /* Heartbeat log */
        time_t now = time(NULL);
        if ((now - last_heartbeat) >= HEARTBEAT_INTERVAL_S) {
            log_info("Heartbeat: epoch=%" PRIu32 " next_nonce=%" PRIu32,
                     g_current_epoch, alloc.next_nonce);
            last_heartbeat = now;
        }

        /* Block until we have a job */
        memset(&job, 0, sizeof(job));
        rc = stratum_wait_job(&job);
        if (rc <= 0) {
            if (g_terminate) break;
            /* stratum_wait_job failed or timed out; sleep briefly and retry */
            log_warn("stratum_wait_job returned %d; retrying in 1s", rc);
            sleep(1);
            continue;
        }

        log_info("Received job id='%s' epoch=%" PRIu32, job.job_id, job.epoch);

        /* Ensure epoch loaded */
        /* TODO: get epoch_data & epoch_words from odocrypt_state for job.epoch */
        rc = load_epoch_if_needed(job.epoch, NULL, 0);
        if (rc != 0) {
            log_warn("Failed to ensure epoch %" PRIu32 " loaded; skipping job", job.epoch);
            continue;
        }

        /* Dispatch a nonce range to FPGA */
        uint32_t nonce_count = 0;
        uint32_t nonce_start = nonce_alloc_get(&alloc, &nonce_count);

        log_info("Dispatching nonce range start=%" PRIu32 " count=%" PRIu32, nonce_start, nonce_count);

        /* Header length may vary; using 80 by default */
        rc = miner_io_dispatch_range(job.header, sizeof(job.header), nonce_start, nonce_count);
        if (rc != 0) {
            log_error("miner_io_dispatch_range failed: %d; will retry later", rc);
            /* back off a bit */
            sleep(1);
            continue;
        }

        /* Poll FPGA for results until timeout or until g_terminate */
        uint32_t found_nonce = 0;
        uint8_t found_digest[32] = {0};
        rc = miner_io_poll_result(&found_nonce, found_digest, POLL_TIMEOUT_MS);
        if (rc == 0) {
            /* Got a result — check target and submit */
            log_info("FPGA result nonce=%" PRIu32, found_nonce);
            if (check_target_le(found_digest, job.target)) {
                log_info("Result meets target; submitting share job_id=%s nonce=%" PRIu32, job.job_id, found_nonce);
int submit_rc = stratum_submit(job.job_id, found_nonce, found_digest);
            if (submit_rc == 0) {
                log_info("Share submitted successfully (job=%s nonce=%" PRIu32 ")", job.job_id, found_nonce);
            } else {
                log_warn("stratum_submit failed (rc=%d) for job=%s nonce=%" PRIu32, submit_rc, job.job_id, found_nonce);
            }
        } else {
            log_info("FPGA result did not meet target; ignoring (nonce=%" PRIu32 ")", found_nonce);
        }
    } else if (rc > 0) {
        /* rc > 0 indicates poll timeout / no result in this range */
        log_info("No result from FPGA for nonce range start=%" PRIu32 " (timeout)", nonce_start);
    } else {
        /* rc < 0 indicates an I/O or internal error from miner_io_poll_result */
        log_error("miner_io_poll_result error (rc=%d); will retry later", rc);
        sleep(1);
    }

    /* brief yield to avoid tight loop; adjust as appropriate for throughput */
    if (!g_terminate) usleep(10000); /* 10 ms */
} /* end main while */

log_info("Termination requested, shutting down");

/* Optional cleanup hooks - adapt to real project APIs if present */

#ifdef HAVE_STRATUM_DISCONNECT stratum_disconnect(); #endif #ifdef HAVE_MINER_IO_SHUTDOWN miner_io_shutdown(); #endif

log_info("odo-miner HPS controller exited cleanly");
return 0;
}