/* hps/epoch_watcher.c
 *
 * Epoch watcher thread for odo-miner-cyclonev HPS.
 *
 * This module polls a user-supplied "epoch getter" callback at a configurable
 * interval. When a new epoch is observed it calls odo_fpga_load_epoch(epoch,
 * epoch_data, epoch_words) to load the epoch into the FPGA. An optional
 * "epoch data getter" callback may provide the epoch table bytes; if NULL
 * the loader is called with NULL data and is expected to obtain the data
 * itself.
 *
 * API:
 *   int epoch_watcher_start(epoch_getter_t getter, void *getter_ctx,
 *                           epoch_data_getter_t data_getter, void *data_ctx,
 *                           unsigned poll_seconds);
 *   void epoch_watcher_stop(void);
 *
 * Callbacks should be fast/non-blocking. If loading is slow the watcher will
 * block until odo_fpga_load_epoch returns.
 */

#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>
#include <inttypes.h>
#include <string.h>

#include "odocrypt_state.h" /* int odo_fpga_load_epoch(uint32_t epoch, const void *epoch_data, size_t epoch_words); */

/* Callback types */
typedef uint32_t (*epoch_getter_t)(void *ctx);
/* If data_getter returns >0 it must set *out_epoch_data to a malloc'd buffer of
 * (returned_words * 4) bytes. The watcher will free the buffer after calling
 * odo_fpga_load_epoch. If it returns 0 it indicates "no data provided" and the
 * watcher will pass NULL to odo_fpga_load_epoch.
 */
typedef size_t (*epoch_data_getter_t)(uint32_t epoch, void **out_epoch_data, void *ctx);

/* Internal state */
static pthread_t g_thread;
static atomic_int g_running = 0;
static unsigned g_poll_seconds = 5;
static epoch_getter_t g_getter = NULL;
static void *g_getter_ctx = NULL;
static epoch_data_getter_t g_data_getter = NULL;
static void *g_data_ctx = NULL;
static pthread_mutex_t g_state_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_last_epoch = UINT32_MAX;

static void log_info(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fprintf(stdout, "[epoch_watcher] "); vfprintf(stdout, fmt, ap); fprintf(stdout, "\n");
    va_end(ap);
}
static void log_warn(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[epoch_watcher] WARN: "); vfprintf(stderr, fmt, ap); fprintf(stderr, "\n");
    va_end(ap);
}

static void *watcher_thread(void *arg) {
    (void)arg;
    while (atomic_load(&g_running)) {
        uint32_t epoch = UINT32_MAX;
        if (g_getter) epoch = g_getter(g_getter_ctx);

        if (epoch != UINT32_MAX) {
            pthread_mutex_lock(&g_state_lock);
            uint32_t last = g_last_epoch;
            pthread_mutex_unlock(&g_state_lock);

            if (epoch != last) {
                log_info("Detected epoch change: %