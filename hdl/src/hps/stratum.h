/*
 * stratum.h - Stratum V1 client interface for the standalone OdoCrypt miner
 *
 * Part of: Autonomous FPGA Miner for OdoCrypt on Cyclone V
 * Layer:   HPS (Linux) software stack
 *
 * Responsibilities:
 *   - Maintain a persistent TCP connection to a mining pool
 *   - Perform the Stratum handshake (subscribe + authorize)
 *   - Parse mining.notify / mining.set_difficulty messages into job_t
 *   - Submit shares (mining.submit) found by the FPGA fabric
 *   - Surface connection state so the daemon can drive reconnect logic
 *
 * This header is transport- and parser-facing only; the actual register
 * programming of the FPGA is handled via hps_regs.h and the daemon.
 */

#ifndef STRATUM_H
#define STRATUM_H

#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include "job.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* Tunables                                                            */
/* ------------------------------------------------------------------ */
#define STRATUM_RECV_BUF      (16 * 1024)  /* line-assembly buffer       */
#define STRATUM_MAX_URL       256
#define STRATUM_MAX_USER      256
#define STRATUM_MAX_PASS      128
#define STRATUM_RECONNECT_SEC 5            /* backoff base               */
#define STRATUM_RPC_TIMEOUT   30           /* seconds to wait for a reply */

/* ------------------------------------------------------------------ */
/* Connection state                                                    */
/* ------------------------------------------------------------------ */
typedef enum {
    STRATUM_DISCONNECTED = 0,
    STRATUM_CONNECTING,
    STRATUM_SUBSCRIBED,
    STRATUM_AUTHORIZED,
    STRATUM_READY,        /* authorized + at least one job received     */
    STRATUM_ERROR
} stratum_state_t;

/* ------------------------------------------------------------------ */
/* Client context                                                      */
/* ------------------------------------------------------------------ */
typedef struct {
    /* pool config */
    char url[STRATUM_MAX_URL];
    char user[STRATUM_MAX_USER];
    char pass[STRATUM_MAX_PASS];
    int  port;

    /* socket / session */
    int  sockfd;
    stratum_state_t state;

    /* subscription artifacts */
    char  session_id[64];
    uint8_t  extranonce1[16];
    size_t   extranonce1_len;
    int      extranonce2_size;

    /* difficulty / target */
    double   difficulty;
    uint8_t  target[32];        /* big-endian 256-bit target            */

    /* current job mirror */
    job_t    current_job;
    bool     have_job;
    bool     clean_jobs;        /* server asked to flush stale work     */

    /* receive line assembler */
    char    rxbuf[STRATUM_RECV_BUF];
    size_t  rxlen;

    /* JSON-RPC id allocation */
    uint64_t next_id;

    /* concurrency */
    pthread_mutex_t lock;
} stratum_ctx_t;

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

/* Initialize a context with pool credentials. Returns 0 on success. */
int  stratum_init(stratum_ctx_t *ctx,
                  const char *url, int port,
                  const char *user, const char *pass);

/* Open TCP connection and perform subscribe + authorize handshake.   */
/* Returns 0 on success, negative errno-style code on failure.        */
int  stratum_connect(stratum_ctx_t *ctx);

/* Gracefully close the socket and reset volatile session state.      */
void stratum_disconnect(stratum_ctx_t *ctx);

/* Release any resources held by the context.                         */
void stratum_destroy(stratum_ctx_t *ctx);

/* ------------------------------------------------------------------ */
/* Message pump                                                        */
/* ------------------------------------------------------------------ */

/* Block (up to timeout_ms) reading socket data and dispatch any      */
/* complete JSON-RPC lines. Updates current_job / difficulty / state. */
/* Returns: >0 messages handled, 0 timeout, <0 socket error.          */
int  stratum_poll(stratum_ctx_t *ctx, int timeout_ms);

/* Copy the most recent job into *out. Returns true if a fresh job is */
/* available since the last call (consumes the "have_job" flag).      */
bool stratum_get_job(stratum_ctx_t *ctx, job_t *out);

/* ------------------------------------------------------------------ */
/* Share submission                                                    */
/* ------------------------------------------------------------------ */

/* Submit a found nonce for the given job. ntime/extranonce2 are the  */
/* hex strings echoed back to the pool. Returns 0 if the submit line  */
/* was written to the socket (acceptance is async via stratum_poll).  */
int  stratum_submit(stratum_ctx_t *ctx,
                    const job_t *job,
                    uint32_t nonce,
                    const char *ntime_hex,
                    const char *extranonce2_hex);

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

/* Convert pool difficulty into a 256-bit big-endian target.          */
void stratum_diff_to_target(double diff, uint8_t target_out[32]);

/* Human-readable state name for logging.                             */
const char *stratum_state_str(stratum_state_t s);

#ifdef __cplusplus
}
#endif

#endif /* STRATUM_H */
