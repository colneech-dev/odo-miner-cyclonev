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
            struct timespec ts = { 0, 1000000 };
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

static uint32_t parse_hex_u32(const char *hex)
{
    uint32_t value = 0;
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
            break;
        value = (value << 4) | nibble;
    }
    return value;
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

static size_t collect_quoted_strings(const char *json,
                                    char out[][128],
                                    size_t max_tokens)
{
    size_t count = 0;
    const char *p = json;

    while (*p && count < max_tokens) {
        if (*p == '"') {
            p++;
            char *dst = out[count];
            size_t written = 0;
            while (*p && *p != '"' && written + 1 < sizeof(out[count])) {
                if (*p == '\\' && p[1])
                    p++;
                dst[written++] = *p++;
            }
            dst[written] = '\0';
            if (*p == '"')
                p++;
            count++;
            continue;
        }
        p++;
    }
    return count;
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
    char tokens[16][128];
    size_t token_count = collect_quoted_strings(body, tokens, 16);
    if (token_count < 3)
        return -1;

    size_t extranonce1_len = hex_to_bytes(tokens[2], ctx->extranonce1, sizeof(ctx->extranonce1));
    if (extranonce1_len == 0)
        return -1;
    ctx->extranonce1_len = extranonce1_len;

    const char *p = strstr(body, tokens[2]);
    if (!p)
        return -1;
    p += strlen(tokens[2]);
    while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\r' || *p == '\n' || *p == ']'))
        p++;
    ctx->extranonce2_size = (int)strtol(p, NULL, 10);
    if (ctx->extranonce2_size < 0 || ctx->extranonce2_size > (int)sizeof(ctx->extranonce1))
        ctx->extranonce2_size = 0;

    ctx->subscribed = true;
    return 0;
}

static int handle_notify(stratum_ctx_t *ctx, const char *params)
{
    char tokens[64][128];
    size_t token_count = collect_quoted_strings(params, tokens, 64);
    if (token_count < 7)
        return -1;

    job_t job;
    job_init(&job);

    snprintf(job.job_id, sizeof(job.job_id), "%s", tokens[0]);
    job.version = parse_hex_u32(tokens[5]);
    job.nbits = parse_hex_u32(tokens[6]);
    job.ntime = parse_hex_u32(tokens[7]);
    job.clean_jobs = false;

    if (token_count >= 9) {
        const char *clean_pos = strstr(params, "clean_jobs");
        if (clean_pos)
            job.clean_jobs = (strstr(clean_pos, "true") != NULL);
    }

    job.epoch = job.ntime / (10u * 24u * 60u * 60u);
    memset(job.extranonce2, 0, sizeof(job.extranonce2));
    job.extranonce2_len = (size_t)ctx->extranonce2_size;

    if (hex_to_bytes(tokens[1], job.prevhash, sizeof(job.prevhash)) != sizeof(job.prevhash))
        return -1;
    for (size_t i = 0; i < sizeof(job.prevhash) / 2; ++i) {
        uint8_t tmp = job.prevhash[i];
        job.prevhash[i] = job.prevhash[31 - i];
        job.prevhash[31 - i] = tmp;
    }

    uint8_t coinbase[4096];
    size_t coinbase_len = 0;
    size_t coinb1_len = hex_to_bytes(tokens[2], coinbase, sizeof(coinbase));
    if (coinb1_len == 0)
        return -1;
    coinbase_len += coinb1_len;
    if (coinbase_len + ctx->extranonce1_len + job.extranonce2_len > sizeof(coinbase))
        return -1;
    memcpy(coinbase + coinbase_len, ctx->extranonce1, ctx->extranonce1_len);
    coinbase_len += ctx->extranonce1_len;
    memcpy(coinbase + coinbase_len, job.extranonce2, job.extranonce2_len);
    coinbase_len += job.extranonce2_len;
    size_t coinb2_len = hex_to_bytes(tokens[3], coinbase + coinbase_len, sizeof(coinbase) - coinbase_len);
    if (coinb2_len == 0)
        return -1;
    coinbase_len += coinb2_len;

    uint8_t root[32];
    odocrypt_build_header(&job, job.header);
    if (hex_to_bytes(tokens[4], job.header + 4, 32) != 32) {
        ;
    }

    if (keys[0] == NULL)
        return -1;

    if (job_target_from_nbits(&job) != 0)
        return -1;

    const size_t merkle_start = 4;
    const size_t merkle_end = token_count - 3;
    uint8_t branch[32];
    size_t branch_len;
    uint8_t root_hash[32];
    odocrypt_build_header(&job, job.header);
    return 0;
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
    if (rc == 0)
        return 0;

    char buffer[4096];
    ssize_t n = recv(ctx->fd, buffer, sizeof(buffer), 0);
    if (n <= 0)
        return -1;

    if ((size_t)n + ctx->rxlen >= sizeof(ctx->rxbuf))
        return -1;

    memcpy(ctx->rxbuf + ctx->rxlen, buffer, (size_t)n);
    ctx->rxlen += (size_t)n;
    ctx->rxbuf[ctx->rxlen] = '\0';

    char *line_start = ctx->rxbuf;
    for (size_t i = 0; i < ctx->rxlen; ++i) {
        if (ctx->rxbuf[i] == '\n') {
            ctx->rxbuf[i] = '\0';
            const char *line = line_start;
            if (line[0] != '\0') {
                const char *method = find_json_key(line, "method");
                if (method && *method == '"' && strncmp(method, "\"mining.notify\"", 15) == 0) {
                    const char *params = find_json_key(line, "params");
                    if (params)
                        handle_notify(ctx, params);
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

    char line[1024];
    snprintf(line, sizeof(line),
             "{\"id\":%llu,\"method\":\"mining.submit\","
             "\"params\":[\"%s\",\"%s\",\"%s\",\"%08x\",\"%08x\"]}\n",
             (unsigned long long)ctx->next_id++, ctx->user,
             job->job_id,
             extranonce2_hex,
             job->ntime,
             nonce);

    return send_line(ctx, line);
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
