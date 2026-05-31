/*
 * hps_regs.h - HPS <-> FPGA register map and shared definitions
 *
 * Memory-mapped interface to the OdoCrypt miner control/status block
 * exposed by the FPGA fabric through the HPS-to-FPGA lightweight bridge
 * (Avalon-MM slave) on the Cyclone V SoC.
 *
 * Register access is 32-bit word aligned. Offsets below are BYTE offsets
 * from the bridge base. The block is mapped read/write via /dev/mem mmap.
 */

#ifndef HPS_REGS_H
#define HPS_REGS_H

#include <stdint.h>

/* ----------------------------------------------------------------------
 * Bridge / mapping geometry
 * --------------------------------------------------------------------*/

/* Lightweight HPS-to-FPGA bridge base on Cyclone V (typical) */
#define LWHPS2FPGA_BASE      0xFF200000UL

/* Byte offset of the miner control block within the bridge window.
 * Set to match the Qsys/Platform Designer assignment for the miner slave. */
#define MINER_BASE_OFFSET    0x00000000UL

/* Size of the region we mmap (one 4 KiB page is plenty for the regs) */
#define MINER_SPAN           0x00001000UL

/* ----------------------------------------------------------------------
 * Register byte offsets (relative to the miner control block base)
 * --------------------------------------------------------------------*/

/* Control / status */
#define REG_CONTROL          0x000   /* W: bit0=start, bit1=reset, bit2=enable */
#define REG_STATUS           0x004   /* R: bit0=busy, bit1=found, bit2=core_rdy */
#define REG_VERSION          0x008   /* R: build/version id */
#define REG_EPOCH            0x00C   /* RW: current OdoCrypt mutation epoch */

/* Nonce range distribution */
#define REG_NONCE_START      0x010   /* W: starting nonce for the array */
#define REG_NONCE_END        0x014   /* W: ending nonce (exclusive) */

/* Result readback */
#define REG_NONCE_FOUND      0x018   /* R: winning nonce (valid when STATUS.found) */
#define REG_CORE_FOUND       0x01C   /* R: index of core that found the nonce */

/* 256-bit target, little-endian words: TARGET[0]=LSW .. TARGET[7]=MSW */
#define REG_TARGET_BASE      0x020   /* R/W: 8 x 32-bit = 0x020..0x03C */
#define REG_TARGET_WORDS     8

/* 80-byte block header (640 bits) staged for hashing.
 * 20 x 32-bit words. Nonce field is filled in hardware per-core. */
#define REG_HEADER_BASE      0x040   /* W: 20 x 32-bit = 0x040..0x08C */
#define REG_HEADER_WORDS     20

/* 256-bit resulting hash of the winning nonce (for verification) */
#define REG_HASH_BASE        0x090   /* R: 8 x 32-bit = 0x090..0x0AC */
#define REG_HASH_WORDS       8

/* Performance counters */
#define REG_PERF_HASHES_LO   0x0B0   /* R: hashes done, low 32 */
#define REG_PERF_HASHES_HI   0x0B4   /* R: hashes done, high 32 */
#define REG_PERF_SHARES      0x0B8   /* R: shares found */
#define REG_PERF_UPTIME      0x0BC   /* R: uptime in clock-derived ticks */

/* ----------------------------------------------------------------------
 * Control bit masks
 * --------------------------------------------------------------------*/
#define CTRL_START           (1u << 0)
#define CTRL_RESET           (1u << 1)
#define CTRL_ENABLE          (1u << 2)
#define CTRL_CLEAR_FOUND     (1u << 3)

#define STAT_BUSY            (1u << 0)
#define STAT_FOUND           (1u << 1)
#define STAT_CORE_READY      (1u << 2)
#define STAT_EPOCH_LOCK      (1u << 3)

/* ----------------------------------------------------------------------
 * mmap helper handle
 * --------------------------------------------------------------------*/
typedef struct {
    int            fd;        /* /dev/mem file descriptor */
    void          *map_base;  /* page-aligned mmap base */
    volatile uint8_t *regs;   /* miner block base (map_base + page offset) */
} miner_io_t;

/* Open /dev/mem and map the miner register block. Returns 0 on success. */
int  miner_io_open(miner_io_t *io);

/* Unmap and close. Safe to call on a partially-initialised handle. */
void miner_io_close(miner_io_t *io);

/* 32-bit register accessors (byte offset). */
static inline uint32_t reg_rd(const miner_io_t *io, uint32_t off)
{
    return *(volatile uint32_t *)(io->regs + off);
}

static inline void reg_wr(const miner_io_t *io, uint32_t off, uint32_t val)
{
    *(volatile uint32_t *)(io->regs + off) = val;
}

#endif /* HPS_REGS_H */
