/*
 * gen_vectors_pipe.c — known-answer helper for the PIPELINED miner TB (P1.2).
 *
 * The pipelined core bakes the epoch into the bitstream and free-runs, reporting
 * VALID nonces (hash < target) for the committed header. Because it never resets
 * its sweep, the exact nonce it reports depends on timing — so the test checks
 * the reported nonce is a *valid* solution, not a specific one.
 *
 *   gen <key> <target_msb> <outdir>
 *       writes header.hex (19 words = bytes 0..75, LE) and target.hex (8 words),
 *       and prints the first qualifying nonce (informational).
 *   verify <key> <target_msb> <nonce>
 *       recomputes hash(header, nonce) and prints VERIFY_OK if hash < target,
 *       else VERIFY_FAIL.
 *
 * Header bytes + hash math mirror gen_vectors.c, so a VERIFY_OK proves the
 * pipelined RTL == the oracle the FSM was validated against.
 *
 * Build: gcc -I../../hps -I../../third_party/odo-miner/src/crypto -o gen_vectors_pipe \
 *        gen_vectors_pipe.c ../../hps/odocrypt_state.c \
 *        ../../third_party/odo-miner/src/crypto/KeccakP-800-reference.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "odocrypt_state.h"
#include "KeccakP-800-SnP.h"

static void write_hex_file(const char *path, const uint32_t *words, int count)
{
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    for (int i = 0; i < count; i++) fprintf(f, "%08x\n", words[i]);
    fclose(f);
}

/* uint256 strict less-than, LE byte arrays (byte[31] = MSB), == RTL cmp_256. */
static int hash_lt_target(const uint8_t *h, const uint8_t *t)
{
    for (int i = 31; i >= 0; i--)
        if (h[i] != t[i]) return h[i] < t[i];
    return 0;
}

/* Deterministic 80-byte header (bytes 76..79 are the swept nonce field). */
static void build_header(uint32_t key, uint8_t header[80])
{
    uint32_t x = key ^ 0xDEADBEEF;
    for (int i = 0; i < 80; i++) {
        x = x * 1664525u + 1013904223u;
        header[i] = (uint8_t)(x >> 24);
    }
    header[76] = header[77] = header[78] = header[79] = 0;
}

static void build_target(uint32_t target_msb, uint8_t target[32])
{
    memset(target, 0, 32);
    target[31] = (uint8_t)target_msb;   /* target = target_msb * 2^248 */
}

static void hash_nonce(odo_epoch_state_t *st, const uint8_t header[80],
                       uint32_t nonce, uint8_t out[32])
{
    uint8_t cipher[KeccakP800_stateSizeInBytes];
    memset(cipher, 0, sizeof(cipher));
    memcpy(cipher, header, 80);
    cipher[76] = (uint8_t)(nonce);
    cipher[77] = (uint8_t)(nonce >> 8);
    cipher[78] = (uint8_t)(nonce >> 16);
    cipher[79] = (uint8_t)(nonce >> 24);
    cipher[80] = 1;
    odo_encrypt(st, cipher, cipher);
    KeccakP800_Permute_12rounds(cipher);
    memcpy(out, cipher, 32);
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fprintf(stderr, "usage: %s gen|verify <key> <target_msb> <outdir|nonce>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    uint32_t key        = (uint32_t)strtoul(argv[2], NULL, 0);
    uint32_t target_msb = (uint32_t)strtoul(argv[3], NULL, 0);

    odo_epoch_state_t st;
    odo_epoch_generate(&st, key);
    uint8_t header[80], target[32], h[32];
    build_header(key, header);
    build_target(target_msb, target);

    if (!strcmp(mode, "gen")) {
        const char *outdir = argv[4];
        uint32_t header_words[19], target_words[8];
        for (int i = 0; i < 19; i++)
            header_words[i] = (uint32_t)header[4*i] | ((uint32_t)header[4*i+1] << 8)
                            | ((uint32_t)header[4*i+2] << 16) | ((uint32_t)header[4*i+3] << 24);
        for (int i = 0; i < 8; i++)
            target_words[i] = (uint32_t)target[4*i] | ((uint32_t)target[4*i+1] << 8)
                            | ((uint32_t)target[4*i+2] << 16) | ((uint32_t)target[4*i+3] << 24);
        uint32_t first = 0; int got = 0;
        for (uint64_t n = 0; n < (1ull << 24); n++) {
            hash_nonce(&st, header, (uint32_t)n, h);
            if (hash_lt_target(h, target)) { first = (uint32_t)n; got = 1; break; }
        }
        char path[512];
        snprintf(path, sizeof(path), "%s/header.hex", outdir); write_hex_file(path, header_words, 19);
        snprintf(path, sizeof(path), "%s/target.hex", outdir); write_hex_file(path, target_words, 8);
        printf("key=0x%08x target_msb=0x%02x first-qualifying nonce = %u%s\n",
               key, target_msb, first, got ? "" : " (none!)");
        return got ? 0 : 1;
    } else if (!strcmp(mode, "verify")) {
        uint32_t nonce = (uint32_t)strtoul(argv[4], NULL, 0);
        hash_nonce(&st, header, nonce, h);
        int ok = hash_lt_target(h, target);
        printf("verify nonce=0x%08x hash[MSB..]=%02x%02x%02x%02x target_msb=0x%02x -> %s\n",
               nonce, h[31], h[30], h[29], h[28], target_msb, ok ? "VERIFY_OK" : "VERIFY_FAIL");
        return ok ? 0 : 1;
    }
    fprintf(stderr, "unknown mode '%s'\n", mode);
    return 2;
}
