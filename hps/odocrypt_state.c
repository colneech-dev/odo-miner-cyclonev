/*
 * odocrypt_state.c - OdoCrypt epoch table generator
 *
 * Faithful C port of third_party/odo-miner/src/crypto/odocrypt.cpp.
 * Generates the complete per-epoch state (S-boxes, P-boxes, rotations,
 * round keys) from a 32-bit epoch key using the OdoRandom LCG.
 */

#include "odocrypt_state.h"
/* hps_regs.h is included via odocrypt_state.h */

#include <string.h>
#include <stdint.h>

/* -----------------------------------------------------------------------
 * OdoRandom — non-standard LCG (exact port of the C++ class)
 * Each call to NextInt() advances both multiplicand and addend so that
 * every seed generates a unique sequence (not just a different phase).
 * ---------------------------------------------------------------------- */

/* LCG parameters from Knuth (same as upstream) */
#define LCG_MUL  UINT64_C(6364136223846793005)
#define LCG_ADD  UINT64_C(1442695040888963407)

typedef struct {
    uint64_t current;
    uint64_t multiplicand;
    uint64_t addend;
} OdoRandom;

static void odo_rand_init(OdoRandom *r, uint32_t seed)
{
    r->current      = seed;
    r->multiplicand = 1;
    r->addend       = 0;
}

static uint32_t odo_next_int(OdoRandom *r)
{
    r->addend       += r->multiplicand * LCG_ADD;
    r->multiplicand *= LCG_MUL;
    r->current       = r->current * r->multiplicand + r->addend;
    return (uint32_t)(r->current >> 32);
}

static uint64_t odo_next_long(OdoRandom *r)
{
    uint64_t hi = odo_next_int(r);
    return (hi << 32) | odo_next_int(r);
}

/* Returns a uniform value in [0, N) */
static int odo_next_n(OdoRandom *r, int N)
{
    return (int)(((uint64_t)odo_next_int(r) * (uint32_t)N) >> 32);
}

/* Fisher-Yates shuffle on an int array of length sz */
static void odo_permutation_int(OdoRandom *r, int *arr, int sz)
{
    for (int i = 0; i < sz; i++)
        arr[i] = i;
    for (int i = 1; i < sz; i++) {
        int j = odo_next_n(r, i + 1);
        int tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
    }
}

/* Fisher-Yates shuffle on a uint8_t array of length sz */
static void odo_permutation_u8(OdoRandom *r, uint8_t *arr, int sz)
{
    for (int i = 0; i < sz; i++)
        arr[i] = (uint8_t)i;
    for (int i = 1; i < sz; i++) {
        int j = odo_next_n(r, i + 1);
        uint8_t tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
    }
}

/* Fisher-Yates shuffle on a uint16_t array of length sz */
static void odo_permutation_u16(OdoRandom *r, uint16_t *arr, int sz)
{
    for (int i = 0; i < sz; i++)
        arr[i] = (uint16_t)i;
    for (int i = 1; i < sz; i++) {
        int j = odo_next_n(r, i + 1);
        uint16_t tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
    }
}

/* -----------------------------------------------------------------------
 * Table generation — exact port of OdoCrypt::OdoCrypt(uint32_t key)
 * ---------------------------------------------------------------------- */

void odo_epoch_generate(odo_epoch_state_t *s, uint32_t key)
{
    OdoRandom r;
    odo_rand_init(&r, key);
    s->key = key;

    /* Small S-boxes: 40 independent permutations of [0..63] */
    for (int i = 0; i < ODO_SMALL_SBOX_COUNT; i++)
        odo_permutation_u8(&r, s->sbox1[i], ODO_SMALL_SBOX_ENTRIES);

    /* Large S-boxes: 10 independent permutations of [0..1023] */
    for (int i = 0; i < ODO_LARGE_SBOX_COUNT; i++)
        odo_permutation_u16(&r, s->sbox2[i], ODO_LARGE_SBOX_ENTRIES);

    /* P-boxes: 2 boxes, each with PBOX_SUBROUNDS masks and PBOX_SUBROUNDS-1 rotations */
    for (int p = 0; p < 2; p++) {
        for (int j = 0; j < ODO_PBOX_SUBROUNDS; j++)
            for (int k = 0; k < ODO_STATE_SIZE / 2; k++)
                s->pbox[p].mask[j][k] = odo_next_long(&r);
        for (int j = 0; j < ODO_PBOX_SUBROUNDS - 1; j++)
            for (int k = 0; k < ODO_STATE_SIZE / 2; k++)
                s->pbox[p].rotation[j][k] = odo_next_n(&r, ODO_WORD_BITS - 1) + 1;
    }

    /* Global rotations: ROTATION_COUNT values, distinct, non-zero, odd sum.
     * Algorithm: permute [1..63], pick first ROTATION_COUNT-1, then find
     * the next value that makes the total sum odd. */
    {
        int bits[ODO_WORD_BITS - 1];
        odo_permutation_int(&r, bits, ODO_WORD_BITS - 1);
        /* bits[i] is 0..(WORD_BITS-2), rotation = bits[i]+1 is 1..(WORD_BITS-1) */
        int sum = 0;
        for (int j = 0; j < ODO_ROTATION_COUNT - 1; j++) {
            s->rotations[j] = bits[j] + 1;
            sum += s->rotations[j];
        }
        for (int j = ODO_ROTATION_COUNT - 1; ; j++) {
            if ((bits[j] + 1 + sum) % 2) {
                s->rotations[ODO_ROTATION_COUNT - 1] = bits[j] + 1;
                break;
            }
        }
    }

    /* Round keys: 84 small integers in [0, 1<<STATE_SIZE) = [0, 1024) */
    for (int i = 0; i < ODO_ROUNDS; i++)
        s->round_key[i] = (uint16_t)odo_next_n(&r, 1 << ODO_STATE_SIZE);
}

/* -----------------------------------------------------------------------
 * OdoCrypt encrypt — software reference implementation
 * Exact port of OdoCrypt::Encrypt().
 * ---------------------------------------------------------------------- */

static inline uint64_t rot64(uint64_t x, int r)
{
    return r == 0 ? x : (x << r) ^ (x >> (64 - r));
}

/* Unpack 80 bytes little-endian into 10 × 64-bit words */
static void odo_unpack(uint64_t state[ODO_STATE_SIZE], const uint8_t bytes[ODO_DIGEST_SIZE])
{
    for (int i = 0; i < ODO_STATE_SIZE; i++) {
        state[i] = 0;
        for (int j = 0; j < 8; j++)
            state[i] |= (uint64_t)bytes[8 * i + j] << (8 * j);
    }
}

/* Pack 10 × 64-bit words into 80 bytes little-endian */
static void odo_pack(const uint64_t state[ODO_STATE_SIZE], uint8_t bytes[ODO_DIGEST_SIZE])
{
    for (int i = 0; i < ODO_STATE_SIZE; i++)
        for (int j = 0; j < 8; j++)
            bytes[8 * i + j] = (uint8_t)((state[i] >> (8 * j)) & 0xff);
}

/* PreMix: XOR all words together, fold the XOR, XOR back into each word */
static void odo_premix(uint64_t state[ODO_STATE_SIZE])
{
    uint64_t total = 0;
    for (int i = 0; i < ODO_STATE_SIZE; i++)
        total ^= state[i];
    total ^= total >> 32;
    for (int i = 0; i < ODO_STATE_SIZE; i++)
        state[i] ^= total;
}

/* ApplyMaskedSwaps: for each adjacent pair, swap bits indicated by mask */
static void odo_masked_swaps(uint64_t state[ODO_STATE_SIZE], const uint64_t mask[ODO_STATE_SIZE / 2])
{
    for (int i = 0; i < ODO_STATE_SIZE / 2; i++) {
        uint64_t *a = &state[2 * i];
        uint64_t *b = &state[2 * i + 1];
        uint64_t swp = mask[i] & (*a ^ *b);
        *a ^= swp;
        *b ^= swp;
    }
}

/* ApplyWordShuffle: permute words by stride m (PBOX_M=3) */
static void odo_word_shuffle(uint64_t state[ODO_STATE_SIZE], int m)
{
    uint64_t next[ODO_STATE_SIZE];
    for (int i = 0; i < ODO_STATE_SIZE; i++)
        next[(m * i) % ODO_STATE_SIZE] = state[i];
    memcpy(state, next, sizeof(next));
}

/* ApplyPboxRotations: rotate even-indexed words */
static void odo_pbox_rotations(uint64_t state[ODO_STATE_SIZE], const int rotation[ODO_STATE_SIZE / 2])
{
    for (int i = 0; i < ODO_STATE_SIZE / 2; i++)
        state[2 * i] = rot64(state[2 * i], rotation[i]);
}

/* ApplyPbox: 6 subrounds of masked-swap → word-shuffle(×3) → rotation */
static void odo_apply_pbox(uint64_t state[ODO_STATE_SIZE],
                           const uint64_t mask    [ODO_PBOX_SUBROUNDS    ][ODO_STATE_SIZE / 2],
                           const int      rotation[ODO_PBOX_SUBROUNDS - 1][ODO_STATE_SIZE / 2])
{
    for (int i = 0; i < ODO_PBOX_SUBROUNDS - 1; i++) {
        odo_masked_swaps(state, mask[i]);
        odo_word_shuffle(state, ODO_PBOX_M);
        odo_pbox_rotations(state, rotation[i]);
    }
    odo_masked_swaps(state, mask[ODO_PBOX_SUBROUNDS - 1]);
}

/* ApplySboxes: substitute each 64-bit word using 4 small + 4 large S-boxes interleaved */
static void odo_apply_sboxes(uint64_t state[ODO_STATE_SIZE],
                             const uint8_t  sbox1[ODO_SMALL_SBOX_COUNT][ODO_SMALL_SBOX_ENTRIES],
                             const uint16_t sbox2[ODO_LARGE_SBOX_COUNT][ODO_LARGE_SBOX_ENTRIES])
{
    const uint64_t MASK1 = ODO_SMALL_SBOX_ENTRIES - 1;  /* 0x3F */
    const uint64_t MASK2 = ODO_LARGE_SBOX_ENTRIES - 1;  /* 0x3FF */

    int small_idx = 0;
    for (int i = 0; i < ODO_STATE_SIZE; i++) {
        uint64_t next = 0;
        int pos = 0;
        int large_idx = i;
        for (int j = 0; j < ODO_SMALL_SBOX_COUNT / ODO_STATE_SIZE; j++) {
            next |= (uint64_t)sbox1[small_idx][(state[i] >> pos) & MASK1] << pos;
            pos  += ODO_SMALL_SBOX_WIDTH;
            next |= (uint64_t)sbox2[large_idx][(state[i] >> pos) & MASK2] << pos;
            pos  += ODO_LARGE_SBOX_WIDTH;
            small_idx++;
        }
        state[i] = next;
    }
}

/* ApplyRotations: state[i] ^= Rot(state[i], r) for each rotation r;
 * also rotates the entire word array by 1 position first. */
static void odo_apply_rotations(uint64_t state[ODO_STATE_SIZE], const int rotations[ODO_ROTATION_COUNT])
{
    uint64_t next[ODO_STATE_SIZE];
    /* rotate_copy(state, state+1, state+STATE_SIZE, next) */
    for (int i = 0; i < ODO_STATE_SIZE - 1; i++)
        next[i] = state[i + 1];
    next[ODO_STATE_SIZE - 1] = state[0];

    for (int i = 0; i < ODO_STATE_SIZE; i++)
        for (int j = 0; j < ODO_ROTATION_COUNT; j++)
            next[i] ^= rot64(state[i], rotations[j]);

    memcpy(state, next, sizeof(next));
}

/* ApplyRoundKey: XOR state[i] with bit i of the round key integer */
static void odo_apply_round_key(uint64_t state[ODO_STATE_SIZE], uint16_t rk)
{
    for (int i = 0; i < ODO_STATE_SIZE; i++)
        state[i] ^= (rk >> i) & 1u;
}

/* -----------------------------------------------------------------------
 * FPGA epoch table loader
 *
 * Streams 5964 32-bit words into REG_EPOCH_WR_DATA in the exact order
 * expected by odocrypt_epoch_tables.v:
 *
 *   [   0.. 639]  Small S-boxes:   640 words  (40 × 64 entries, 4 × 8-bit per word)
 *   [ 640..5759]  Large S-boxes:  5120 words  (10 × 1024 entries, 2 × 16-bit per word)
 *   [5760..5819]  Pbox-0 masks:     60 words  (6 rounds × 5 lanes, 2 words / 64-bit)
 *   [5820..5844]  Pbox-0 rotations: 25 words  (5 rounds × 5 lanes, 6-bit each)
 *   [5845..5904]  Pbox-1 masks:     60 words
 *   [5905..5929]  Pbox-1 rotations: 25 words
 *   [5930..5935]  Global rotations:  6 words  (6-bit each)
 *   [5936..5963]  Round keys:       28 words  (3 × 10-bit per word)
 * ---------------------------------------------------------------------- */
int odo_epoch_stream_words(const odo_epoch_state_t *s, uint32_t *out)
{
    if (!s || !out)
        return -1;

    int n = 0;
#define WR(val) (out[n++] = (uint32_t)(val))

    /* Small S-boxes: 4 entries per word, 8-bit each */
    for (int si = 0; si < ODO_SMALL_SBOX_COUNT; si++) {
        for (int e = 0; e < ODO_SMALL_SBOX_ENTRIES; e += 4) {
            uint32_t w = (uint32_t)s->sbox1[si][e+0]
                       | ((uint32_t)s->sbox1[si][e+1] << 8)
                       | ((uint32_t)s->sbox1[si][e+2] << 16)
                       | ((uint32_t)s->sbox1[si][e+3] << 24);
            WR(w);
        }
    }

    /* Large S-boxes: 2 entries per word, 16-bit each (10-bit values) */
    for (int si = 0; si < ODO_LARGE_SBOX_COUNT; si++) {
        for (int e = 0; e < ODO_LARGE_SBOX_ENTRIES; e += 2) {
            uint32_t w = (uint32_t)s->sbox2[si][e+0]
                       | ((uint32_t)s->sbox2[si][e+1] << 16);
            WR(w);
        }
    }

    /* P-boxes: write per-pbox (masks then rotations for each pbox separately).
     * RTL address map: pbox-0 masks [5760..5819], pbox-0 rots [5820..5844],
     *                  pbox-1 masks [5845..5904], pbox-1 rots [5905..5929].
     * Writing all masks then all rotations (as done previously) would place
     * pbox-1 masks at the pbox-0 rotation addresses — silent wrong tables. */
    for (int p = 0; p < 2; p++) {
        /* Masks: 6 subrounds × 5 lanes × 2 words (lo then hi of each 64-bit mask) */
        for (int j = 0; j < ODO_PBOX_SUBROUNDS; j++) {
            for (int k = 0; k < ODO_STATE_SIZE / 2; k++) {
                uint64_t m = s->pbox[p].mask[j][k];
                WR((uint32_t)m);
                WR((uint32_t)(m >> 32));
            }
        }
        /* Rotations: (PBOX_SUBROUNDS-1)=5 subrounds × 5 lanes, one word each */
        for (int j = 0; j < ODO_PBOX_SUBROUNDS - 1; j++) {
            for (int k = 0; k < ODO_STATE_SIZE / 2; k++) {
                WR((uint32_t)s->pbox[p].rotation[j][k]);
            }
        }
    }

    /* Global rotations: one word each */
    for (int r = 0; r < ODO_ROTATION_COUNT; r++)
        WR((uint32_t)s->rotations[r]);

    /* Round keys: 3 × 10-bit packed per word */
    for (int r = 0; r < ODO_ROUNDS; r += 3) {
        uint32_t w = (uint32_t)s->round_key[r];
        if (r + 1 < ODO_ROUNDS) w |= (uint32_t)s->round_key[r+1] << 10;
        if (r + 2 < ODO_ROUNDS) w |= (uint32_t)s->round_key[r+2] << 20;
        WR(w);
    }

#undef WR
    return n;
}

int odo_fpga_load_epoch(const odo_epoch_state_t *s, const miner_io_t *io)
{
    static uint32_t words[REG_EPOCH_WR_TOTAL];

    if (!s || !io)
        return -1;

    int n = odo_epoch_stream_words(s, words);
    if (n != REG_EPOCH_WR_TOTAL)
        return -1;

    for (int i = 0; i < n; i++)
        reg_wr(io, REG_EPOCH_WR_DATA, words[i]);

    return 0;
}

void odo_encrypt(const odo_epoch_state_t *s,
                 const uint8_t plain[ODO_DIGEST_SIZE],
                 uint8_t cipher[ODO_DIGEST_SIZE])
{
    uint64_t state[ODO_STATE_SIZE];
    odo_unpack(state, plain);
    odo_premix(state);

    for (int round = 0; round < ODO_ROUNDS; round++) {
        odo_apply_pbox(state, s->pbox[0].mask, s->pbox[0].rotation);
        odo_apply_sboxes(state, s->sbox1, s->sbox2);
        odo_apply_pbox(state, s->pbox[1].mask, s->pbox[1].rotation);
        odo_apply_rotations(state, s->rotations);
        odo_apply_round_key(state, s->round_key[round]);
    }

    odo_pack(state, cipher);
}
