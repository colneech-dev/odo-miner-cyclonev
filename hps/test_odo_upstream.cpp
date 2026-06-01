/*
 * test_odo_upstream.cpp — Cross-check wrapper around the upstream OdoCrypt C++
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
        OdoCrypt cipher(test_keys[ki]);

        for (size_t ni = 0; ni < sizeof(test_nonces)/sizeof(test_nonces[0]); ni++) {
            uint8_t hdr[80];
            make_header(hdr, test_nonces[ni]);

            char out[OdoCrypt::DIGEST_SIZE];
            cipher.Encrypt(out, reinterpret_cast<const char *>(hdr));

            printf("key=%08x nonce=%08x out=", test_keys[ki], test_nonces[ni]);
            for (int i = 0; i < OdoCrypt::DIGEST_SIZE; i++)
                printf("%02x", (unsigned char)out[i]);
            printf("\n");
        }
    }

    return 0;
}
