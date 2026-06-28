#define _POSIX_C_SOURCE 200112L

#include "stratum.h"
#include "odocrypt_header.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>

static int set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static int tcp_connect(const char *host, const char *port)
{
    struct addrinfo hints;
    struct addrinfo *res = NULL, *rp;
    int fd = -1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    if (getaddrinfo(host, port, &hints, &res) != 0)
        return -1;

    for (rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0)
            continue;
        if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0)
            break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);

    if (fd < 0)
        return -1;

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
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

    while (off < len) {
        ssize_t n = send(ctx->fd, line + off, len - off, MSG_NOSIGNAL);
        if (n > 0) {
            off += (size_t)n;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct timespec ts = { .tv_sec = 0, .tv_nsec = 1000000 };
            nanosleep(&ts, NULL);
        } else {
            return -1;
        }
    }
    return 0;
}

static int parse_hex_byte(char ch, uint8_t *value)
{
    if (ch >= '0' && ch <= '9') {
        *value = (uint8_t)(ch - '0');
        return 0;
    }
    if (ch >= 'a' && ch <= 'f') {
        *value = (uint8_t)(10 + ch - 'a');
        return 0;
    }
    if (ch >= 'A' && ch <= 'F') {
        *value = (uint8_t)(10 + ch - 'A');
        return 0;
    }
    return -1;
}

static size_t hex_to_bytes(const char *hex, uint8_t *out, size_t max_out)
{
    size_t len = strlen(hex);
    if ((len & 1u) != 0 || (len / 2u) > max_out)
        return 0;

    for (size_t i = 0; i < len / 2; ++i) {
        uint8_t hi, lo;
        if (parse_hex_byte(hex[2 * i], &hi) || parse_hex_byte(hex[2 * i + 1], &lo))
            return 0;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return len / 2;
}

/* Parse a hex string to u32 (M5). Returns 0 on success and writes *out; -1 if
 * the string is empty, contains any non-hex char, or has more than 8 hex digits
 * (which would overflow a u32) — so a malformed version/nbits/ntime in a notify
 * rejects the job instead of silently mining a zeroed or truncated field. */
static int parse_hex_u32(const char *hex, uint32_t *out)
{
    uint32_t value = 0;
    int ndigits = 0;
    if (!hex || *hex == '\0')
        return -1;                         /* empty = malformed */
    while (*hex != '\0') {
        char c = *hex++;
        uint32_t nibble;
        if (c >= '0' && c <= '9')
            nibble = (uint32_t)(c - '0');
        else if (c >= 'a' && c <= 'f')
            nibble = (uint32_t)(10 + c - 'a');
        else if (c >= 'A' && c <= 'F')
            nibble = (uint32_t)(10 + c - 'A');
        else
            return -1;                     /* non-hex char = malformed */
        if (++ndigits > 8)
            return -1;                     /* > 32 bits = overflow/malformed */
        value = (value << 4) | nibble;
    }
    *out = value;
    return 0;
}

static void bytes_to_hex(const uint8_t *src, size_t src_len, char *dst, size_t dst_len)
{
    static const char hex[] = "0123456789abcdef";
    size_t needed = src_len * 2 + 1;
    if (dst_len < needed)
        return;
    for (size_t i = 0; i < src_len; ++i) {
        dst[2 * i]     = hex[(src[i] >> 4) & 0xF];
        dst[2 * i + 1] = hex[src[i] & 0xF];
    }
    dst[src_len * 2] = '\0';
}

static const char *find_json_key(const char *json, const char *key)
{
    char search[128];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(json, search);
    if (!p)
        return NULL;
    p += strlen(search);
    while (*p && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n' || *p == ':'))
        p++;
    return p;
}

static bool parse_json_bool(const char *json, const char *key, bool *out)
{
    const char *p = find_json_key(json, key);
    if (!p)
        return false;
    if (strncmp(p, "true", 4) == 0) {
        *out = true;
        return true;
    }
    if (strncmp(p, "false", 5) == 0) {
        *out = false;
        return true;
    }
    return false;
}

static int handle_subscribe_result(stratum_ctx_t *ctx, const char *body)
{
    /*
     * The result field looks like:
     *   "result": [[["mining.notify","<sub_id>"]], "EN1_HEX", EN2_SIZE]
     *
     * We locate the result value with find_json_key() and skip past the
     * nested subscription-details array to find EN1 and EN2_SIZE.
     * (collect_quoted_strings() is wrong here because it also picks up JSON
     * key strings like "id", "error", "result" before the actual values.)
     */
    const char *p = find_json_key(body, "result");
    if (!p || *p != '[')
        return -1;
    p++; /* skip outer '[' */

    /* Skip the subscription-details array [[...]] */
    if (*p == '[') {
        int depth = 1;
        p++;
        while (*p && depth > 0) {
            if (*p == '[') depth++;
            else if (*p == ']') depth--;
            p++;
        }
    }

    /* Skip comma and whitespace between the inner array and EN1 */
    while (*p && (*p == ',' || *p == ' ' || *p == '\t')) p++;

    /* Next quoted string is the extranonce1 hex */
    if (*p != '"')
        return -1;
    p++;
    char en1_hex[65] = {0};
    size_t hlen = 0;
    while (*p && *p != '"' && hlen + 1 < sizeof(en1_hex))
        en1_hex[hlen++] = *p++;
    en1_hex[hlen] = '\0';
    if (*p == '"') p++;

    size_t extranonce1_len = hex_to_bytes(en1_hex, ctx->extranonce1, sizeof(ctx->extranonce1));
    if (extranonce1_len == 0)
        return -1;
    ctx->extranonce1_len = extranonce1_len;

    /* Skip comma and whitespace, then parse EN2_SIZE integer */
    while (*p && (*p == ',' || *p == ' ' || *p == '\t')) p++;
    ctx->extranonce2_size = (int)strtol(p, NULL, 10);
    /* Clamp against the extranonce2 DESTINATION buffer (job_t.extranonce2,
     * JOB_MAX_EXTRANONCE) — not extranonce1, which only happens to be the same
     * size today. A pool advertising a larger EN2_SIZE would otherwise overflow
     * job.extranonce2[] at submit time (stratum.c share build). */
    if (ctx->extranonce2_size < 0 || ctx->extranonce2_size > JOB_MAX_EXTRANONCE)
        ctx->extranonce2_size = 0;
    else if (ctx->extranonce2_size > 0 && ctx->extranonce2_size < 4)
        /* H2: the per-job counter fills extranonce2's low bytes, so a tiny
         * EN2_SIZE repeats coinbases after 2^(8*size) jobs. Harmless at the
         * usual 4+, worth a heads-up if a pool advertises 1-3 bytes. */
        fprintf(stderr, "[stratum] WARN small EN2_SIZE=%d: extranonce2 repeats "
                "after 2^%d jobs\n", ctx->extranonce2_size, 8 * ctx->extranonce2_size);

    ctx->subscribed = true;
    fprintf(stderr, "[stratum] subscribe: EN1=%s (%zu B) EN2_SIZE=%d\n",
            en1_hex, extranonce1_len, ctx->extranonce2_size);
    return 0;
}

/*
 * Parse a mining.notify params array.
 *
 * Stratum format:
 *   ["job_id","prevhash","coinb1","coinb2",["branch",...],
 *    "version","nbits","ntime",clean_jobs]
 *
 * The inner branch array is variable length; we parse positionally.
 */
static int handle_notify(stratum_ctx_t *ctx, const char *params)
{
    job_t job;
    job_init(&job);

    /* Walk params character by character, extracting the structured fields. */
    const char *p = params;

    /* helper: skip to and past the next '"', copy content, return ptr after closing '"' */
#define NEXT_STR(dst, dst_sz) do { \
    while (*p && *p != '"') p++;   \
    if (!*p) return -1;            \
    p++;                           \
    size_t _len = 0;               \
    while (*p && *p != '"' && _len + 1 < (dst_sz)) { dst[_len++] = *p++; } \
    dst[_len] = '\0';              \
    while (*p && *p != '"') p++;   \
    if (*p == '"') p++;            \
} while (0)

    char job_id_buf [JOB_MAX_JOBID_LEN] = {0};
    char prevhash_hex[68]  = {0};
    char coinb1_hex  [2048] = {0};
    char coinb2_hex  [2048] = {0};
    /* Row width must match the odocrypt_build_merkle_root() parameter type
     * (const char [][128]) — passing a narrower array gives a wrong stride. */
    char branches[32][128];
    size_t branch_count = 0;

    /* Skip the outer '[' */
    while (*p && *p != '[') p++;
    if (!*p) return -1;
    p++;

    NEXT_STR(job_id_buf,  sizeof(job_id_buf));
    NEXT_STR(prevhash_hex, sizeof(prevhash_hex));
    NEXT_STR(coinb1_hex,  sizeof(coinb1_hex));
    NEXT_STR(coinb2_hex,  sizeof(coinb2_hex));

    /* Merkle branch array */
    while (*p && *p != '[') p++;
    if (!*p) return -1;
    p++; /* skip inner '[' */

    while (*p && *p != ']' && branch_count < 32) {
        if (*p == '"') {
            p++;
            size_t len = 0;
            while (*p && *p != '"' && len + 1 < sizeof(branches[0]))
                branches[branch_count][len++] = *p++;
            branches[branch_count][len] = '\0';
            if (*p == '"') p++;
            branch_count++;
        } else {
            p++;
        }
    }
    while (*p && *p != ']') p++;
    if (*p == ']') p++;

    char version_hex[12] = {0};
    char nbits_hex  [12] = {0};
    char ntime_hex  [12] = {0};
    NEXT_STR(version_hex, sizeof(version_hex));
    NEXT_STR(nbits_hex,   sizeof(nbits_hex));
    NEXT_STR(ntime_hex,   sizeof(ntime_hex));

    /* clean_jobs boolean follows the ntime string */
    const char *clean_pos = p;
    while (*clean_pos && *clean_pos != 't' && *clean_pos != 'f' && *clean_pos != ']')
        clean_pos++;
    job.clean_jobs = (strncmp(clean_pos, "true", 4) == 0);

#undef NEXT_STR

    /* Populate numeric fields — reject the job if any is malformed (M5). */
    snprintf(job.job_id, sizeof(job.job_id), "%s", job_id_buf);
    if (parse_hex_u32(version_hex, &job.version) != 0 ||
        parse_hex_u32(nbits_hex,   &job.nbits)   != 0 ||
        parse_hex_u32(ntime_hex,   &job.ntime)   != 0) {
        fprintf(stderr, "[stratum] notify: malformed version/nbits/ntime — ignoring job\n");
        return -1;
    }

    /* OdoCrypt epoch key: ntime rounded down to the shapechange interval
     * (upstream pool/stratum/header.py: odokey = ntime - ntime % interval). */
    job.epoch = job.ntime - (job.ntime % ctx->odo_interval);

    /* Pick a fresh extranonce2 for this job BEFORE building the coinbase so
     * the merkle root and the submitted value always agree. */
    job.extranonce2_len = (size_t)ctx->extranonce2_size;
    {
        uint64_t en2 = ctx->extranonce2_counter++;
        for (size_t i = 0; i < job.extranonce2_len && i < sizeof(en2); i++)
            job.extranonce2[i] = (uint8_t)(en2 >> (8 * i));
    }

    /* prevhash: classic Stratum V1 convention sends it word-swapped -- the
     * 32 bytes as eight 4-byte words in REVERSE WORD ORDER, but with each
     * word's own bytes UNCHANGED (NOT a full 32-byte mirror reversal, which
     * is what this used to do). Verified against a live pool 2026-06-20:
     * comparing a captured mining.notify prevhash against the real chain's
     * getbestblockhash, the per-word-swap-undo recovers the correct internal
     * hash bytes; a full reversal does not. Reversing the bytes within each
     * 4-byte word (leaving word order as received) is self-inverse, so this
     * one loop both "receives" and "produces" the same convention. */
    if (hex_to_bytes(prevhash_hex, job.prevhash, sizeof(job.prevhash))
            != sizeof(job.prevhash))
        return -1;
    for (size_t w = 0; w < sizeof(job.prevhash); w += 4) {
        uint8_t tmp;
        tmp = job.prevhash[w];   job.prevhash[w]   = job.prevhash[w + 3]; job.prevhash[w + 3] = tmp;
        tmp = job.prevhash[w+1]; job.prevhash[w+1] = job.prevhash[w + 2]; job.prevhash[w + 2] = tmp;
    }

    /* Build coinbase: coinb1 + extranonce1 + extranonce2 + coinb2 */
    uint8_t coinbase[4096];
    size_t  coinbase_len = 0;
    size_t n;

    n = hex_to_bytes(coinb1_hex, coinbase, sizeof(coinbase));
    if (!n && coinb1_hex[0]) return -1;
    coinbase_len += n;

    if (coinbase_len + ctx->extranonce1_len + job.extranonce2_len > sizeof(coinbase))
        return -1;
    memcpy(coinbase + coinbase_len, ctx->extranonce1, ctx->extranonce1_len);
    coinbase_len += ctx->extranonce1_len;
    memcpy(coinbase + coinbase_len, job.extranonce2, job.extranonce2_len);
    coinbase_len += job.extranonce2_len;

    n = hex_to_bytes(coinb2_hex, coinbase + coinbase_len, sizeof(coinbase) - coinbase_len);
    coinbase_len += n;

    /* Compute merkle root from coinbase + branch list */
    if (odocrypt_build_merkle_root(coinbase, coinbase_len,
                                   (const char (*)[128])branches,
                                   branch_count,
                                   job.merkle_root) != 0)
        return -1;

    /* Derive 256-bit network target from nbits, then the pool share target */
    if (job_target_from_nbits(&job) != 0)
        return -1;
    job_share_target_from_difficulty(&job, ctx->difficulty);

    /* Build the 80-byte header template (nonce field zeroed) */
    odocrypt_build_header(&job, job.header);

    /* Commit to context */
    ctx->current_job = job;
    ctx->have_job    = true;
    if (ctx->state < STRATUM_READY)
        ctx->state = STRATUM_READY;

    fprintf(stderr, "[stratum] job %s nbits=%s ntime=%08x epoch=%u branches=%zu clean=%d\n",
            job.job_id, nbits_hex, job.ntime, job.epoch, branch_count, job.clean_jobs);
    return 0;
}

/*
 * mining.set_difficulty: params = [diff]. Affects the share target of all
 * subsequent jobs; also retroactively updates a pending unfetched job so a
 * set_difficulty/notify pair in either order behaves correctly.
 */
static void handle_set_difficulty(stratum_ctx_t *ctx, const char *params)
{
    const char *p = params;
    while (*p && *p != '[') p++;
    if (!*p) return;
    p++;
    while (*p == ' ' || *p == '\t') p++;

    char *end = NULL;
    double diff = strtod(p, &end);
    if (end == p || diff <= 0.0)
        return;

    ctx->difficulty = diff;
    if (ctx->have_job)
        job_share_target_from_difficulty(&ctx->current_job, diff);
    fprintf(stderr, "[stratum] difficulty set to %g\n", diff);
}

/* Record a mining.submit request id as awaiting its result. Drops the oldest
 * if the in-flight set is full (that result then goes uncounted — bounded). */
static void track_pending_submit(stratum_ctx_t *ctx, uint64_t id)
{
    if (ctx->n_pending_submits >= STRATUM_MAX_PENDING_SUBMITS) {
        memmove(&ctx->pending_submits[0], &ctx->pending_submits[1],
                (STRATUM_MAX_PENDING_SUBMITS - 1) * sizeof(ctx->pending_submits[0]));
        ctx->n_pending_submits = STRATUM_MAX_PENDING_SUBMITS - 1;
    }
    ctx->pending_submits[ctx->n_pending_submits++] = id;
}

/* If id is a tracked submit, remove it and return true (this result belongs to
 * a share, not to subscribe/authorize). */
static bool take_pending_submit(stratum_ctx_t *ctx, uint64_t id)
{
    for (int i = 0; i < ctx->n_pending_submits; i++) {
        if (ctx->pending_submits[i] == id) {
            memmove(&ctx->pending_submits[i], &ctx->pending_submits[i + 1],
                    (size_t)(ctx->n_pending_submits - i - 1) * sizeof(ctx->pending_submits[0]));
            ctx->n_pending_submits--;
            return true;
        }
    }
    return false;
}

void stratum_share_stats(const stratum_ctx_t *ctx,
                         uint64_t *accepted, uint64_t *rejected)
{
    if (accepted) *accepted = ctx ? ctx->shares_accepted : 0;
    if (rejected) *rejected = ctx ? ctx->shares_rejected : 0;
}

static void handle_result(stratum_ctx_t *ctx, const char *line)
{
    /* find_json_key skips whitespace after ':', handling "result": [[...]] */
    const char *rp = find_json_key(line, "result");
    if (rp && *rp == '[') {
        if (handle_subscribe_result(ctx, line) == 0)
            return;
    }

    /* H3: correlate this response to a share submit by request id. The pool's
     * result:true/false here is the authoritative accept/reject — distinct from
     * the daemon's fire-and-forget "submitted" count. Submit ids are the only
     * ids we track, so authorize/other results fall through untouched. */
    const char *idp = find_json_key(line, "id");
    if (idp) {
        uint64_t id = strtoull(idp, NULL, 10);
        if (id != 0 && take_pending_submit(ctx, id)) {
            bool ok = false;
            if (parse_json_bool(line, "result", &ok)) {
                if (ok) {
                    ctx->shares_accepted++;
                } else {
                    ctx->shares_rejected++;
                    fprintf(stderr, "[stratum] share REJECTED: %s\n", line);
                }
            }
            return;
        }
    }

    bool ok = false;
    if (parse_json_bool(line, "result", &ok)) {
        if (ok) {
            if (!ctx->authorized) {
                ctx->authorized = true;
                fprintf(stderr, "[stratum] authorized\n");
            }
        } else {
            fprintf(stderr, "[stratum] result=false for line: %s\n", line);
        }
    }
}

int stratum_init(stratum_ctx_t *ctx,
                 const char *host,
                 const char *port,
                 const char *user,
                 const char *pass)
{
    if (!ctx || !host || !port || !user || !pass)
        return -1;

    memset(ctx, 0, sizeof(*ctx));
    ctx->fd = -1;
    ctx->state = STRATUM_DISCONNECTED;
    ctx->extranonce1_len = 0;
    ctx->extranonce2_size = 0;
    ctx->have_job = false;
    ctx->next_id = 1;
    ctx->difficulty = 0.0;

    /* OdoCrypt shapechange interval: 10 days mainnet, 1 day testnet.
     * Override with ODO_EPOCH_INTERVAL (seconds) or ODO_TESTNET=1. */
    ctx->odo_interval = 10 * 24 * 60 * 60;
    {
        const char *tn = getenv("ODO_TESTNET");
        const char *iv = getenv("ODO_EPOCH_INTERVAL");
        if (tn && tn[0] == '1')
            ctx->odo_interval = 24 * 60 * 60;
        if (iv && strtoul(iv, NULL, 10) > 0)
            ctx->odo_interval = (uint32_t)strtoul(iv, NULL, 10);
    }
    snprintf(ctx->host, sizeof(ctx->host), "%s", host);
    snprintf(ctx->port, sizeof(ctx->port), "%s", port);
    snprintf(ctx->user, sizeof(ctx->user), "%s", user);
    snprintf(ctx->pass, sizeof(ctx->pass), "%s", pass);
    return 0;
}

int stratum_connect(stratum_ctx_t *ctx)
{
    if (!ctx)
        return -1;

    ctx->fd = tcp_connect(ctx->host, ctx->port);
    if (ctx->fd < 0)
        return -1;

    ctx->rxlen = 0;
    ctx->subscribed = false;
    ctx->authorized = false;
    ctx->state = STRATUM_CONNECTING;

    char line[1024];
    snprintf(line, sizeof(line),
             "{\"id\":%llu,\"method\":\"mining.subscribe\","
             "\"params\":[\"odo-cyclonev/1.0\"]}\n",
             (unsigned long long)ctx->next_id++);
    if (send_line(ctx, line) < 0)
        goto fail;

    snprintf(line, sizeof(line),
             "{\"id\":%llu,\"method\":\"mining.authorize\","
             "\"params\":[\"%s\",\"%s\"]}\n",
             (unsigned long long)ctx->next_id++, ctx->user, ctx->pass);
    if (send_line(ctx, line) < 0)
        goto fail;

    ctx->state = STRATUM_SUBSCRIBED;
    ctx->last_rx = time(NULL);   /* arm the idle watchdog from connect time */
    return 0;

fail:
    stratum_disconnect(ctx);
    return -1;
}

int stratum_poll(stratum_ctx_t *ctx, int timeout_ms)
{
    if (!ctx || ctx->fd < 0)
        return -1;

    struct pollfd pfd = { .fd = ctx->fd, .events = POLLIN };
    int rc = poll(&pfd, 1, timeout_ms);
    if (rc < 0)
        return -1;
    if (rc == 0) {
        /* No data this tick. If the pool has been silent past the watchdog
         * window, the connection is likely half-dead — force a reconnect
         * instead of mining blind until the next submit fails. */
        if (ctx->last_rx != 0 && time(NULL) - ctx->last_rx > STRATUM_IDLE_TIMEOUT) {
            fprintf(stderr, "[stratum] no data for >%ds — assuming dead pool, reconnecting\n",
                    STRATUM_IDLE_TIMEOUT);
            return -1;
        }
        return 0;
    }

    char buffer[4096];
    ssize_t n = recv(ctx->fd, buffer, sizeof(buffer), 0);
    if (n <= 0)
        return -1;
    ctx->last_rx = time(NULL);   /* pool is alive — pet the watchdog */

    if ((size_t)n + ctx->rxlen >= sizeof(ctx->rxbuf)) {
        /* A single line has grown past the buffer with no newline to split on
         * (the parse loop drains complete lines every poll, so rxbuf only ever
         * holds one trailing partial). Drop that overlong partial and resync on
         * the next newline instead of tearing down the connection (M1). The
         * 4 KB recv always fits once rxlen is reset, so parsing continues below. */
        fprintf(stderr, "[stratum] oversized line >%zuB — dropping partial, resyncing\n",
                sizeof(ctx->rxbuf));
        ctx->rxlen  = 0;
        ctx->resync = 1;   /* discard the dropped line's tail up to the next \n */
    }

    memcpy(ctx->rxbuf + ctx->rxlen, buffer, (size_t)n);
    ctx->rxlen += (size_t)n;
    ctx->rxbuf[ctx->rxlen] = '\0';

    char *line_start = ctx->rxbuf;
    for (size_t i = 0; i < ctx->rxlen; ++i) {
        if (ctx->rxbuf[i] == '\n') {
            ctx->rxbuf[i] = '\0';
            const char *line = line_start;
            if (ctx->resync) {
                /* This newline ends the tail of a dropped oversized line —
                 * discard the fragment and resume parsing clean lines. */
                ctx->resync = 0;
                line_start = ctx->rxbuf + i + 1;
                continue;
            }
            if (line[0] != '\0') {
                const char *method = find_json_key(line, "method");
                if (method && *method == '"' && strncmp(method, "\"mining.notify\"", 15) == 0) {
                    const char *params = find_json_key(line, "params");
                    if (params)
                        handle_notify(ctx, params);
                } else if (method && *method == '"' &&
                           strncmp(method, "\"mining.set_difficulty\"", 23) == 0) {
                    const char *params = find_json_key(line, "params");
                    if (params)
                        handle_set_difficulty(ctx, params);
                } else {
                    handle_result(ctx, line);
                }
            }
            line_start = ctx->rxbuf + i + 1;
        }
    }

    size_t remaining = ctx->rxlen - (line_start - ctx->rxbuf);
    memmove(ctx->rxbuf, line_start, remaining);
    ctx->rxlen = remaining;
    return 1;
}

void stratum_disconnect(stratum_ctx_t *ctx)
{
    if (!ctx)
        return;
    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
    ctx->state = STRATUM_DISCONNECTED;
    ctx->subscribed = false;
    ctx->authorized = false;
    ctx->have_job = false;
    ctx->rxlen = 0;
}

void stratum_destroy(stratum_ctx_t *ctx)
{
    if (!ctx)
        return;
    stratum_disconnect(ctx);
}

bool stratum_get_job(stratum_ctx_t *ctx, job_t *out)
{
    if (!ctx || !out || !ctx->have_job)
        return false;
    *out = ctx->current_job;
    ctx->have_job = false;
    return true;
}

int stratum_submit_share(stratum_ctx_t *ctx,
                         const job_t *job,
                         uint32_t nonce)
{
    if (!ctx || !job || ctx->fd < 0 || !ctx->authorized)
        return -1;

    char extranonce2_hex[JOB_MAX_EXTRANONCE * 2 + 1] = "";
    bytes_to_hex(job->extranonce2, job->extranonce2_len,
                 extranonce2_hex, sizeof(extranonce2_hex));

    uint64_t id = ctx->next_id++;
    char line[1024];
    snprintf(line, sizeof(line),
             "{\"id\":%llu,\"method\":\"mining.submit\","
             "\"params\":[\"%s\",\"%s\",\"%s\",\"%08x\",\"%08x\"]}\n",
             (unsigned long long)id, ctx->user,
             job->job_id,
             extranonce2_hex,
             job->ntime,
             nonce);

    int rc = send_line(ctx, line);
    if (rc >= 0)
        track_pending_submit(ctx, id);   /* count the pool's accept/reject */
    return rc;
}

int stratum_submit(stratum_ctx_t *ctx,
                   const job_t *job,
                   uint32_t nonce,
                   const char *ntime_hex,
                   const char *extranonce2_hex)
{
    if (!ctx || !job || ctx->fd < 0 || !ctx->authorized)
        return -1;

    uint64_t id = ctx->next_id++;
    char line[1024];
    snprintf(line, sizeof(line),
             "{\"id\":%llu,\"method\":\"mining.submit\","
             "\"params\":[\"%s\",\"%s\",\"%s\",\"%s\",\"%08x\"]}\n",
             (unsigned long long)id,
             ctx->user,
             job->job_id,
             extranonce2_hex ? extranonce2_hex : "",
             ntime_hex ? ntime_hex : "00000000",
             nonce);

    int rc = send_line(ctx, line);
    if (rc >= 0)
        track_pending_submit(ctx, id);
    return rc;
}

const char *stratum_state_str(stratum_state_t state)
{
    switch (state) {
    case STRATUM_DISCONNECTED: return "disconnected";
    case STRATUM_CONNECTING:   return "connecting";
    case STRATUM_SUBSCRIBED:   return "subscribed";
    case STRATUM_AUTHORIZED:   return "authorized";
    case STRATUM_READY:        return "ready";
    case STRATUM_ERROR:        return "error";
    default:                   return "unknown";
    }
}
