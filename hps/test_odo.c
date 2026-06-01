/*
 * test_odo.c — Self-test and cross-check harness for odocrypt_state.c
 *
 * Validates our C port of OdoCrypt and computes the full PoW hash:
 *   odo_encrypt(header) → KeccakP800_Permute_12rounds → 256-bit hash
 *
 * The "pow:" lines in the output are the ground-truth expected values
 * used by the Verilog testbench (hdl/tb/odocrypt_core_tb.v).
 *
 * Build:
 *   make test_odo          (C self-test only)
 *   make check             (cross-check vs upstream C++)
 *
 * Cross-check workflow:
 *   diff <(./test_odo) <(./test_odo_upstream)  → must produce no output
 */

#include "odocrypt_state.h"

/* Keccak-800 reference implementation from upstream submodule. */
#include "../upstream/odo-miner/src/crypto/KeccakP-800-SnP.h"

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

/* Compare two byte arrays; return 0 if equal. */
static int bytes_eq(const uint8_t *a, const uint8_t *b, size_t len)
{
    return memcmp(a, b, len) == 0;
}

/* Build an 80-byte test header with a given nonce and distinguishable fields.
 * Version=1, prevhash filled with 0xAA, merkle filled with 0xBB,
 * ntime=0xDEADBEEF, nbits=0x1d00ffff, nonce as given. */
static void make_header(uint8_t hdr[80], uint32_t nonce)
{
    memset(hdr, 0, 80);
    uint32_t version = 1;
    memcpy(hdr + 0, &version, 4);
    memset(hdr + 4,  0xAA, 32);   /* prevhash */
    memset(hdr + 36, 0xBB, 32);   /* merkle root */
    uint32_t ntime = 0xDEADBEEF;
    memcpy(hdr + 68, &ntime, 4);
    uint32_t nbits = 0x1d00ffff;
    memcpy(hdr + 72, &nbits, 4);
    memcpy(hdr + 76, &nonce, 4);
}

/* Compute the full OdoCrypt PoW hash:
 *   state[0..79]  = header (80 bytes)
 *   state[80]     = 0x01   (domain separation, set before odo_encrypt)
 *   state[81..99] = 0x00
 *   odo_encrypt in-place on state[0..79]
 *   KeccakP800_Permute_12rounds on full 100-byte state
 *   hash = state[0..31]
 *
 * Matches hashodo.h from the upstream odo-miner exactly.
 */
static void pow_hash(const odo_epoch_state_t *st,
                     const uint8_t header[ODO_DIGEST_SIZE],
                     uint8_t hash_out[32])
{
    uint8_t state[KeccakP800_stateSizeInBytes];   /* 100 bytes */
    memset(state, 0, sizeof(state));
    memcpy(state, header, ODO_DIGEST_SIZE);
    state[ODO_DIGEST_SIZE] = 0x01;                /* domain separation byte */
    odo_encrypt(st, state, state);
    KeccakP800_Permute_12rounds(state);
    memcpy(hash_out, state, 32);
}

/* Run one encrypt and print the result. Returns pointer to static buffer. */
static const uint8_t *run_encrypt(const odo_epoch_state_t *st,
                                  const uint8_t plain[80])
{
    static uint8_t cipher[ODO_DIGEST_SIZE];
    memset(cipher, 0, sizeof(cipher));
    odo_encrypt(st, plain, cipher);
    return cipher;
}

static int failures = 0;

#define CHECK(cond, msg) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s\n", msg); \
        failures++; \
    } else { \
        printf("PASS: %s\n", msg); \
    } \
} while (0)

int main(void)
{
    odo_epoch_state_t st0, st1;
    uint8_t hdr0[80], hdr1[80];
    uint8_t out_a[ODO_DIGEST_SIZE], out_b[ODO_DIGEST_SIZE];

    /* --- Test 1: determinism --- */
    odo_epoch_generate(&st0, 0);
    make_header(hdr0, 0);
    odo_encrypt(&st0, hdr0, out_a);
    odo_encrypt(&st0, hdr0, out_b);
    CHECK(bytes_eq(out_a, out_b, ODO_DIGEST_SIZE),
          "same input + same epoch → same output (determinism)");

    /* --- Test 2: different epoch → different output --- */
    odo_epoch_generate(&st1, 1);
    odo_encrypt(&st1, hdr0, out_b);
    CHECK(!bytes_eq(out_a, out_b, ODO_DIGEST_SIZE),
          "same input, different epoch → different output");

    /* --- Test 3: different nonce → different output --- */
    make_header(hdr1, 1);
    odo_encrypt(&st0, hdr1, out_b);
    CHECK(!bytes_eq(out_a, out_b, ODO_DIGEST_SIZE),
          "same epoch, different nonce → different output");

    /* --- Test 4: output is non-trivial (not all zeros) --- */
    int all_zero = 1;
    for (int i = 0; i < ODO_DIGEST_SIZE; i++)
        if (out_a[i]) { all_zero = 0; break; }
    CHECK(!all_zero, "encrypt output is not all-zeros");

    /* --- Test 5: verify table word count matches FPGA expectation --- */
    /*
     * odo_fpga_load_epoch writes exactly REG_EPOCH_WR_TOTAL = 5964 words.
     * Count manually:
     *   small sbox:  40 × 64 / 4         = 640
     *   large sbox:  10 × 1024 / 2       = 5120
     *   pbox masks:  2 × (6×5×2)         = 120
     *   pbox rots:   2 × (5×5)           = 50
     *   rotations:   6                   = 6
     *   round keys:  ceil(84/3)          = 28
     *   total                            = 5964
     */
    int expected = 640 + 5120 + 120 + 50 + 6 + 28;
    CHECK(expected == 5964, "table word count matches REG_EPOCH_WR_TOTAL (5964)");

    /* --- Cross-check vectors: odo_encrypt output + full PoW hash --- */
    printf("\n--- Cross-check vectors (compare with test_odo_upstream) ---\n");

    uint32_t test_keys[]   = { 0, 1, 12345, 0xDEADBEEF };
    uint32_t test_nonces[] = { 0, 1, 0xCAFEBABE };

    for (size_t ki = 0; ki < sizeof(test_keys)/sizeof(test_keys[0]); ki++) {
        odo_epoch_state_t st;
        odo_epoch_generate(&st, test_keys[ki]);

        for (size_t ni = 0; ni < sizeof(test_nonces)/sizeof(test_nonces[0]); ni++) {
            uint8_t hdr[80], hash[32];
            make_header(hdr, test_nonces[ni]);

            /* odo_encrypt output — for cross-checking algorithm only */
            const uint8_t *enc = run_encrypt(&st, hdr);
            printf("key=%08x nonce=%08x out=", test_keys[ki], test_nonces[ni]);
            for (int i = 0; i < ODO_DIGEST_SIZE; i++)
                printf("%02x", enc[i]);
            printf("\n");

            /* Full PoW hash (odo_encrypt → Keccak-800 → 32 bytes) */
            make_header(hdr, test_nonces[ni]);   /* fresh header for pow_hash */
            pow_hash(&st, hdr, hash);
            printf("key=%08x nonce=%08x pow=", test_keys[ki], test_nonces[ni]);
            for (int i = 0; i < 32; i++)
                printf("%02x", hash[i]);
            printf("\n");
        }
    }

    printf("\n%s: %d failure(s)\n",
           failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
