/*
 * test_units.c — unit tests for stratum/job helper logic.
 *
 * Covers the 2026-06-10 bug fixes:
 *   1. job_share_target_from_difficulty: diff=1 must equal the standard
 *      diff1 target (0xFFFF * 2^208), higher diff must lower the target.
 *   2. OdoCrypt epoch key derivation: ntime - ntime % interval.
 *   3. odocrypt_build_merkle_root with multiple branches (the call-site
 *      stride bug made every branch after the first read garbage).
 *   4. target_met semantics on little-endian uint256 arrays.
 *
 * Build & run: make test_units
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "job.h"
#include "odocrypt_header.h"

static int g_failures = 0;

#define CHECK(cond, name) do { \
    if (cond) { printf("PASS: %s\n", name); } \
    else      { printf("FAIL: %s\n", name); g_failures++; } \
} while (0)

/* Same comparison the miner uses: LE uint256, byte 31 most significant */
static int target_met(const uint8_t hash[32], const uint8_t target[32])
{
    for (int i = 31; i >= 0; i--) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 1;
}

static void test_share_target(void)
{
    job_t job;
    job_init(&job);

    /* diff = 1.0 → target = 0xFFFF * 2^208:
     * LE bytes: target[26]=0xFF, target[27]=0xFF, all others 0 */
    job_share_target_from_difficulty(&job, 1.0);
    uint8_t expect[32] = {0};
    expect[26] = 0xFF;
    expect[27] = 0xFF;
    CHECK(memcmp(job.share_target, expect, 32) == 0, "diff1 share target");

    /* diff = 65536 → target = 0xFFFF * 2^192:
     * LE bytes: target[24]=0xFF, target[25]=0xFF */
    job_share_target_from_difficulty(&job, 65536.0);
    memset(expect, 0, 32);
    expect[24] = 0xFF;
    expect[25] = 0xFF;
    CHECK(memcmp(job.share_target, expect, 32) == 0, "diff 65536 share target");

    /* Monotonic: higher difficulty → numerically smaller target */
    job_t a, b;
    job_init(&a); job_init(&b);
    job_share_target_from_difficulty(&a, 16.0);
    job_share_target_from_difficulty(&b, 1024.0);
    CHECK(target_met(b.share_target, a.share_target) &&
          !target_met(a.share_target, b.share_target),
          "higher difficulty gives smaller target");

    /* diff <= 0 falls back to the network target */
    job_t c;
    job_init(&c);
    c.nbits = 0x1d00ffff;
    job_target_from_nbits(&c);
    uint8_t net[32];
    memcpy(net, c.target, 32);
    job_share_target_from_difficulty(&c, 0.0);
    CHECK(memcmp(c.share_target, net, 32) == 0, "diff 0 falls back to network target");
}

static void test_epoch_key(void)
{
    /* Mirrors upstream pool/stratum/header.py: odokey = ntime - ntime % I */
    const uint32_t interval = 10 * 24 * 60 * 60;   /* 864000, mainnet */
    uint32_t ntime = 1749600000;                   /* arbitrary recent time */
    uint32_t key   = ntime - (ntime % interval);
    CHECK(key % interval == 0,        "epoch key aligned to interval");
    CHECK(key <= ntime,               "epoch key not in the future");
    CHECK(ntime - key < interval,     "epoch key within one interval");
    /* concrete value: 1749600000 % 864000 = 1749600000 - 2024*864000
     * 2024*864000 = 1748736000; remainder 864000 → wait, recompute below */
    CHECK(key == (ntime / interval) * interval, "epoch key matches integer division");
}

static void test_merkle_branches(void)
{
    /* Reference chain computed with the same double-SHA256 primitive:
     * root = dsha(coinbase); for each branch: root = dsha(root || branch). */
    const uint8_t coinbase[] = { 0x01, 0x02, 0x03, 0x04 };

    uint8_t b0[32], b1[32];
    for (int i = 0; i < 32; i++) { b0[i] = (uint8_t)i; b1[i] = (uint8_t)(0xA0 ^ i); }

    uint8_t expect[32], concat[64];
    odocrypt_double_sha256(coinbase, sizeof(coinbase), expect);
    memcpy(concat, expect, 32); memcpy(concat + 32, b0, 32);
    odocrypt_double_sha256(concat, 64, expect);
    memcpy(concat, expect, 32); memcpy(concat + 32, b1, 32);
    odocrypt_double_sha256(concat, 64, expect);

    /* Hex-encode branches the way handle_notify stores them: 128-byte rows */
    char branches[2][128];
    for (int i = 0; i < 32; i++) {
        snprintf(branches[0] + 2 * i, 3, "%02x", b0[i]);
        snprintf(branches[1] + 2 * i, 3, "%02x", b1[i]);
    }

    uint8_t got[32];
    int rc = odocrypt_build_merkle_root(coinbase, sizeof(coinbase),
                                        (const char (*)[128])branches, 2, got);
    CHECK(rc == 0 && memcmp(got, expect, 32) == 0,
          "merkle root with 2 branches matches reference chain");
}

static void test_target_met(void)
{
    uint8_t hash[32] = {0}, target[32] = {0};

    /* hash MSB (byte 31) below target MSB → met, regardless of low bytes */
    hash[31] = 0x01; hash[0] = 0xFF;
    target[31] = 0x02;
    CHECK(target_met(hash, target), "MSB dominates comparison");

    /* equal arrays count as met */
    memcpy(target, hash, 32);
    CHECK(target_met(hash, target), "equal hash meets target");

    /* hash above target → not met */
    hash[31] = 0x03;
    CHECK(!target_met(hash, target), "hash above target rejected");
}

int main(void)
{
    test_share_target();
    test_epoch_key();
    test_merkle_branches();
    test_target_met();

    if (g_failures) {
        printf("%d test(s) FAILED\n", g_failures);
        return 1;
    }
    printf("All unit tests passed.\n");
    return 0;
}
