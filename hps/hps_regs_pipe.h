/* hps_regs_pipe.h — register contract for the PIPELINED OdoCrypt miner.
 *
 * Used by the HPS daemon when the FPGA carries the pipelined core
 * (pipelined_miner_top.v) instead of the sequential FSM (hps_regs.h).
 *
 * The pipelined core free-runs: write the 19-word header + 8-word target, then
 * write REG_PIPE_COMMIT to snapshot them into the 150 MHz domain. The core then
 * sweeps all nonces continuously; poll REG_PIPE_FSTATUS.valid and read
 * REG_PIPE_FNONCE (read-to-consume) to collect found nonces.
 *
 * The epoch is baked into the bitstream; REG_PIPE_SEED reports it so the daemon
 * can verify the loaded bitstream matches the current OdoCrypt epoch and trigger
 * a reconfigure when it does not (Phase 2+). */
#ifndef HPS_REGS_PIPE_H
#define HPS_REGS_PIPE_H

/* Same LW HPS->FPGA window as the FSM build (hps_regs.h). */
#define PIPE_LWHPS2FPGA_BASE   0xFF200000UL
#define PIPE_MINER_BASE_OFFSET 0x00000000UL
#define PIPE_FPGA_BASE         (PIPE_LWHPS2FPGA_BASE + PIPE_MINER_BASE_OFFSET)
#define PIPE_MINER_SPAN        0x00001000UL

#define REG_PIPE_CONTROL   0x000  /* W: bit1 soft_reset (informational)        */
#define REG_PIPE_STATUS    0x004  /* R: bit0 running, bit1 pll_ok, bit2 empty  */
#define REG_PIPE_VERSION   0x008  /* R: 0x0002_xxxx = pipelined                */
#define REG_PIPE_SEED      0x00C  /* R: baked-in epoch (ODOKEY) of this rbf    */

#define REG_PIPE_TARGET_BASE  0x020  /* W: 8 x 32-bit (256-bit target)        */
#define REG_PIPE_TARGET_WORDS 8

#define REG_PIPE_HEADER_BASE  0x040  /* W: 19 x 32-bit (608-bit header, no nonce) */
#define REG_PIPE_HEADER_WORDS 19

#define REG_PIPE_COMMIT    0x08C  /* W: any write -> latch header/target to core */
#define REG_PIPE_FNONCE    0x090  /* R: pop one found nonce (read-to-consume)    */
#define REG_PIPE_FSTATUS   0x094  /* R: bit0 = a found nonce is available        */

/* STATUS / FSTATUS bit fields */
#define PIPE_STAT_RUNNING  (1u << 0)
#define PIPE_STAT_PLL_OK   (1u << 1)
#define PIPE_STAT_EMPTY    (1u << 2)
#define PIPE_FSTAT_VALID   (1u << 0)

#endif /* HPS_REGS_PIPE_H */
