#include "job.h"
#include <string.h>
#include <limits.h>

static bool hex_digit_to_value(char digit, uint8_t *value)
{
    if (digit >= '0' && digit <= '9') {
        *value = (uint8_t)(digit - '0');
        return true;
    }
    if (digit >= 'a' && digit <= 'f') {
        *value = (uint8_t)(10 + digit - 'a');
        return true;
    }
    if (digit >= 'A' && digit <= 'F') {
        *value = (uint8_t)(10 + digit - 'A');
        return true;
    }
    return false;
}

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
    return 0;
}

void job_set_nonce_range(job_t *job, uint32_t start, uint32_t end)
{
    if (!job)
        return;
    job->nonce_start = start;
    job->nonce_end = end;
}

bool job_same(const job_t *a, const job_t *b)
{
    if (!a || !b)
        return false;
    return (a->epoch == b->epoch) && (strncmp(a->job_id, b->job_id, JOB_MAX_JOBID_LEN) == 0);
}
