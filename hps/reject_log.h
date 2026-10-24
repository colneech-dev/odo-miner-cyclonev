/*
 * reject_log.h -- say WHY the pool rejected a share, and WHICH share it was.
 *
 * WHY: stratum.c already prints "[stratum] share REJECTED: <raw reply>", but the reply carries only a request
 * id, so nothing said which share it was, and the line rotated out of the journal in a day or two. On 2026-10-24
 * the Pi showed 57 rejects (of ~174,000) and the only visible reason, "duplicate share" (code 22), could not be
 * traced to a job or a nonce, nor could the other 56 be found at all.
 *
 * Pieces (all pure, no I/O, so they are unit-tested):
 *   submit_ring_*   the last SUBMIT_RING_N submits by request id (id -> job, nonce, time)
 *   reject_extract  the pool's reason and code from either reply shape:
 *                     {"result":false,"error":{"code":22,"message":"duplicate share",...},"id":N}   (miningcore, NOMP)
 *                     {"result":null,"error":[21,"Job not found",null],"id":N}                     (classic stratum)
 *   reject_format   one log line, the same text for the journal and the durable file
 * The miner supplies the I/O (journal line, /var/lib/odod/rejects.log) in miner_pipe_k7.c.
 */
#ifndef REJECT_LOG_H
#define REJECT_LOG_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SUBMIT_RING_N      256
#define SUBMIT_JOBID_MAX   32
#define REJECT_REASON_MAX  96

struct submit_rec {
    uint64_t id;
    uint32_t nonce;
    time_t   t;
    char     job[SUBMIT_JOBID_MAX];
    int      used;
};
struct submit_ring { struct submit_rec r[SUBMIT_RING_N]; };

/* Remember submit `id`. ids are sequential, so the slot is id % N and a newer id simply replaces the one N earlier. */
static inline void submit_ring_put(struct submit_ring *g, uint64_t id, const char *job, uint32_t nonce, time_t t)
{
    struct submit_rec *s = &g->r[id % SUBMIT_RING_N];
    s->id = id;
    s->nonce = nonce;
    s->t = t;
    s->used = 1;
    {
        size_t n = job ? strlen(job) : 0;
        if (n >= SUBMIT_JOBID_MAX)
            n = SUBMIT_JOBID_MAX - 1;          /* truncate, always NUL-terminated */
        if (n)
            memcpy(s->job, job, n);
        s->job[n] = '\0';
    }
}

/* NULL if the id is unknown or has been overwritten by a newer submit. */
static inline const struct submit_rec *submit_ring_find(const struct submit_ring *g, uint64_t id)
{
    const struct submit_rec *s = &g->r[id % SUBMIT_RING_N];
    return (s->used && s->id == id) ? s : NULL;
}

/* Copy a JSON string body starting AFTER its opening quote into out (stops at the closing quote). Control characters
 * and double quotes are made safe for a one-line, quoted log field. */
static inline void reject_copy_str(const char *p, char *out, size_t outsz)
{
    size_t n = 0;
    while (*p && *p != '"' && n + 1 < outsz) {
        unsigned char c = (unsigned char)*p;
        if (c == '\\' && p[1]) { p++; c = (unsigned char)*p; }       /* take an escaped char literally */
        out[n++] = (c < 0x20 || c == 0x7f || c == '"') ? (c == '"' ? '\'' : ' ') : (char)c;
        p++;
    }
    out[n] = '\0';
}

/* Reason and code from a submit reply line. Always fills reason; code is -1 when none was found.
 * Returns 1 if the line carried an error description, 0 if it had to be guessed ("no error field"). */
static inline int reject_extract(const char *line, char *reason, size_t rsz, long *code)
{
    const char *p;
    *code = -1;
    if (rsz) reason[0] = '\0';
    if (!line) { snprintf(reason, rsz, "no reply"); return 0; }

    p = strstr(line, "\"error\"");
    if (p) {
        const char *q = strchr(p + 7, ':');
        if (q) {
            q++;
            while (*q == ' ') q++;
            if (*q == '[') {                                            /* [code, "message", data] */
                char *end;
                long v;
                q++;
                while (*q == ' ') q++;
                v = strtol(q, &end, 10);
                if (end != q) *code = v;
                q = strchr(end, ',');
                if (q) {
                    q++;
                    while (*q == ' ') q++;
                    if (*q == '"') { reject_copy_str(q + 1, reason, rsz); return reason[0] != '\0'; }
                }
            } else if (*q == '{') {                                     /* {"code":N,"message":"..."} */
                const char *c = strstr(q, "\"code\"");
                const char *m = strstr(q, "\"message\"");
                if (c) {
                    const char *cc = strchr(c + 6, ':');
                    if (cc) *code = strtol(cc + 1, NULL, 10);
                }
                if (m) {
                    const char *mm = strchr(m + 9, ':');
                    if (mm) {
                        mm++;
                        while (*mm == ' ') mm++;
                        if (*mm == '"') { reject_copy_str(mm + 1, reason, rsz); if (reason[0]) return 1; }
                    }
                }
            }
        }
    }
    snprintf(reason, rsz, "no error field in reply");
    return 0;
}

/* One line, no trailing newline. rec may be NULL (the id is older than the ring, or was never recorded). */
static inline void reject_format(char *buf, size_t bsz, uint64_t id, const char *reason, long code,
                                 const struct submit_rec *rec, time_t now)
{
    if (rec)
        snprintf(buf, bsz, "REJECT reason=\"%s\" code=%ld job=%s nonce=0x%08x age=%lds id=%llu",
                 reason, code, rec->job, (unsigned)rec->nonce, (long)(now - rec->t), (unsigned long long)id);
    else
        snprintf(buf, bsz, "REJECT reason=\"%s\" code=%ld job=? nonce=? (id %llu is not among the last %d submits)",
                 reason, code, (unsigned long long)id, SUBMIT_RING_N);
}

#endif
