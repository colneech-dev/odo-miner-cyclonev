# OdoCrypt Miner — Avalon-MM Register Map

**Status:** v0.2 (matches actual `odocrypt_top.v` + `miner_daemon.c`) · **Owner:** colneech-dev
**Applies to:** `fpga/odocrypt_top.v` (Avalon-MM slave) ↔ `hps/miner_daemon.c` (`mmap` access)

> **Single source of truth.** Any change here MUST be matched in `odocrypt_top.v` and
> `odo_regs.h` in the same commit. Register-map / CDC mismatches are the #1 bring-up
> failure mode for this project. Offsets below are **verified against the current code**,
> not idealized — known caveats are called out explicitly.

---

## 1. Bus Parameters

| Parameter | Value | Notes |
|---|---|---|
| Data width | 32 bits | All registers are 32-bit words. |
| Address unit | Word (4 bytes) | `address[N:0]` indexes 32-bit words, not bytes. The HPS `mmap` pointer is `uint32_t*`, so `base[idx]` already matches word addressing. |
| Endianness | Little-endian | HPS (ARM) and Avalon agree; no byte-swap needed for register access. |
| Byteenable | Ignored | RTL performs full 32-bit read/write only. Do not rely on sub-word writes. |
| Read latency | 1 cycle (registered) | `readdata` is registered; `waitrequest` is tied low (always ready). |
| Reset | Active-high `reset` | Synchronous to the Avalon clock domain. |

The HPS reaches the slave through the **HPS-to-FPGA Lightweight (LWH2F) bridge**.
Bridge base is `0xFF20_0000`; the slave's span base offset is set in Platform Designer.
Effective virtual address = `mmap(LWH2F_base + slave_offset)`.

---

## 2. Register Map

Byte offsets are relative to the slave base. The current RTL and HPS helper use
byte-addressed Avalon offsets, not word indexes.

| Offset | Name | Dir | Description |
|---|---|---|---|
| 0x000 | `CONTROL` | R/W | Start/stop, reset, enable. See §3. |
| 0x004 | `STATUS` | RO | Busy, found, lock, pipeline-valid flags. See §3. |
| 0x008 | `VERSION` | RO | Build/version identifier. |
| 0x00C | `EPOCH` | R/W | Current OdoCrypt epoch number (tweak selector). |
| 0x010 | `NONCE_START` | R/W | Starting nonce for the search range. |
| 0x014 | `NONCE_END` | R/W | Ending nonce (exclusive). |
| 0x018 | `NONCE_FOUND` | RO | Winning nonce, valid when `STATUS.FOUND` is set. |
| 0x01C | `CORE_FOUND` | RO | Optional core ID/index that produced the match. |
| 0x020–0x03C | `TARGET[0..7]` | R/W | 256-bit difficulty target, little-endian words. |
| 0x040–0x08C | `HEADER[0..19]` | R/W | 80-byte block header, 20 × 32-bit words. |
| 0x090–0x0AC | `HASH[0..7]` | RO | 256-bit hash result captured from the pipeline. |
| 0x0B0 | `PERF_HASHES_LO` | RO | Hash count low 32 bits. |
| 0x0B4 | `PERF_HASHES_HI` | RO | Hash count high 32 bits. |
| 0x0B8 | `PERF_SHARES` | RO | Shares found since reset. |
| 0x0BC | `PERF_UPTIME` | RO | Uptime in clock-derived ticks. |

> **Header word count:** the OdoCrypt header is 80 bytes = 20 words, and the RTL
> accepts exactly 20 header words at `HEADER[0..19]`. The HPS job loader currently
> writes just those 20 words.

---

## 3. Field Definitions

### `CONTROL` (0x00, R/W)

| Bit | Name | Description |
|---|---|---|
| 0 | `START` | Write 1 to begin hashing the loaded header/target. Hold high to keep cores running. |
| 1 | `SOFT_RESET` | Write 1 to clear pipelines, counters, and the `found` latch. Self-clears or held per RTL. |
| 2 | `ENABLE` | Master clock-enable for the core array. 0 = cores idle (counters frozen). |
| 31:3 | reserved | Write 0. |

> **Latch clearing:** after reading `NONCE_FOUND`, pulse `SOFT_RESET` (or the
> dedicated ack bit if present in RTL) so `STATUS.FOUND` re-arms for the next hit.

### `STATUS` (0x04, RO)

> **Known RTL bug (BUG-1):** In the current `odocrypt_top.v`, `EPOCH_LOCK` (bit 3)
> always reads **0** due to a Verilog concatenation width error. `STAT_EPOCH_LOCK`
> is a 32-bit constant (`1u << 3`); using it inside `{28'h0, STAT_EPOCH_LOCK, …}`
> makes the concat 63 bits wide and after truncation bit 3 is always 0.
> Fix tracked in `docs/TODO.md` as BUG-1.

| Bit | Name | Description |
|---|---|---|
| 0 | `BUSY` | 1 = core array actively hashing. |
| 1 | `FOUND` | 1 = a nonce meeting target was found; `NONCE_FOUND` is valid. CDC-synced from hash domain. |
| 2 | `CORE_READY` | 1 = core pipeline is ready. Tied high in RTL (reads 1 always). |
| 3 | `EPOCH_LOCK` | 1 = epoch register stable. Intended to be tied high; **currently reads 0 due to BUG-1.** |
| 31:4 | reserved | Reads 0. |

---

## 4. Access Sequences

**Load a job and start (daemon order):**

1. Clear: write `CONTROL = SOFT_RESET` (bit 1), then `CONTROL = 0`.
2. Write `EPOCH`.
3. Write `HEADER[0..19]` (80-byte block header, 20 words).
4. Write `TARGET[0..7]` (word 0 = LSW).
5. Write `NONCE_START`.
6. Start: write `CONTROL = ENABLE | START` (bits 2 and 0).

**Poll for a result:**

1. Read `STATUS`; check `FOUND` (bit 1).
2. On `FOUND`: read `NONCE_FOUND`, submit share.
3. Re-arm: pulse `SOFT_RESET`, then re-assert `ENABLE | START` for the next range.

**Read hashrate:** sample `HASH_COUNT_HI:LO` as a 64-bit value over a known
interval; read HI first then LO, and re-read HI to detect rollover between reads.

---

## 6. Clocking — Current vs. Planned

**Today (single-clock):** the Avalon slave and the core array run on the same
clock. In this mode the CDC primitives (`cdc_sync`, `cdc_found`, `cdc_bus`)
degrade to harmless extra flip-flop stages, and `STATUS.PLL_LOCKED` is not
meaningful (tie it high or ignore it).

**Planned (split-clock):** the hash pipeline moves onto a faster PLL-generated
clock (`hash_pll.v`) while the Avalon side stays on the bridge clock. At that
point:

- `STATUS.FOUND` and `NONCE_FOUND` cross from the hash domain via `cdc_found`
  (flip-flop handshake) — already validated in simulation.
- `HEADER`/`TARGET`/`NONCE_START` cross into the hash domain via `cdc_bus` with
  a load-pulse handshake; the daemon must not retime jobs faster than the
  handshake completes.
- `STATUS.PLL_LOCKED` becomes a real gate: the daemon should wait for it before
  asserting `START`.

No register offsets or bitfields change between the two modes — only the CDC
paths become active. This keeps `odo_regs.h` stable across the transition.

> **CDC note (BUG-7):** `cdc_bus.v` currently assigns `ready_src = ready_dst`
> directly — a domain-crossing without a synchronizer. Harmless in single-clock
> mode; must be fixed before enabling the PLL hash clock.

---

## 7. Known Issues (as of 2026-05-31)

| ID | Severity | Description |
|---|---|---|
| BUG-1 | Medium | `STATUS.EPOCH_LOCK` (bit 3) always reads 0 — concatenation width bug in `odocrypt_top.v:212`. |
| BUG-2 | Low | `odocrypt_core.v`: `busy` driven from two always blocks (multi-driver violation). |
| BUG-3 | High | `odocrypt_array.v` declares 24 header words; core expects 20 — synthesis error. |
| BUG-4 | High | `core_start_pulse` is a one-cycle combinatorial signal; lost if core is busy. |
| BUG-7 | Low | `cdc_bus.v:33` `ready_src = ready_dst` is an unsynced cross-domain signal. |
| ALGO-1 | Critical | `odocrypt_epoch_mutator.v` uses a synthetic formula, not the real Keccak-800 PRNG. |
| ALGO-2 | Critical | `odocrypt_round.v` / `odocrypt_sbox_dsp.v` are approximations; won't produce valid shares. |
| ALGO-3 | High | Target endianness in HPS write vs RTL `<=` comparison is unvalidated. |
| ALGO-4 | Medium | Pipeline nonce alignment (off-by-one risk) needs simulation verification. |
| PERF-1 | Low | `PERF_HASHES` counts busy cycles, not completed hashes — fix to increment on `core_hash_valid`. |

All issues are tracked with fixes in `docs/TODO.md`.
