#ifndef EPOCH_WATCHER_H
#define EPOCH_WATCHER_H

#include <stdint.h>

/*
 * Callback: return the current OdoCrypt epoch number (block_height / 2048),
 * or UINT32_MAX if the epoch is unknown.  Must be fast and non-blocking.
 */
typedef uint32_t (*epoch_getter_t)(void *ctx);

/* Start the epoch watcher thread.  getter and getter_ctx must remain valid
 * until epoch_watcher_stop() returns.  poll_seconds controls how often the
 * getter is called.  Returns 0 on success, -1 on failure. */
int epoch_watcher_start(epoch_getter_t getter, void *getter_ctx,
                        unsigned poll_seconds);

/* Stop the watcher thread and block until it exits. */
void epoch_watcher_stop(void);

/* Return the last successfully loaded epoch, or UINT32_MAX if none. */
uint32_t epoch_watcher_current_epoch(void);

#endif /* EPOCH_WATCHER_H */
