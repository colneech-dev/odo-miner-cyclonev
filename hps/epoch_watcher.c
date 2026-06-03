/*
 * epoch_watcher.c — background thread that tracks OdoCrypt epoch changes
 *
 * Polls a caller-supplied epoch-getter callback at a configurable interval.
 * When a new epoch is detected it calls miner_io_load_epoch() to stream the
 * freshly generated tables to the FPGA automatically.
 *
 * API:
 *   int  epoch_watcher_start(epoch_getter_t getter, void *ctx,
 *                            unsigned poll_seconds);
 *   void epoch_watcher_stop(void);
 *
 * The getter callback must be fast and non-blocking — it is called from the
 * watcher thread at every poll interval.  Return UINT32_MAX to indicate
 * "epoch unknown" (no load will be triggered).
 */

#define _POSIX_C_SOURCE 200809L

#include "epoch_watcher.h"
#include "miner_io.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>
#include <inttypes.h>

/* -----------------------------------------------------------------------
 * Internal state
 * ---------------------------------------------------------------------- */
static pthread_t        g_thread;
static atomic_int       g_running    = 0;
static unsigned         g_poll_sec   = 5;
static epoch_getter_t   g_getter     = NULL;
static void            *g_getter_ctx = NULL;
static pthread_mutex_t  g_lock       = PTHREAD_MUTEX_INITIALIZER;
static uint32_t         g_last_epoch = UINT32_MAX;

/* -----------------------------------------------------------------------
 * Logging (prefixed for easy log filtering)
 * ---------------------------------------------------------------------- */
static void ew_log(const char *level, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stdout, "[epoch_watcher] %s: ", level);
    vfprintf(stdout, fmt, ap);
    fprintf(stdout, "\n");
    fflush(stdout);
    va_end(ap);
}
#define LOG_INFO(...)  ew_log("INFO",  __VA_ARGS__)
#define LOG_WARN(...)  ew_log("WARN",  __VA_ARGS__)
#define LOG_ERROR(...) ew_log("ERROR", __VA_ARGS__)

/* -----------------------------------------------------------------------
 * Watcher thread
 * ---------------------------------------------------------------------- */
static void *watcher_thread(void *arg)
{
    (void)arg;

    while (atomic_load(&g_running)) {
        /* Ask the getter for the current epoch */
        uint32_t epoch = UINT32_MAX;
        if (g_getter)
            epoch = g_getter(g_getter_ctx);

        if (epoch != UINT32_MAX) {
            pthread_mutex_lock(&g_lock);
            uint32_t last = g_last_epoch;
            pthread_mutex_unlock(&g_lock);

            if (epoch != last) {
                LOG_INFO("epoch change %" PRIu32 " -> %" PRIu32 "; loading tables",
                         last, epoch);

                /* Stop the core while loading */
                miner_io_stop();

                int rc = miner_io_load_epoch(epoch);
                if (rc == 0) {
                    pthread_mutex_lock(&g_lock);
                    g_last_epoch = epoch;
                    pthread_mutex_unlock(&g_lock);
                    LOG_INFO("epoch %" PRIu32 " loaded successfully", epoch);
                    /* Restart — caller's dispatch loop will pick up the next job */
                    miner_io_start();
                } else {
                    LOG_ERROR("miner_io_load_epoch(%" PRIu32 ") failed: %d", epoch, rc);
                }
            }
        }

        /* Sleep in 1-second steps so stop() is responsive */
        for (unsigned i = 0; i < g_poll_sec && atomic_load(&g_running); i++)
            sleep(1);
    }

    LOG_INFO("thread exiting");
    return NULL;
}

/* -----------------------------------------------------------------------
 * Public API
 * ---------------------------------------------------------------------- */

int epoch_watcher_start(epoch_getter_t getter, void *getter_ctx,
                        unsigned poll_seconds)
{
    if (!getter) return -1;
    if (atomic_load(&g_running)) return -1;  /* already running */

    g_getter     = getter;
    g_getter_ctx = getter_ctx;
    g_poll_sec   = poll_seconds > 0 ? poll_seconds : 5;
    g_last_epoch = UINT32_MAX;

    atomic_store(&g_running, 1);
    if (pthread_create(&g_thread, NULL, watcher_thread, NULL) != 0) {
        atomic_store(&g_running, 0);
        return -1;
    }

    LOG_INFO("started (poll interval %u s)", g_poll_sec);
    return 0;
}

void epoch_watcher_stop(void)
{
    if (!atomic_load(&g_running)) return;
    atomic_store(&g_running, 0);
    pthread_join(g_thread, NULL);
    LOG_INFO("stopped");
}

uint32_t epoch_watcher_current_epoch(void)
{
    pthread_mutex_lock(&g_lock);
    uint32_t e = g_last_epoch;
    pthread_mutex_unlock(&g_lock);
    return e;
}
