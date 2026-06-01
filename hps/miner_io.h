#ifndef MINER_IO_H
#define MINER_IO_H

#include <stdint.h>
#include <stddef.h>

/* Initialize the miner IO layer.
 * If uio_dev is NULL, uses "/dev/uio0".
 * Returns 0 on success, negative errno on failure.
 */
int miner_io_init(const char *uio_dev);

/* Convenience default initializer (uses /dev/uio0) */
static inline int miner_io_init_default(void) { return miner_io_init(NULL); }

/* Dispatch a header and nonce range to the FPGA.
 * header: pointer to header bytes (typically 80 bytes)
 * header_len: length in bytes of header (<= 256)
 * nonce_start: starting nonce (u32)
 * nonce_count: number of nonces to test
 * Returns 0 on success, negative errno on failure.
 */
int miner_io_dispatch_range(const uint8_t *header, size_t header_len,
                            uint32_t nonce_start, uint32_t nonce_count);

/* Poll for a result from FPGA.
 * On success (return 0) writes found nonce to out_nonce and 32-byte digest to out_digest.
 * If no result in the timeout, returns >0 (timeout).
 * On error returns negative errno.
 */
int miner_io_poll_result(uint32_t *out_nonce, uint8_t out_digest[32], uint32_t timeout_ms);

/* Graceful shutdown and resource release */
void miner_io_shutdown(void);

#endif /* MINER_IO_H */