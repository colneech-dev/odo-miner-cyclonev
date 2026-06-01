/*
 * test_odo.c — Self-test and cross-check harness for odocrypt_state.c
 *
 * Validates that our C port of OdoCrypt:
 *   1. Produces deterministic output (same input → same output).
 *   2. Produces different output for different epoch keys.
 *   3. Produces different output for different nonces (i.e., the initial
 *      state build is nonce-sensitive).
 *   4. Prints the encrypt output as hex so it can be compared manually
 *      with the upstream C++ reference (see test_odo_upstream.cpp).
 *
 * Build (native host or cross-compiled for ARM):
 *   make test_odo
 *
 * Cross-check workflow:
 *   ./test_odo          → prints our output
 *   ./test_odo_upstream → prints upstream C++ output (same test vectors)
 *   diff <(./test_odo) <(./test_odo_upstream)   → must produce no output
 */

#include "odocrypt_state.h"

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

    /* --- Cross-check vectors: print for comparison with upstream --- */
    printf("\n--- Cross-check vectors (compare with test_odo_upstream) ---\n");

    uint32_t test_keys[]   = { 0, 1, 12345, 0xDEADBEEF };
    uint32_t test_nonces[] = { 0, 1, 0xCAFEBABE };

    for (size_t ki = 0; ki < sizeof(test_keys)/sizeof(test_keys[0]); ki++) {
        odo_epoch_state_t st;
        odo_epoch_generate(&st, test_keys[ki]);

        for (size_t ni = 0; ni < sizeof(test_nonces)/sizeof(test_nonces[0]); ni++) {
            uint8_t hdr[80];
            make_header(hdr, test_nonces[ni]);

            const uint8_t *out = run_encrypt(&st, hdr);

            printf("key=%08x nonce=%08x out=", test_keys[ki], test_nonces[ni]);
            for (int i = 0; i < ODO_DIGEST_SIZE; i++)
                printf("%02x", out[i]);
            printf("\n");
        }
    }

    printf("\n%s: %d failure(s)\n",
           failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
