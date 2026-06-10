/*
 * miner_io.h — FPGA MMIO bridge API for the odo-miner-cyclonev HPS
 *
 * The implementation (miner_io.c) uses /dev/mem to reach the FPGA register
 * block via the LWH2F bridge at 0xFF200000.  A UIO alternative is available
 * in miner_io_uio.c.
 *
 * Typical call sequence:
 *
 *   miner_io_init(NULL);                    // open /dev/mem, mmap LWH2F
 *   miner_io_load_epoch(epoch_key);         // stream epoch tables to FPGA
 *
 *   // For each new stratum job:
 *   miner_io_dispatch_job(hdr, 80, target, nonce_start, nonce_count);
 *
 *   // Poll loop:
 *   uint32_t nonce;  uint8_t hash[32];
 *   int rc = miner_io_poll_result(&nonce, hash, 2000);
 *   if (rc == 0) { ... submit share ... }
 *
 *   miner_io_shutdown();
 */

#ifndef MINER_IO_H
#define MINER_IO_H

#include <stdint.h>
#include <stddef.h>
#include "odocrypt_state.h"  /* for odo_epoch_state_t used by load_epoch */

#ifdef __cplusplus
extern "C" {
#endif

/* -----------------------------------------------------------------------
 * Lifecycle
 * ---------------------------------------------------------------------- */

/*
 * Open /dev/mem and mmap the FPGA register window.
 * dev is ignored (reserved for future UIO path); pass NULL.
 * Returns 0 on success, negative errno on failure.
 */
int miner_io_init(const char *dev);

/* Release mmap and close file descriptor. Safe to call on an uninitialised handle. */
void miner_io_shutdown(void);

/* -----------------------------------------------------------------------
 * Epoch loading
 * ---------------------------------------------------------------------- */

/*
 * Generate OdoCrypt tables for epoch_key and stream them to the FPGA.
 * Blocks until STATUS.TABLES_VALID is set.
 * Must be called before the first dispatch, and again on each epoch change.
 * Returns 0 on success, -ETIMEDOUT if the FPGA does not acknowledge.
 */
int miner_io_load_epoch(uint32_t epoch_key);

/* -----------------------------------------------------------------------
 * Job dispatch
 * ---------------------------------------------------------------------- */

/*
 * Write a complete mining job and start the FPGA hashing core.
 *
 * header     : 80-byte OdoCrypt block header (nonce field zeroed; FPGA sweeps it).
 * header_len : must be 80.
 * target     : 32-byte little-endian difficulty target (LE uint256, same
 *              byte order as job_t.share_target), or NULL to accept any hash.
 * nonce_start: first nonce value.
 * nonce_count: number of nonces to sweep (end = start + count - 1).
 * Returns 0 on success, -EAGAIN if an unread FOUND result is still latched
 * (caller must consume it via miner_io_check_result first).
 */
int miner_io_dispatch_job(const uint8_t *header, size_t header_len,
                          const uint8_t *target,
                          uint32_t nonce_start, uint32_t nonce_count);

/*
 * Convenience wrapper: dispatch without an explicit target (accepts any hash).
 * Matches the simpler miner_io API used by existing callers.
 */
int miner_io_dispatch_range(const uint8_t *header, size_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count);

/* -----------------------------------------------------------------------
 * Result polling
 * ---------------------------------------------------------------------- */

/*
 * Non-blocking result check.
 *
 * Returns:
 *   0         — nonce found; *out_nonce filled; out_hash (32 B) filled if
 *               non-NULL; FOUND latch cleared.
 *   1         — core idle, nonce range exhausted without a find.
 *   EAGAIN    — core still hashing.
 *   negative  — I/O error.
 */
int miner_io_check_result(uint32_t *out_nonce, uint8_t out_hash[32]);

/*
 * Wait up to timeout_ms for the FPGA to finish.
 *
 * Returns:
 *   0         — nonce found; *out_nonce filled; out_hash (32 B) filled if non-NULL.
 *   1         — range exhausted without a find (core idle).
 *   ETIMEDOUT — core still busy after timeout_ms.
 *   negative  — I/O error.
 *
 * Clears the FOUND latch on success so the next dispatch starts clean.
 * out_hash receives the 32-byte Keccak PoW hash from the HASH registers.
 */
int miner_io_poll_result(uint32_t *out_nonce, uint8_t out_hash[32],
                         uint32_t timeout_ms);

/* -----------------------------------------------------------------------
 * Core control
 * ---------------------------------------------------------------------- */

void     miner_io_stop(void);    /* halt hashing (registers preserved) */
void     miner_io_start(void);   /* resume with current registers */
uint32_t miner_io_status(void);  /* raw STATUS register value */

/*
 * Read the FPGA performance counters.
 * hashes      : total hashes computed since configuration (64-bit)
 * shares      : FOUND events latched since configuration
 * uptime_ticks: fabric clock ticks since configuration (wraps at 2^32)
 * Any pointer may be NULL. Returns 0, or -ENODEV if the bridge is closed.
 */
int miner_io_read_perf(uint64_t *hashes, uint32_t *shares, uint32_t *uptime_ticks);

#ifdef __cplusplus
}
#endif

#endif /* MINER_IO_H */
