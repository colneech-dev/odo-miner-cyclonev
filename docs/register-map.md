# OdoCrypt Miner — Avalon-MM Register Map

**Status:** v1.1 (2026-06-26, matches `pipelined_miner_top.v` + `hps/hps_regs_pipe.h`; UIO IRQ added) · **Owner:** colneech-dev
**Applies to:** the **deployed pipelined core** — `hdl/src/pipelined/pipelined_miner_top.v` (Avalon-MM slave) ↔ `hps/hps_regs_pipe.h` / `hps/miner_io_pipe.c`

> **Single source of truth.** Any change here MUST be matched in
> `pipelined_miner_top.v` and `hps/hps_regs_pipe.h` in the same commit.
> Register-map mismatches are the #1 bring-up failure mode for this project.
>
> **Legacy FSM core:** the older sequential-FSM miner (`hdl/src/odocrypt_top.v`,
> `hps/hps_regs.h`, driven by `hps/miner.c`) has a *different*, table-streaming
> register map and is **not deployed**. It is retained for the `miner.c` path
> only; its contract lives in `hps/hps_regs.h`. The FSM map and its historical
> bring-up bug list were removed from this doc on 2026-06-22 — they described a
> core that no longer ships and an algorithm since proven bit-exact (the board
> has mined 485+ blocks).

---

## 1. Deployed configuration

| Item | Value | Source |
|---|---|---|
| Core | Pipelined `odo_encrypt` (epoch baked into LUTs), free-running nonce sweep | `pipelined_miner_top.v` |
| THROUGHPUT | **6** (a new nonce every 6 miner-clock cycles) | `odo_miner.qsf` VERILOG_MACRO |
| Miner clock | **156.25 MHz** (fabric PLL ×25/8, `soc_top.v` `u_pll_miner`) | `soc_top.v` |
| Raw rate | 156.25 MHz / 6 ≈ **26.0 MH/s** | derived |
| Baked epoch (ODOKEY) | 1782432000 (per-bitstream; read back at `SEED`) | `odo_miner.qsf` |

> The free-running core has no hardware hash counter; the daemon reports a
> statistical hashrate (`work_acc / uptime`, see `miner_pipe.c:share_work`), so
> the "effective" MH/s on the dashboard is an estimate, not a sweep count.

---

## 2. Bus parameters

| Parameter | Value | Notes |
|---|---|---|
| Data width | 32 bits | All registers are 32-bit words. |
| Address unit | **Byte (SYMBOLS)** | `avs_address[7:0]` is a byte offset (0x00, 0x04, …). `pipelined_miner_hw.tcl` declares `addressUnits SYMBOLS` — never change it. |
| Endianness | Little-endian | HPS (ARM) and Avalon agree; no byte-swap for register access. |
| Read/write | Full 32-bit only | No byteenable; sub-word access unsupported. |
| `waitrequest` | Tied 0 | Single-cycle access; the pipelined core never stalls the bus. |
| Reset | Active-low `reset_n` | Synchronous deassert, Avalon (55 MHz) clock domain. |
| CDC | Internal | Header/target cross 55→156.25 MHz via a commit-toggle handshake; found nonces cross 156.25→55 MHz via a depth-8 dual-clock async FIFO (Gray-code pointers). See the wrapper header comment. |

The HPS reaches the slave through the **HPS-to-FPGA Lightweight (LWH2F) bridge**;
base `0xFF20_0000`, miner slave at offset **0x0000** (`PIPE_MINER_BASE_OFFSET = 0`),
span `0x1000` (`PIPE_MINER_SPAN`).

### System LWH2F address map (Platform Designer)

| LW offset | Peripheral | Linux driver |
|---|---|---|
| 0x0000 | Pipelined OdoCrypt miner (this block) | none — daemon uses /dev/mem (or UIO, see below) |
| 0x1000 | `spi_lcd` Avalon SPI (ILI9341, ~25 MHz) | spi-altera-platform + fbtft |
| 0x1100 | `spi_touch` Avalon SPI (XPT2046, ~1.56 MHz) | spi-altera-platform + ads7846 |
| 0x1200 | `pio_lcd` 3-bit out (D/C, RESET_n, BL) | gpio-altera |
| 0x1300 | `pio_in` 3-bit in + IRQ (PENIRQ_n, KEY0, KEY1) | gpio-altera |
| 0x1400 | `pio_led` 8-bit out (board LEDs) | gpio-altera + gpio-leds |

FPGA→HPS interrupts (f2h_irq0): 0 = spi_lcd, 1 = spi_touch, 2 = pio_in
(Linux GIC SPI 72/73/74).

> **Found-nonce interrupt (DEPLOYED 2026-06-25):** a level interrupt
> (= `FSTATUS.valid`) on `f2h_irq0` line 3 (GIC SPI 75) lets the daemon block
> on a found nonce instead of polling. RTL/Qsys/kernel/DTS all on `main`;
> `/dev/uio0` present on board; `backend: "uio"` active. See
> `docs/uio-miner-io-scope.md`.

---

## 3. Register map (pipelined core)

Byte offsets relative to the slave base. Mirrors `hps/hps_regs_pipe.h` exactly.

| Offset | Name | Dir | Description |
|---|---|---|---|
| 0x000 | `CONTROL` | W | bit1 = `soft_reset` (informational; the core free-runs). |
| 0x004 | `STATUS` | R | bit0 `running` (1), bit1 `pll_ok` (1), bit2 `empty` (no found nonce pending), bit3 `fifo_overflow` (sticky: a found nonce was dropped because the FIFO was full; clears only on reset). |
| 0x008 | `VERSION` | R | `0x0002_0000` — the high half (0x0002) marks the pipelined core. |
| 0x00C | `SEED` | R | Baked-in epoch (`ODOKEY`) of this bitstream. Compare against the job's epoch; a mismatch means the FPGA must be reconfigured (epoch renewal). |
| 0x020–0x03C | `TARGET[0..7]` | W | 256-bit share target, little-endian words (word 0 = LSW). |
| 0x040–0x088 | `HEADER[0..18]` | W | 19 words = header bytes 0..75. Bytes 76..79 are swept internally as the nonce — do **not** write a nonce. |
| 0x08C | `COMMIT` | W | Any write snapshots HEADER+TARGET into the 156.25 MHz domain and arms the settle window (drains stale pre-commit pipeline results). |
| 0x090 | `FNONCE` | R | Pop one found nonce. **Read-to-consume**: the read advances the found FIFO's read pointer. |
| 0x094 | `FSTATUS` | R | bit0 = a found nonce is available (`PIPE_FSTAT_VALID`). |

> **Header is 19 words, not 20.** The pipelined core owns the nonce field, so the
> HPS writes only bytes 0..75. (The legacy FSM core took 20 words including a
> host-supplied nonce — a key difference if porting code between the two.)

---

## 4. Access sequences

**Load a job (daemon order, `miner_io_pipe_dispatch`):**

1. Write `HEADER[0..18]` (19 words, header bytes 0..75).
2. Write `TARGET[0..7]` (share target, word 0 = LSW).
3. Write `COMMIT` (any value) — snapshots into the miner domain.

There is no start/stop and no nonce range: the core sweeps all 2³² nonces
continuously and latches any hash ≤ target.

**Collect results (`miner_io_pipe_poll`, drain loop):**

1. Read `FSTATUS`; if bit0 clear, nothing pending — done for now.
2. Read `FNONCE` (consumes the entry); validate the nonce against the *current*
   job with the software oracle (this is also the stale-job guard — a nonce for
   a pre-commit header recomputes to a non-qualifying hash and is dropped), then
   submit if it meets the share target.
3. Repeat until `FSTATUS` reads empty.

> Found nonces are buffered in a **depth-8 dual-clock async FIFO** (Gray-code
> pointer CDC), so a burst of finds is held rather than dropped while the HPS
> drains them. The producer is a 1-cycle `found` strobe from the core (each find
> pushed exactly once); a strobe arriving while the FIFO is full is dropped and
> latches `STATUS.fifo_overflow` (bit3) for observability. Hardware-verified
> (finds delivered + pool-accepted, 0 rejected). The FIFO holds the full 8
> entries and drops the newest on overflow; regression: `hdl/tb/run_tb_fifo.sh`
> (burst/overflow/in-order-drain/irq-level) alongside the bit-exact
> `run_tb_pipe.sh`.

---

## 5. Notes

- **Epoch renewal:** the epoch is baked into the bitstream, so a new OdoCrypt
  epoch needs a new `.rbf` (off-board precompile) + reconfigure, not a register
  write. The daemon detects the need by `job.epoch != SEED` and the autonomy
  path swaps the bitstream + reboots (see `usr/sbin/epoch-update.sh`,
  `docs/TODO.md`).
- **Verification:** `hdl/tb/run_tb_pipe.sh` drives this exact register interface
  in simulation and checks the found nonce against the C oracle (== upstream
  `odocrypt.cpp`). Run it after any change to the wrapper or core.
