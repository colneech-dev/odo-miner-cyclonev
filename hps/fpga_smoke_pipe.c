/*
 * fpga_smoke_pipe.c — on-board smoke test for the pipelined miner (P1.5/P1.6).
 *
 * Verifies the pipelined FPGA path end to end WITHOUT a pool: reads the baked-in
 * epoch, dispatches a deterministic test header with a loose target, polls for a
 * found nonce, and validates it with the same oracle the RTL was checked against
 * (odocrypt_state.c == upstream odocrypt.cpp). Run on the board as root.
 *
 * Build (cross or native): see hps/Makefile target smoke_pipe.
 */

#define _POSIX_C_SOURCE 200809L

#include "miner_io_pipe.h"
#include "odocrypt_state.h"
#include "KeccakP-800-SnP.h"

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

static void sleep_us(long us)
{
    struct timespec ts = { us / 1000000L, (us % 1000000L) * 1000L };
    nanosleep(&ts, NULL);
}

/* Must match the bitstream's baked epoch (qsf ODOKEY / odo_<seed>.v). */
#define SMOKE_EPOCH   1748736000u
#define SMOKE_TGT_MSB 0x10u          /* target = 0x10 * 2^248 (~1/16, fast) */

/* Same deterministic header as gen_vectors_pipe.c (bytes 76..79 swept). */
static void build_header(uint32_t key, uint8_t h[80])
{
    uint32_t x = key ^ 0xDEADBEEFu;
    for (int i = 0; i < 80; i++) { x = x * 1664525u + 1013904223u; h[i] = (uint8_t)(x >> 24); }
    h[76] = h[77] = h[78] = h[79] = 0;
}

/* uint256 strict less-than, LE byte arrays (byte[31] = MSB) == RTL cmp_256. */
static int hash_lt(const uint8_t *a, const uint8_t *b)
{
    for (int i = 31; i >= 0; i--) if (a[i] != b[i]) return a[i] < b[i];
    return 0;
}

int main(void)
{
    if (miner_io_pipe_init() != 0) {
        fprintf(stderr, "smoke_pipe: miner_io_pipe_init failed (run as root?)\n");
        return 1;
    }

    uint32_t seed = miner_io_pipe_seed();
    uint32_t ver  = miner_io_pipe_version();
    printf("seed=0x%08x (epoch %u)  version=0x%08x\n", seed, seed, ver);
    if (seed != SMOKE_EPOCH) {
        printf("FAIL: bitstream epoch 0x%08x != expected 0x%08x\n", seed, SMOKE_EPOCH);
        miner_io_pipe_shutdown();
        return 1;
    }

    uint8_t header[80]; build_header(SMOKE_EPOCH, header);
    uint8_t target[32]; memset(target, 0, sizeof(target)); target[31] = (uint8_t)SMOKE_TGT_MSB;

    printf("dispatching test job (target_msb=0x%02x)...\n", SMOKE_TGT_MSB);
    miner_io_pipe_dispatch(header, target);

    /* Poll up to ~5 s for a find (settle window + first qualifying nonce). */
    uint32_t nonce = 0; int found = 0;
    for (int i = 0; i < 50000 && !found; i++) {
        int rc = miner_io_pipe_poll(&nonce);
        if (rc == 0) { found = 1; break; }
        if (rc < 0) { printf("FAIL: poll I/O error\n"); miner_io_pipe_shutdown(); return 1; }
        sleep_us(100);
    }
    if (!found) {
        printf("FAIL: no nonce found within timeout\n");
        miner_io_pipe_shutdown();
        return 1;
    }
    printf("FOUND nonce=0x%08x\n", nonce);

    /* Validate against the oracle (recompute hash, check < target). */
    odo_epoch_state_t st;
    odo_epoch_generate(&st, SMOKE_EPOCH);
    uint8_t cipher[KeccakP800_stateSizeInBytes];
    memset(cipher, 0, sizeof(cipher));
    memcpy(cipher, header, 80);
    cipher[76] = (uint8_t)(nonce);       cipher[77] = (uint8_t)(nonce >> 8);
    cipher[78] = (uint8_t)(nonce >> 16); cipher[79] = (uint8_t)(nonce >> 24);
    cipher[80] = 1;
    odo_encrypt(&st, cipher, cipher);
    KeccakP800_Permute_12rounds(cipher);

    int ok = hash_lt(cipher, target);
    printf("hash MSB=%02x%02x%02x%02x  ->  %s\n",
           cipher[31], cipher[30], cipher[29], cipher[28],
           ok ? "PASS: valid pipelined solution" : "FAIL: nonce does not satisfy target");

    miner_io_pipe_shutdown();
    return ok ? 0 : 1;
}
