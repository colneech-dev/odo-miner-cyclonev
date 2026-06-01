/*
 * test_odo_upstream.cpp — Cross-check wrapper around the upstream OdoCrypt C++
 * Outputs both odo_encrypt result and full PoW hash to match test_odo.c format.
 *
 * Produces the same test vectors as test_odo.c using the authoritative
 * upstream implementation. Diff the two outputs to verify our C port is correct.
 *
 * Build:
 *   make test_odo_upstream
 *
 * Usage:
 *   diff <(./test_odo) <(./test_odo_upstream)
 *   → no output means our implementation matches the upstream.
 */

#include "../upstream/odo-miner/src/crypto/odocrypt.h"
extern "C" {
#include "../upstream/odo-miner/src/crypto/KeccakP-800-SnP.h"
}

#include <cstdio>
#include <cstring>
#include <cstdint>

/* Build the same 80-byte header as make_header() in test_odo.c */
static void make_header(uint8_t hdr[80], uint32_t nonce)
{
    memset(hdr, 0, 80);
    uint32_t version = 1;
    memcpy(hdr + 0, &version, 4);
    memset(hdr + 4,  0xAA, 32);
    memset(hdr + 36, 0xBB, 32);
    uint32_t ntime = 0xDEADBEEF;
    memcpy(hdr + 68, &ntime, 4);
    uint32_t nbits = 0x1d00ffff;
    memcpy(hdr + 72, &nbits, 4);
    memcpy(hdr + 76, &nonce, 4);
}

int main(void)
{
    printf("--- Cross-check vectors (compare with test_odo_upstream) ---\n");

    uint32_t test_keys[]   = { 0, 1, 12345, 0xDEADBEEFu };
    uint32_t test_nonces[] = { 0, 1, 0xCAFEBABEu };

    for (size_t ki = 0; ki < sizeof(test_keys)/sizeof(test_keys[0]); ki++) {
        OdoCrypt ciph(test_keys[ki]);

        for (size_t ni = 0; ni < sizeof(test_nonces)/sizeof(test_nonces[0]); ni++) {
            uint8_t hdr[80];
            make_header(hdr, test_nonces[ni]);

            /* odo_encrypt output */
            char enc[OdoCrypt::DIGEST_SIZE];
            ciph.Encrypt(enc, reinterpret_cast<const char *>(hdr));
            printf("key=%08x nonce=%08x out=", test_keys[ki], test_nonces[ni]);
            for (int i = 0; i < OdoCrypt::DIGEST_SIZE; i++)
                printf("%02x", (unsigned char)enc[i]);
            printf("\n");

            /* Full PoW hash: replicate hashodo.h inline to avoid cassert issue */
            uint8_t hash[32];
            make_header(hdr, test_nonces[ni]);
            {
                char state[KeccakP800_stateSizeInBytes] = {};
                memcpy(state, hdr, OdoCrypt::DIGEST_SIZE);
                state[OdoCrypt::DIGEST_SIZE] = 1;
                ciph.Encrypt(state, state);
                KeccakP800_Permute_12rounds(state);
                memcpy(hash, state, 32);
            }
            printf("key=%08x nonce=%08x pow=", test_keys[ki], test_nonces[ni]);
            for (int i = 0; i < 32; i++)
                printf("%02x", hash[i]);
            printf("\n");
        }
    }

    return 0;
}
