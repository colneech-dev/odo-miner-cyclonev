/*
 * miner_io_pipe.h — FPGA MMIO bridge for the PIPELINED OdoCrypt miner.
 *
 * Counterpart to miner_io.h (sequential FSM). The pipelined core bakes the
 * epoch into the bitstream and free-runs, so there is NO epoch-table streaming
 * and NO nonce range: write the header + share target, commit, then poll for
 * found nonces (read-to-consume). Register contract: hps_regs_pipe.h.
 *
 * Typical use:
 *   miner_io_pipe_init();
 *   uint32_t epoch = miner_io_pipe_seed();   // verify bitstream matches job
 *   miner_io_pipe_dispatch(job->header, job->share_target);  // on each job
 *   uint32_t nonce;
 *   while (miner_io_pipe_poll(&nonce) == 0) { ... validate + submit ... }
 *   miner_io_pipe_shutdown();
 */
#ifndef MINER_IO_PIPE_H
#define MINER_IO_PIPE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Open /dev/mem and mmap the LWH2F window. 0 on success, <0 on error. */
int  miner_io_pipe_init(void);
void miner_io_pipe_shutdown(void);

/* Baked-in epoch (ODOKEY) of the loaded bitstream — verify against the job's
 * epoch; a mismatch means the FPGA must be reconfigured (Phase 2). */
uint32_t miner_io_pipe_seed(void);
uint32_t miner_io_pipe_version(void);

/* Snapshot a job into the miner: write the 19 header words (bytes 0..75; the
 * core sweeps bytes 76..79 as the nonce) + 8 target words, then COMMIT.
 * header is the 80-byte block header; target is the 32-byte LE share target.
 * Returns 0 on success, <0 if the bridge is closed. */
int  miner_io_pipe_dispatch(const uint8_t header[80], const uint8_t target[32]);

/* Pop one found nonce. 0 = found (*out_nonce set, entry consumed),
 * 1 = none pending, <0 = error. */
int  miner_io_pipe_poll(uint32_t *out_nonce);

/* Block until the FPGA signals a found nonce, or until timeout_ms elapses.
 * Lets the daemon stop fixed-interval polling: the UIO backend sleeps on the
 * hardware interrupt (f2h_irq0 line 3 = the wrapper's found_valid level); the
 * /dev/mem backend has no interrupt and falls back to a short bounded nap.
 *
 * timeout_ms MUST bound the wait so a missing/stuck IRQ degrades to polling
 * rather than hanging the daemon under the watchdog (never infinite — see
 * docs/uio-miner-io-scope.md risk #3); a negative value is treated as a sane
 * default cap, not "wait forever". After any return, drain with
 * miner_io_pipe_poll() until it returns 1.
 *
 * Returns: 0 = woken (a nonce is likely pending — drain now),
 *          1 = timed out (drain defensively anyway),
 *         <0 = error. */
int  miner_io_pipe_wait(int timeout_ms);

#ifdef __cplusplus
}
#endif

#endif /* MINER_IO_PIPE_H */
