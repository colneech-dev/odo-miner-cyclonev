/*
 * job.h - Work-item definitions for the standalone OdoCrypt miner (Cyclone V HPS)
 *
 * A job_t bundles everything the FPGA needs to start hashing a single piece of
 * work: the 80-byte block header template, the 256-bit target, the nonce range
 * assigned to this device, and the Stratum bookkeeping needed to submit a share.
 *
 * The HPS daemon flow is:
 *   stratum_recv() -> job_from_notify() -> odocrypt_build_header() ->
 *   job_program_fpga() -> (FPGA finds nonce) -> stratum_submit()
 */
#ifndef JOB_H
#define JOB_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* Sizes fixed by the block format / pool protocol. */
#define JOB_HEADER_BYTES      80   /* classic 80-byte PoW header              */
#define JOB_TARGET_BYTES      32   /* 256-bit target, big-endian               */
#define JOB_PREVHASH_BYTES    32
#define JOB_MERKLE_BYTES      32
#define JOB_MAX_JOBID_LEN     64
#define JOB_MAX_EXTRANONCE    16   /* extranonce2 working buffer               */

/*
 * job_t - one unit of mining work.
 *
 * All multi-byte fields are stored in the byte order required by the FPGA
 * register interface (little-endian words written via reg_wr). The raw
 * pool-supplied big-endian fields are kept where noted so shares can be
 * re-serialised for submission without re-deriving them.
 */
typedef struct job {
    /* --- Pool identity / bookkeeping --- */
    char     job_id[JOB_MAX_JOBID_LEN]; /* Stratum job id string             */
    bool     clean_jobs;                /* drop in-flight work if true        */
    uint32_t epoch;                     /* OdoCrypt mutation epoch for header */

    /* --- Header construction inputs (from mining.notify) --- */
    uint32_t version;                          /* block version (host order)  */
    uint8_t  prevhash[JOB_PREVHASH_BYTES];     /* previous block hash         */
    uint8_t  merkle_root[JOB_MERKLE_BYTES];    /* computed merkle root        */
    uint32_t ntime;                            /* block time                  */
    uint32_t nbits;                            /* compact difficulty bits     */

    /* --- Assembled output --- */
    uint8_t  header[JOB_HEADER_BYTES]; /* 80-byte template, nonce field zeroed */
    uint8_t  target[JOB_TARGET_BYTES]; /* 256-bit target derived from nbits    */

    /* --- Nonce range assigned to this FPGA --- */
    uint32_t nonce_start;
    uint32_t nonce_end;

    /* --- Extranonce data for share submission --- */
    uint8_t  extranonce2[JOB_MAX_EXTRANONCE];
    size_t   extranonce2_len;
} job_t;

/*
 * Initialise a job to a known-empty state. Must be called before any other
 * job_* function operates on the structure.
 */
void job_init(job_t *job);

/*
 * Populate header-construction fields from a parsed mining.notify. Does NOT
 * build the final header (call odocrypt_build_header() afterwards). Returns
 * 0 on success, negative on malformed input.
 */
int job_from_notify(job_t *job,
                    const char *job_id,
                    uint32_t version,
                    const uint8_t prevhash[JOB_PREVHASH_BYTES],
                    const uint8_t merkle_root[JOB_MERKLE_BYTES],
                    uint32_t ntime,
                    uint32_t nbits,
                    uint32_t epoch,
                    bool clean_jobs);

/*
 * Derive the 256-bit big-endian target from the compact nbits field and store
 * it in job->target. Returns 0 on success, negative if nbits is invalid.
 */
int job_target_from_nbits(job_t *job);

/*
 * Assign the nonce search window for this device. start/end are inclusive.
 */
void job_set_nonce_range(job_t *job, uint32_t start, uint32_t end);

/*
 * True if 'a' and 'b' refer to the same pool job (same job_id and epoch).
 */
bool job_same(const job_t *a, const job_t *b);

#endif /* JOB_H */
