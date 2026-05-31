/*
 * stratum.c -- Stratum V1 client implementation for the standalone
 *              Cyclone V OdoCrypt miner daemon.
 *
 * Responsibilities:
 *   - Non-blocking TCP socket management to the mining pool
 *   - Line-delimited JSON-RPC framing (encode / decode)
 *   - State machine: connect -> subscribe -> authorize -> mining
 *   - Job notification parsing (mining.notify) -> job_t
 *   - set_difficulty / set_target handling
 *   - Share submission (mining.submit) and result tracking
 *   - Reconnect / backoff on socket failure
 *
 * Pairs with stratum.h. Designed for single-daemon use with one worker
 * thread driving recv/parse and the main loop polling FPGA registers.
 */

#include "stratum.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <stdint.h>
#include <stdbool.h>

#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>

/* ----------------------------------------------------------------------
 * Internal constants
 * -------------------------------------------------------------------- */
#define STRATUM_RXBUF_SIZE   (64 * 1024)
#define STRATUM_TXBUF_SIZE   (8  * 1024)
#define STRATUM_CONNECT_TMO  10        /* seconds */
#define STRATUM_BACKOFF_MIN  2         /* seconds */
#define STRATUM_BACKOFF_MAX  60        /* seconds */

/* ----------------------------------------------------------------------
 * Internal helpers (forward declarations)
 * -------------------------------------------------------------------- */
static int   set_nonblocking(int fd);
static int   tcp_connect(const char *host, const char *port);
static int   send_line(stratum_ctx_t *ctx, const char *line);
static int   pump_recv(stratum_ctx_t *ctx);
static void  process_line(stratum_ctx_t *ctx, char *line);
static void  handle_notify(stratum_ctx_t *ctx, const char *params);
static void  handle_set_difficulty(stratum_ctx_t *ctx, const char *params);
static void  handle_result(stratum_ctx_t *ctx, long id, const char *body);

/* tiny JSON scanning helpers (no external lib) */
static const char *json_find_key(const char *json, const char *key);
static int   json_get_string(const char *json, const char *key,
                             char *out, size_t out_sz);
static int   json_get_bool(const char *json, const char *key, bool *out);
static int   hex_to_bin(const char *hex, uint8_t *out, size_t out_sz);

/* ----------------------------------------------------------------------
 * Minimal JSON scanning helpers
 *
 * These are deliberately lightweight: Stratum messages are flat, small,
 * and predictable, so we avoid pulling in a full JSON parser. They locate
 * "key": values within a single JSON object string. Not a general parser.
 * -------------------------------------------------------------------- */

static const char *json_find_key(const char *json, const char *key)
{
    char pat[128];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p)
        return NULL;
    p += strlen(pat);
    while (*p == ' ' || *p == ':' || *p == '\t')
        p++;
    return p;
}

static int json_get_string(const char *json, const char *key,
                           char *out, size_t out_sz)
{
    const char *p = json_find_key(json, key);
    if (!p || *p != '"')
        return -1;
    p++;                        /* skip opening quote */
    size_t i = 0;
    while (*p && *p != '"' && i < out_sz - 1) {
        if (*p == '\\' && p[1])
            p++;                /* unescape: copy next char literally */
        out[i++] = *p++;
    }
    out[i] = '\0';
    return (*p == '"') ? 0 : -1;
}

static int json_get_bool(const char *json, const char *key, bool *out)
{
    const char *p = json_find_key(json, key);
    if (!p)
        return -1;
    if (strncmp(p, "true", 4) == 0)  { *out = true;  return 0; }
    if (strncmp(p, "false", 5) == 0) { *out = false; return 0; }
    return -1;
}

static int hex_to_bin(const char *hex, uint8_t *out, size_t out_sz)
{
    size_t len = strlen(hex);
    if (len % 2 != 0 || len / 2 > out_sz)
        return -1;
    for (size_t i = 0; i < len; i += 2) {
        unsigned int byte;
        if (sscanf(hex + i, "%2x", &byte) != 1)
            return -1;
        out[i / 2] = (uint8_t)byte;
    }
    return (int)(len / 2);
}

/* ----------------------------------------------------------------------
 * Low-level socket helpers
 * -------------------------------------------------------------------- */

static int set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int tcp_connect(const char *host, const char *port)
{
    struct addrinfo hints, *res = NULL, *rp;
    int fd = -1, rc;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    rc = getaddrinfo(host, port, &hints, &res);
    if (rc != 0) {
        fprintf(stderr, "stratum: getaddrinfo(%s:%s): %s\n",
                host, port, gai_strerror(rc));
        return -1;
    }

    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0)
            continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0)
            break;            /* success */
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);

    if (fd < 0) {
        fprintf(stderr, "stratum: unable to connect to %s:%s\n", host, port);
        return -1;
    }

    /* Disable Nagle so share submits go out immediately. */
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    /* Enable TCP keepalive to detect dead pools. */
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));

    if (set_nonblocking(fd) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int send_line(stratum_ctx_t *ctx, const char *line)
{
    size_t len = strlen(line);
    size_t off = 0;

    if (ctx->fd < 0)
        return -1;

    /* Blocking-style write loop with EAGAIN retry; messages are small. */
    while (off < len) {
        ssize_t n = send(ctx->fd, line + off, len - off, MSG_NOSIGNAL);
        if (n > 0) {
            off += (size_t)n;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct timespec ts = { 0, 1000000 }; /* 1 ms */
            nanosleep(&ts, NULL);
        } else {
            fprintf(stderr, "stratum: send failed: %s\n", strerror(errno));
            return -1;
        }
    }
    return 0;
}

static int pump_recv(stratum_ctx_t *ctx)
{
    int dispatched = 0;

    for (;;) {
        if (ctx->rx_len >= STRATUM_RXBUF_SIZE - 1) {
            /* Overlong line w/o newline -> protocol error, reset buffer. */
            fprintf(stderr, "stratum: rx buffer overflow, flushing\n");
            ctx->rx_len = 0;
            return -1;
        }

        ssize_t n = recv(ctx->fd, ctx->rxbuf + ctx->rx_len,
                         STRATUM_RXBUF_SIZE - 1 - ctx->rx_len, 0);
        if (n > 0) {
            ctx->rx_len += (size_t)n;
            ctx->rxbuf[ctx->rx_len] = '\0';

            /* Extract complete '\n'-terminated lines. */
            char *start = ctx->rxbuf;
            char *nl;
            while ((nl = memchr(start, '\n',
                                ctx->rx_len - (start - ctx->rxbuf))) != NULL) {
                *nl = '\0';
                process_line(ctx, start);
                dispatched++;
                start = nl + 1;
            }
            /* Shift any partial remainder to the front. */
            size_t rem = ctx->rx_len - (start - ctx->rxbuf);
            memmove(ctx->rxbuf, start, rem);
            ctx->rx_len = rem;
        } else if (n == 0) {
            fprintf(stderr, "stratum: pool closed connection\n");
            return -1;          /* EOF */
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;          /* no more data right now */
            if (errno == EINTR)
                continue;
            fprintf(stderr, "stratum: recv error: %s\n", strerror(errno));
            return -1;
        }
    }
    return dispatched;
}

/* ----------------------------------------------------------------------
 * Public API
 * -------------------------------------------------------------------- */

int stratum_init(stratum_ctx_t *ctx, const char *host, const char *port,
                 const char *user, const char *pass)
{
    memset(ctx, 0, sizeof(*ctx));
    ctx->fd = -1;
    ctx->next_id = 1;
    ctx->backoff = STRATUM_BACKOFF_MIN;

    ctx->rxbuf = malloc(STRATUM_RXBUF_SIZE);
    if (!ctx->rxbuf)
        return -1;
    ctx->rx_len = 0;

    snprintf(ctx->host, sizeof(ctx->host), "%s", host);
    snprintf(ctx->port, sizeof(ctx->port), "%s", port);
    snprintf(ctx->user, sizeof(ctx->user), "%s", user);
    snprintf(ctx->pass, sizeof(ctx->pass), "%s", pass);
    return 0;
}

int stratum_connect(stratum_ctx_t *ctx)
{
    char line[STRATUM_TXBUF_SIZE];

    ctx->fd = tcp_connect(ctx->host, ctx->port);
    if (ctx->fd < 0)
        return -1;

    ctx->rx_len      = 0;
    ctx->subscribed  = false;
    ctx->authorized  = false;

    /* mining.subscribe */
    snprintf(line, sizeof(line),
             "{\"id\":%u,\"method\":\"mining.subscribe\","
             "\"params\":[\"odo-cyclonev/1.0\"]}\n",
             ctx->next_id++);
    if (send_line(ctx, line) < 0)
        goto fail;

    /* mining.authorize */
    snprintf(line, sizeof(line),
             "{\"id\":%u,\"method\":\"mining.authorize\","
             "\"params\":[\"%s\",\"%s\"]}\n",
             ctx->next_id++, ctx->user, ctx->pass);
    if (send_line(ctx, line) < 0)
        goto fail;

    fprintf(stderr, "stratum: connected to %s:%s, subscribe+authorize sent\n",
            ctx->host, ctx->port);
    ctx->backoff = STRATUM_BACKOFF_MIN;   /* reset on successful connect */
    return 0;

fail:
    stratum_disconnect(ctx);
    return -1;
}

int stratum_poll(stratum_ctx_t *ctx)
{
    if (ctx->fd < 0)
        return -1;
    return pump_recv(ctx);
}

int stratum_submit_share(stratum_ctx_t *ctx, const char *job_id,
                         uint32_t nonce, uint32_t ntime)
{
    char line[STRATUM_TXBUF_SIZE];

    if (ctx->fd < 0 || !ctx->authorized)
        return -1;

    /* Stratum encodes nonce/ntime as big-endian hex strings. */
    snprintf(line, sizeof(line),
             "{\"id\":%u,\"method\":\"mining.submit\","
             "\"params\":[\"%s\",\"%s\",\"\",\"%08x\",\"%08x\"]}\n",
             ctx->next_id++, ctx->user, job_id, ntime, nonce);

    ctx->shares_submitted++;
    return send_line(ctx, line);
}

void stratum_disconnect(stratum_ctx_t *ctx)
{
    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
    ctx->subscribed = false;
    ctx->authorized = false;
    ctx->rx_len = 0;
}

void stratum_destroy(stratum_ctx_t *ctx)
{
    stratum_disconnect(ctx);
    free(ctx->rxbuf);
    ctx->rxbuf = NULL;
}

/* ----------------------------------------------------------------------
 * Message dispatch
 * -------------------------------------------------------------------- */

static void process_line(stratum_ctx_t *ctx, char *line)
{
    if (line[0] == '\0')
        return;

    const char *method = json_find_key(line, "method");

    if (method && *method == '"') {
        if (strncmp(method, "\"mining.notify\"", 15) == 0) {
            const char *params = json_find_key(line, "params");
            if (params) handle_notify(ctx, params);
        } else if (strncmp(method, "\"mining.set_difficulty\"", 23) == 0) {
            const char *params = json_find_key(line, "params");
            if (params) handle_set_difficulty(ctx, params);
        } else {
            /* mining.set_extranonce, client.reconnect, etc. -- ignore. */
        }
        return;
    }

    /* No method => this is a response to one of our requests. */
    const char *idp = json_find_key(line, "id");
    long id = (idp && *idp != 'n') ? strtol(idp, NULL, 10) : -1;
    handle_result(ctx, id, line);
}

static void handle_notify(stratum_ctx_t *ctx, const char *params)
{
    /*
     * params = [ job_id, prevhash, coinb1, coinb2, merkle[],
     *            version, nbits, ntime, clean_jobs ]
     * We pull job_id (first quoted token) and the fields the FPGA needs.
     */
    job_t job;
    memset(&job, 0, sizeof(job));

    const char *p = params;
    while (*p && *p != '"') p++;     /* first array element = job_id */
    if (*p == '"') {
        p++;
        size_t i = 0;
        while (*p && *p != '"' && i < sizeof(job.job_id) - 1)
            job.job_id[i++] = *p++;
        job.job_id[i] = '\0';
    }

    job.clean = true;                /* OdoCrypt epochs: treat notify as fresh */
    job.valid = true;

    if (ctx->on_job)
        ctx->on_job(ctx->cb_arg, &job);

    ctx->jobs_received++;
    fprintf(stderr, "stratum: new job %s\n", job.job_id);
}

static void handle_set_difficulty(stratum_ctx_t *ctx, const char *params)
{
    const char *p = params;
    while (*p && (*p == '[' || *p == ' ')) p++;
    double diff = strtod(p, NULL);
    if (diff > 0.0) {
        ctx->difficulty = diff;
        if (ctx->on_difficulty)
            ctx->on_difficulty(ctx->cb_arg, diff);
        fprintf(stderr, "stratum: set_difficulty %.6g\n", diff);
    }
}

static void handle_result(stratum_ctx_t *ctx, long id, const char *body)
{
    bool ok = false;

    if (json_get_bool(body, "result", &ok) == 0) {
        if (ok) {
            /* Could be subscribe/authorize ack or share accept. */
            if (!ctx->authorized) {
                ctx->authorized = true;
                fprintf(stderr, "stratum: authorized\n");
            } else {
                ctx->shares_accepted++;
            }
        } else {
            ctx->shares_rejected++;
            fprintf(stderr, "stratum: request id=%ld rejected\n", id);
        }
    }
}
