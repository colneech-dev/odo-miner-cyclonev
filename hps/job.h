/*
 * job.h - Work-item definitions for the standalone OdoCrypt miner
 *
 * A job_t carries the fields required to build an OdoCrypt header, program
 * the FPGA, and submit a share to a Stratum pool.
 */

#ifndef JOB_H
#define JOB_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define JOB_HEADER_BYTES      80
#define JOB_TARGET_BYTES      32
#define JOB_MAX_JOBID_LEN     64
#define JOB_MAX_EXTRANONCE    32

typedef struct {
    char     job_id[JOB_MAX_JOBID_LEN];
    bool     clean_jobs;
    uint32_t epoch;

    uint32_t version;
    uint8_t  prevhash[32];
    uint8_t  merkle_root[32];
    uint32_t ntime;
    uint32_t nbits;

    uint8_t  target[JOB_TARGET_BYTES];
    uint8_t  header[JOB_HEADER_BYTES];

    uint8_t  extranonce2[JOB_MAX_EXTRANONCE];
    size_t   extranonce2_len;

    uint32_t nonce_start;
    uint32_t nonce_end;
} job_t;

void     job_init(job_t *job);
int      job_target_from_nbits(job_t *job);
void     job_set_nonce_range(job_t *job, uint32_t start, uint32_t end);
bool     job_same(const job_t *a, const job_t *b);

#endif /* JOB_H */
