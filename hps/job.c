#include "job.h"
#include <string.h>
#include <limits.h>
#include <stdio.h>


void job_init(job_t *job)
{
    if (!job)
        return;

    memset(job, 0, sizeof(*job));
    job->clean_jobs = true;
    job->epoch = 0;
    job->nonce_start = 0;
    job->nonce_end = UINT32_MAX;
}

int job_target_from_nbits(job_t *job)
{
    if (!job)
        return -1;

    uint32_t nbits = job->nbits;
    uint32_t exponent = nbits >> 24;
    uint32_t mantissa = nbits & 0x007FFFFFu;

    if (mantissa == 0 || exponent == 0)
        return -1;

    memset(job->target, 0, JOB_TARGET_BYTES);

    if (exponent <= 3) {
        uint32_t value = mantissa >> (8 * (3 - exponent));
        for (int i = 0; i < 4; ++i) {
            job->target[i] = (uint8_t)(value & 0xFFu);
            value >>= 8;
        }
        memcpy(job->share_target, job->target, JOB_TARGET_BYTES);
        return 0;
    }

    if (exponent > JOB_TARGET_BYTES + 3)
        return -1;

    size_t shift = (size_t)(8 * (exponent - 3));
    size_t word_shift = shift / 8;

    if (word_shift + 3 >= JOB_TARGET_BYTES)
        return -1;

    job->target[word_shift + 0] = (uint8_t)(mantissa & 0xFFu);
    job->target[word_shift + 1] = (uint8_t)((mantissa >> 8) & 0xFFu);
    job->target[word_shift + 2] = (uint8_t)((mantissa >> 16) & 0xFFu);
    memcpy(job->share_target, job->target, JOB_TARGET_BYTES);
    return 0;
}

/*
 * Convert a Stratum share difficulty to a 256-bit little-endian target.
 * Same construction as cpuminer's diff_to_target: diff1 target is
 * 0x00000000FFFF0000...0000 (0xFFFF * 2^208); share target = diff1 / diff.
 */
void job_share_target_from_difficulty(job_t *job, double diff)
{
    if (!job)
        return;

    if (diff <= 0.0) {
        memcpy(job->share_target, job->target, JOB_TARGET_BYTES);
        return;
    }

    int k;
    for (k = 6; k > 0 && diff > 1.0; k--)
        diff /= 4294967296.0;

    uint64_t m = (uint64_t)(4294901760.0 / diff);  /* 0xFFFF0000 / diff */

    memset(job->share_target, 0, JOB_TARGET_BYTES);
    if (m == 0 && k == 6) {
        memset(job->share_target, 0xff, JOB_TARGET_BYTES);
    } else {
        /* place m at 32-bit word positions k and k+1 (LE words, LE bytes) */
        for (int b = 0; b < 8; b++)
            job->share_target[4 * k + b] = (uint8_t)(m >> (8 * b));
    }
}

void job_set_nonce_range(job_t *job, uint32_t start, uint32_t end)
{
    if (!job)
        return;
    job->nonce_start = start;
    job->nonce_end = end;
}

int job_from_notify(job_t *job,
                    const char *job_id,
                    uint32_t version,
                    const uint8_t *prevhash,
                    const uint8_t *merkle_root,
                    uint32_t ntime,
                    uint32_t nbits,
                    uint32_t epoch,
                    bool clean_jobs)
{
    if (!job || !job_id || !prevhash || !merkle_root)
        return -1;

    job_init(job);

    snprintf(job->job_id, sizeof(job->job_id), "%s", job_id);
    job->version    = version;
    job->ntime      = ntime;
    job->nbits      = nbits;
    job->epoch      = epoch;
    job->clean_jobs = clean_jobs;

    memcpy(job->prevhash,    prevhash,    sizeof(job->prevhash));
    memcpy(job->merkle_root, merkle_root, sizeof(job->merkle_root));

    return job_target_from_nbits(job);
}

bool job_same(const job_t *a, const job_t *b)
{
    if (!a || !b)
        return false;
    return (a->epoch == b->epoch) && (strncmp(a->job_id, b->job_id, JOB_MAX_JOBID_LEN) == 0);
}
