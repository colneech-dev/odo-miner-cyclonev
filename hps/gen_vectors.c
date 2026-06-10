/*
 * gen_vectors.c — known-answer vector generator for the RTL testbench.
 *
 * For a given (epoch_key, nonce) it emits three $readmemh files:
 *   stream.hex : the 5964-word epoch table stream (exact HPS loader order)
 *   header.hex : 20 header words (LE), with the nonce field zeroed —
 *                the FPGA injects the nonce itself
 *   expect.hex : nonce (1 word) + expected 256-bit PoW hash (8 LE words)
 *
 * The expected hash mirrors upstream hashodo.h:
 *   cipher[100] = {header(80) , 0x01, 0...}
 *   OdoCrypt(key).Encrypt(cipher, cipher)        (first 80 bytes)
 *   KeccakP800_Permute_12rounds(cipher)          (full 100-byte state)
 *   hash = cipher[0..31]
 *
 * Build (see Makefile target gen_vectors):
 *   gcc -I. -I../upstream/odo-miner/src/crypto -o gen_vectors gen_vectors.c \
 *       odocrypt_state.c ../upstream/odo-miner/src/crypto/KeccakP-800-reference.c
 *
 * Usage: gen_vectors <epoch_key> <nonce> <outdir>
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
    if (!f) {
        perror(path);
        exit(1);
    }
    for (int i = 0; i < count; i++)
        fprintf(f, "%08x\n", words[i]);
    fclose(f);
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <epoch_key> <nonce> <outdir>\n", argv[0]);
        return 1;
    }

    uint32_t key   = (uint32_t)strtoul(argv[1], NULL, 0);
    uint32_t nonce = (uint32_t)strtoul(argv[2], NULL, 0);
    const char *outdir = argv[3];

    /* --- Epoch tables and stream --- */
    odo_epoch_state_t st;
    odo_epoch_generate(&st, key);

    static uint32_t stream[REG_EPOCH_WR_TOTAL];
    int n = odo_epoch_stream_words(&st, stream);
    if (n != REG_EPOCH_WR_TOTAL) {
        fprintf(stderr, "stream length mismatch: %d\n", n);
        return 1;
    }

    /* --- Deterministic pseudo-random 80-byte header (nonce field zeroed in
     *     the register image; the FPGA injects the nonce itself) --- */
    uint8_t header[80];
    uint32_t x = key ^ 0xDEADBEEF;
    for (int i = 0; i < 80; i++) {
        x = x * 1664525u + 1013904223u;
        header[i] = (uint8_t)(x >> 24);
    }
    header[76] = header[77] = header[78] = header[79] = 0;

    uint32_t header_words[20];
    for (int i = 0; i < 20; i++) {
        header_words[i] = (uint32_t)header[4*i]
                        | ((uint32_t)header[4*i+1] << 8)
                        | ((uint32_t)header[4*i+2] << 16)
                        | ((uint32_t)header[4*i+3] << 24);
    }

    /* --- Expected hash (mirror of upstream hashodo.h) --- */
    uint8_t cipher[KeccakP800_stateSizeInBytes];
    memset(cipher, 0, sizeof(cipher));
    memcpy(cipher, header, 80);
    /* inject the nonce at bytes 76..79 (LE) the way the FPGA does */
    cipher[76] = (uint8_t)(nonce);
    cipher[77] = (uint8_t)(nonce >> 8);
    cipher[78] = (uint8_t)(nonce >> 16);
    cipher[79] = (uint8_t)(nonce >> 24);
    cipher[80] = 1;

    odo_encrypt(&st, cipher, cipher);
    KeccakP800_Permute_12rounds(cipher);

    uint32_t expect[9];
    expect[0] = nonce;
    for (int i = 0; i < 8; i++) {
        expect[1 + i] = (uint32_t)cipher[4*i]
                      | ((uint32_t)cipher[4*i+1] << 8)
                      | ((uint32_t)cipher[4*i+2] << 16)
                      | ((uint32_t)cipher[4*i+3] << 24);
    }

    /* --- Emit files --- */
    char path[512];
    snprintf(path, sizeof(path), "%s/stream.hex", outdir);
    write_hex_file(path, stream, REG_EPOCH_WR_TOTAL);
    snprintf(path, sizeof(path), "%s/header.hex", outdir);
    write_hex_file(path, header_words, 20);
    snprintf(path, sizeof(path), "%s/expect.hex", outdir);
    write_hex_file(path, expect, 9);

    printf("vectors written to %s (key=0x%08x nonce=0x%08x)\n", outdir, key, nonce);
    printf("expected hash (LE bytes): ");
    for (int i = 0; i < 32; i++)
        printf("%02x", cipher[i]);
    printf("\n");
    return 0;
}
