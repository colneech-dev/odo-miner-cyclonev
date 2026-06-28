/*
 * stratum.h - Stratum V1 client interface for the standalone OdoCrypt miner
 */

#ifndef STRATUM_H
#define STRATUM_H

#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include "job.h"

#define STRATUM_RECV_BUF      (16 * 1024)
#define STRATUM_MAX_URL       256
#define STRATUM_MAX_USER      256
#define STRATUM_MAX_PASS      128
#define STRATUM_MAX_JOBID     64

/* Force a reconnect if the pool sends NOTHING (no notify, no keepalive) for
 * this long while the socket still looks open — catches a silently half-dead
 * TCP connection that would otherwise go unnoticed until the next share submit
 * fails. Pools normally re-notify well within a minute. */
#define STRATUM_IDLE_TIMEOUT  120

/* In-flight mining.submit request ids awaiting a result. Bounds the memory for
 * accept/reject correlation; if more than this many submits are outstanding the
 * oldest is dropped (its result simply goes uncounted). */
#define STRATUM_MAX_PENDING_SUBMITS  64

typedef enum {
    STRATUM_DISCONNECTED = 0,
    STRATUM_CONNECTING,
    STRATUM_SUBSCRIBED,
    STRATUM_AUTHORIZED,
    STRATUM_READY,
    STRATUM_ERROR
} stratum_state_t;

typedef struct {
    char host[STRATUM_MAX_URL];
    char port[32];
    char user[STRATUM_MAX_USER];
    char pass[STRATUM_MAX_PASS];

    int fd;
    stratum_state_t state;

    bool subscribed;
    bool authorized;

    uint8_t extranonce1[32];
    size_t  extranonce1_len;
    int     extranonce2_size;
    uint64_t extranonce2_counter; /* incremented once per job */

    double   difficulty;     /* last mining.set_difficulty (0 = none yet) */
    uint32_t odo_interval;   /* OdoCrypt shapechange interval in seconds
                                (864000 mainnet, 86400 testnet) */

    job_t current_job;
    bool  have_job;

    char rxbuf[STRATUM_RECV_BUF];
    size_t rxlen;
    int    resync;           /* 1 = an oversized line was dropped; skip the
                              * remaining tail up to the next newline (M1) */

    time_t last_rx;          /* time() of the last bytes received from the pool;
                                0 until the first successful connect. Drives the
                                STRATUM_IDLE_TIMEOUT dead-pool watchdog. */

    /* Pool-confirmed share accounting (H3): mining.submit ids awaiting a
     * result, and the accept/reject tallies once results arrive. Distinct from
     * the daemon's "submitted" count (socket-write success) — these reflect
     * what the pool actually acknowledged. */
    uint64_t pending_submits[STRATUM_MAX_PENDING_SUBMITS];
    int      n_pending_submits;
    uint64_t shares_accepted;
    uint64_t shares_rejected;

    uint64_t next_id;
} stratum_ctx_t;

int  stratum_init(stratum_ctx_t *ctx,
                  const char *host,
                  const char *port,
                  const char *user,
                  const char *pass);
int  stratum_connect(stratum_ctx_t *ctx);
int  stratum_poll(stratum_ctx_t *ctx, int timeout_ms);
void stratum_disconnect(stratum_ctx_t *ctx);
void stratum_destroy(stratum_ctx_t *ctx);

bool stratum_get_job(stratum_ctx_t *ctx, job_t *out);
int  stratum_submit_share(stratum_ctx_t *ctx,
                          const job_t *job,
                          uint32_t nonce);

/* Pool-confirmed share tallies (accept/reject correlated to mining.submit
 * results by request id). Either out pointer may be NULL. */
void stratum_share_stats(const stratum_ctx_t *ctx,
                         uint64_t *accepted, uint64_t *rejected);

const char *stratum_state_str(stratum_state_t state);

#endif /* STRATUM_H */
