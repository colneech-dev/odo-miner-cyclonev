/*
 * odocrypt_state.h - OdoCrypt epoch table generator (HPS side)
 *
 * Faithfully replicates the OdoRandom LCG and all table-generation logic from
 * third_party/odo-miner/src/crypto/odocrypt.cpp so the HPS can compute the correct
 * epoch-dependent S-boxes, P-boxes, rotations, and round keys for any epoch key,
 * then load them into the FPGA over MMIO.
 *
 * Algorithm constants match the upstream exactly:
 *   ROUNDS        = 84
 *   STATE_SIZE    = 10 (10 × 64-bit words = 640 bits = 80-byte block header)
 *   SMALL_SBOX    = 6-bit, 64 entries, 40 instances (4 per word)
 *   LARGE_SBOX    = 10-bit, 1024 entries, 10 instances (1 per word)
 *   PBOX_SUBROUNDS = 6
 *   ROTATION_COUNT = 6
 */

#ifndef ODOCRYPT_STATE_H
#define ODOCRYPT_STATE_H

#include <stdint.h>
#include <stddef.h>
#include "hps_regs.h"

/* --- Algorithm dimensions (must match odocrypt.h) --- */
#define ODO_ROUNDS           84
#define ODO_WORD_BITS        64
#define ODO_DIGEST_SIZE      80          /* bytes */
#define ODO_DIGEST_BITS      (ODO_DIGEST_SIZE * 8)   /* 640 */
#define ODO_STATE_SIZE       (ODO_DIGEST_BITS / ODO_WORD_BITS)  /* 10 */

#define ODO_SMALL_SBOX_WIDTH  6
#define ODO_LARGE_SBOX_WIDTH 10
#define ODO_SMALL_SBOX_COUNT (ODO_DIGEST_BITS / (ODO_SMALL_SBOX_WIDTH + ODO_LARGE_SBOX_WIDTH))  /* 40 */
#define ODO_LARGE_SBOX_COUNT  ODO_STATE_SIZE   /* 10 */
#define ODO_SMALL_SBOX_ENTRIES (1 << ODO_SMALL_SBOX_WIDTH)   /* 64 */
#define ODO_LARGE_SBOX_ENTRIES (1 << ODO_LARGE_SBOX_WIDTH)   /* 1024 */

#define ODO_PBOX_SUBROUNDS   6
#define ODO_PBOX_M           3
#define ODO_ROTATION_COUNT   6

/* --- Epoch state: all tables for one epoch key --- */
typedef struct {
    uint32_t key;   /* epoch seed — ntime rounded down to the shapechange
                       interval; see ODO_EPOCH_INTERVAL_MAINNET/TESTNET below */

    /* Substitution boxes */
    uint8_t  sbox1[ODO_SMALL_SBOX_COUNT][ODO_SMALL_SBOX_ENTRIES]; /* 40 × 64  bytes */
    uint16_t sbox2[ODO_LARGE_SBOX_COUNT][ODO_LARGE_SBOX_ENTRIES]; /* 10 × 1024 × 2 bytes */

    /* Permutation boxes (2 of them) */
    struct {
        uint64_t mask    [ODO_PBOX_SUBROUNDS  ][ODO_STATE_SIZE / 2];   /* 6 × 5 uint64 */
        int      rotation[ODO_PBOX_SUBROUNDS-1][ODO_STATE_SIZE / 2];   /* 5 × 5 int */
    } pbox[2];

    /* Linear mixing rotations (6 values, each 1..63) */
    int rotations[ODO_ROTATION_COUNT];

    /* Per-round keys (84 small integers, 0 .. (1<<STATE_SIZE)-1) */
    uint16_t round_key[ODO_ROUNDS];   /* values fit in 10 bits */

} odo_epoch_state_t;

/*
 * Populate all fields of *state from the given 32-bit epoch key.
 * This is the C equivalent of OdoCrypt::OdoCrypt(uint32_t key).
 * Safe to call from any thread; uses no global state.
 */
void odo_epoch_generate(odo_epoch_state_t *state, uint32_t key);

/*
 * Apply the OdoCrypt encryption (odo_encrypt) to an 80-byte plaintext block.
 * Equivalent to OdoCrypt::Encrypt().  Used as a software reference / test oracle.
 * in and out may alias.
 */
void odo_encrypt(const odo_epoch_state_t *state,
                 const uint8_t plain[ODO_DIGEST_SIZE],
                 uint8_t cipher[ODO_DIGEST_SIZE]);

/*
 * OdoCrypt epoch key derivation (DigiByte):
 *   key = ntime - ntime % ODO_EPOCH_INTERVAL
 * i.e. the block time rounded down to the shapechange interval. The interval
 * is 10 days on mainnet and 1 day on testnet (see upstream
 * pool/stratum/header.py odokey_from_ntime).
 */
#define ODO_EPOCH_INTERVAL_MAINNET  (10u * 24u * 60u * 60u)  /* 864000 */
#define ODO_EPOCH_INTERVAL_TESTNET  (24u * 60u * 60u)        /*  86400 */

/*
 * Serialise all epoch tables into the exact 5964-word stream consumed by
 * odocrypt_epoch_tables.v (same order odo_fpga_load_epoch writes over MMIO).
 * out must hold REG_EPOCH_WR_TOTAL words. Returns the word count written,
 * or -1 on bad arguments. Used by the FPGA loader and the RTL testbench
 * vector generator so both always agree.
 */
int odo_epoch_stream_words(const odo_epoch_state_t *state, uint32_t *out);

/*
 * Stream all epoch tables to the FPGA via the REG_EPOCH_WR_DATA register.
 *
 * Call sequence:
 *   odo_epoch_generate(&state, epoch_key);
 *   odo_fpga_load_epoch(&state, io);      // streams 5964 words
 *   reg_wr(io, REG_EPOCH_COMMIT, 1);      // activates new tables
 *   // Wait for STATUS.TABLES_VALID before starting cores.
 *
 * The function writes exactly REG_EPOCH_WR_TOTAL (5964) words in the order
 * expected by odocrypt_epoch_tables.v. The caller must ensure:
 *   - cores are stopped (CTRL_RESET) before calling,
 *   - REG_EPOCH_COMMIT is written after this function returns.
 *
 * Returns 0 on success, -1 if io is NULL or state is NULL.
 */
int odo_fpga_load_epoch(const odo_epoch_state_t *state, const miner_io_t *io);

#endif /* ODOCRYPT_STATE_H */
