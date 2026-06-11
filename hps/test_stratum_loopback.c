/*
 * test_stratum_loopback.c — end-to-end validation of the HPS mining software
 * against a real DigiByte node, with NO FPGA.
 *
 * Drives the ACTUAL production code paths:
 *   stratum_connect -> stratum_poll -> stratum_get_job   (stratum.c)
 *   job parsing, header + merkle build                    (stratum.c, job.c,
 *                                                          odocrypt_header.c)
 *   epoch table generation + OdoCrypt encrypt             (odocrypt_state.c)
 *   + Keccak-800 (upstream reference)  = full PoW hash
 *   stratum_submit_share                                  (stratum.c)
 *
 * It connects to the solo Stratum bridge (tools/testnet), takes a job, CPU-
 * sweeps nonces hashing the job's OWN header (so a header/merkle/epoch bug
 * makes the share fail), and submits a winner. If the bridge accepts and the
 * node mines a block, the entire HPS software stack is proven correct — the
 * only untested piece left is the FPGA hashing, which is already verified
 * bit-exact by the RTL testbench.
 *
 * Build: make test_stratum_loopback
 * Run:   ./test_stratum_loopback <bridge-host> <bridge-port>
 */

#define _POSIX_C_SOURCE 200112L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "stratum.h"
#include "job.h"
#include "odocrypt_state.h"

/* upstream Keccak reference */
#define KeccakP800_stateSizeInBytes 100
extern void KeccakP800_Permute_12rounds(void *state);

/* Full consensus PoW hash: OdoCrypt encrypt of (header||0x01) then Keccak-12.
 * Mirrors DigiByte HashOdo and the FPGA core. */
static void pow_hash(const odo_epoch_state_t *st,
                     const uint8_t header[80], uint8_t out[32])
{
    uint8_t buf[KeccakP800_stateSizeInBytes];
    memset(buf, 0, sizeof(buf));
    memcpy(buf, header, 80);
    buf[80] = 1;
    odo_encrypt(st, buf, buf);          /* encrypts the first 80 bytes */
    KeccakP800_Permute_12rounds(buf);
    memcpy(out, buf, 32);
}

/* hash <= target, both little-endian uint256 (compare MSB-first) */
static int meets(const uint8_t h[32], const uint8_t t[32])
{
    for (int i = 31; i >= 0; i--) {
        if (h[i] < t[i]) return 1;
        if (h[i] > t[i]) return 0;
    }
    return 1;
}

int main(int argc, char **argv)
{
    const char *host = argc > 1 ? argv[1] : "127.0.0.1";
    const char *port = argc > 2 ? argv[2] : "3333";

    stratum_ctx_t ctx;
    if (stratum_init(&ctx, host, port, "loopback.worker", "x") != 0) {
        fprintf(stderr, "stratum_init failed\n");
        return 1;
    }
    if (stratum_connect(&ctx) != 0) {
        fprintf(stderr, "connect to %s:%s failed\n", host, port);
        return 1;
    }
    printf("connected to bridge %s:%s\n", host, port);

    /* Pump the protocol until a job is parsed (subscribe/authorize/notify). */
    job_t job;
    int have = 0;
    for (int i = 0; i < 100 && !have; i++) {
        stratum_poll(&ctx, 200);
        if (stratum_get_job(&ctx, &job))
            have = 1;
    }
    if (!have) {
        fprintf(stderr, "no job received — protocol mismatch with the bridge?\n");
        return 1;
    }
    printf("job %s epoch=%u ntime=%08x nbits=%08x\n",
           job.job_id, job.epoch, job.ntime, job.nbits);

    /* Generate this epoch's tables and sweep nonces over the job's OWN header. */
    odo_epoch_state_t st;
    odo_epoch_generate(&st, job.epoch);

    uint8_t header[80];
    memcpy(header, job.header, 80);
    uint8_t h[32];
    uint32_t nonce = 0;
    int found = 0;
    for (; nonce < 0x400000u; nonce++) {
        header[76] = (uint8_t)nonce;
        header[77] = (uint8_t)(nonce >> 8);
        header[78] = (uint8_t)(nonce >> 16);
        header[79] = (uint8_t)(nonce >> 24);
        pow_hash(&st, header, h);
        if (meets(h, job.target)) { found = 1; break; }
    }
    if (!found) {
        fprintf(stderr, "no winning nonce found (unexpected on regtest)\n");
        return 1;
    }
    printf("winner nonce=%u, submitting via stratum_submit_share...\n", nonce);

    if (stratum_submit_share(&ctx, &job, nonce) != 0) {
        fprintf(stderr, "stratum_submit_share send failed\n");
        return 1;
    }
    /* Let the response come back. */
    for (int i = 0; i < 25; i++)
        stratum_poll(&ctx, 200);

    printf("share submitted — check the bridge log for 'BLOCK ACCEPTED' and "
           "the node height.\n");
    stratum_disconnect(&ctx);
    return 0;
}
