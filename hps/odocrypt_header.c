#include "odocrypt_header.h"

#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* ---------------------------------------------------------------------- */
/* Local SHA-256 implementation for double-hash / merkle root building. */
/* ---------------------------------------------------------------------- */

static const uint32_t K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

static uint32_t rotr32(uint32_t x, uint32_t n)
{
    return (x >> n) | (x << (32 - n));
}

static void sha256_transform(uint32_t state[8], const uint8_t block[64])
{
    uint32_t w[64];
    for (int i = 0; i < 16; ++i) {
        w[i] = ((uint32_t)block[4 * i] << 24) |
               ((uint32_t)block[4 * i + 1] << 16) |
               ((uint32_t)block[4 * i + 2] << 8) |
               ((uint32_t)block[4 * i + 3]);
    }
    for (int i = 16; i < 64; ++i) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint32_t a = state[0];
    uint32_t b = state[1];
    uint32_t c = state[2];
    uint32_t d = state[3];
    uint32_t e = state[4];
    uint32_t f = state[5];
    uint32_t g = state[6];
    uint32_t h = state[7];

    for (int i = 0; i < 64; ++i) {
        uint32_t S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t ch = (e & f) ^ ((~e) & g);
        uint32_t temp1 = h + S1 + ch + K[i] + w[i];
        uint32_t S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t temp2 = S0 + maj;

        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }

    state[0] += a;
    state[1] += b;
    state[2] += c;
    state[3] += d;
    state[4] += e;
    state[5] += f;
    state[6] += g;
    state[7] += h;
}

static void sha256(const uint8_t *data, size_t len, uint8_t digest[32])
{
    uint32_t state[8] = {
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
    };

    uint8_t block[64];
    size_t filled = 0;
    uint64_t bitlen = 0;

    while (len > 0) {
        size_t chunk = (len < (64 - filled)) ? len : (64 - filled);
        memcpy(block + filled, data, chunk);
        filled += chunk;
        data += chunk;
        len -= chunk;
        bitlen += (uint64_t)chunk * 8ull;

        if (filled == 64) {
            sha256_transform(state, block);
            filled = 0;
        }
    }

    block[filled++] = 0x80;
    if (filled > 56) {
        while (filled < 64)
            block[filled++] = 0x00;
        sha256_transform(state, block);
        filled = 0;
    }
    while (filled < 56)
        block[filled++] = 0x00;

    block[56] = (uint8_t)(bitlen >> 56);
    block[57] = (uint8_t)(bitlen >> 48);
    block[58] = (uint8_t)(bitlen >> 40);
    block[59] = (uint8_t)(bitlen >> 32);
    block[60] = (uint8_t)(bitlen >> 24);
    block[61] = (uint8_t)(bitlen >> 16);
    block[62] = (uint8_t)(bitlen >> 8);
    block[63] = (uint8_t)(bitlen);
    sha256_transform(state, block);

    for (int i = 0; i < 8; ++i) {
        digest[4 * i + 0] = (uint8_t)(state[i] >> 24);
        digest[4 * i + 1] = (uint8_t)(state[i] >> 16);
        digest[4 * i + 2] = (uint8_t)(state[i] >> 8);
        digest[4 * i + 3] = (uint8_t)(state[i]);
    }
}

static size_t hex_to_bytes(const char *hex, uint8_t *out, size_t max_out)
{
    size_t len = strlen(hex);
    if ((len & 1u) != 0 || (len / 2u) > max_out)
        return 0;

    for (size_t i = 0; i < len / 2; ++i) {
        char hi = hex[2 * i];
        char lo = hex[2 * i + 1];
        uint8_t value_hi;
        uint8_t value_lo;
        if ((hi >= '0' && hi <= '9'))
            value_hi = (uint8_t)(hi - '0');
        else if (hi >= 'a' && hi <= 'f')
            value_hi = (uint8_t)(10 + hi - 'a');
        else if (hi >= 'A' && hi <= 'F')
            value_hi = (uint8_t)(10 + hi - 'A');
        else
            return 0;
        if ((lo >= '0' && lo <= '9'))
            value_lo = (uint8_t)(lo - '0');
        else if (lo >= 'a' && lo <= 'f')
            value_lo = (uint8_t)(10 + lo - 'a');
        else if (lo >= 'A' && lo <= 'F')
            value_lo = (uint8_t)(10 + lo - 'A');
        else
            return 0;
        out[i] = (uint8_t)((value_hi << 4) | value_lo);
    }
    return len / 2;
}


void odocrypt_double_sha256(const uint8_t *data, size_t len, uint8_t out[32])
{
    uint8_t tmp[32];
    sha256(data, len, tmp);
    sha256(tmp, 32, out);
}

int odocrypt_build_merkle_root(const uint8_t *coinbase,
                               size_t coinbase_len,
                               const char merkle_hex[][128],
                               size_t merkle_count,
                               uint8_t out_root[32])
{
    if (!coinbase || !out_root)
        return -1;

    uint8_t root[32];
    odocrypt_double_sha256(coinbase, coinbase_len, root);

    for (size_t i = 0; i < merkle_count; ++i) {
        uint8_t branch[32];
        if (hex_to_bytes(merkle_hex[i], branch, sizeof(branch)) != sizeof(branch))
            return -1;
        uint8_t concat[64];
        memcpy(concat, root, 32);
        memcpy(concat + 32, branch, 32);
        odocrypt_double_sha256(concat, sizeof(concat), root);
    }

    memcpy(out_root, root, 32);
    return 0;
}

int odocrypt_build_header(const job_t *job, uint8_t out_header[JOB_HEADER_BYTES])
{
    if (!job || !out_header)
        return -1;

    memset(out_header, 0, JOB_HEADER_BYTES);

    uint32_t version_le = job->version;
    uint32_t ntime_le = job->ntime;
    uint32_t nbits_le = job->nbits;

    memcpy(out_header, &version_le, sizeof(version_le));
    memcpy(out_header + 4, job->prevhash, 32);
    memcpy(out_header + 36, job->merkle_root, 32);
    memcpy(out_header + 68, &ntime_le, sizeof(ntime_le));
    memcpy(out_header + 72, &nbits_le, sizeof(nbits_le));

    return 0;
}
