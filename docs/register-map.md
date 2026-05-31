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

Word offsets are relative to the slave base. Byte offset = word offset × 4.

| Word | Byte | Name | Dir | Description |
|---|---|---|---|---|
| 0x00 | 0x00 | `CONTROL` | R/W | Start/stop, reset, enable. See §3. |
| 0x01 | 0x04 | `STATUS` | RO | Busy, found, lock, pipeline-valid flags. See §3. |
| 0x02 | 0x08 | `NONCE_FOUND` | RO | Winning nonce, latched on `found` (CDC-synced). |
| 0x03 | 0x0C | `EPOCH` | R/W | Current OdoCrypt epoch number (tweak selector). |
| 0x04–0x1B | 0x10–0x6C | `HEADER[0..23]` | R/W | 80-byte block header (24 × 32-bit words; word 23 holds tail/padding). |
| 0x1C–0x23 | 0x70–0x8C | `TARGET[0..7]` | R/W | 256-bit difficulty target, word 0 = LSW. |
| 0x24 | 0x90 | `NONCE_START` | R/W | Base nonce; cores stripe upward from here. |
| 0x25 | 0x94 | `HASH_COUNT_LO` | RO | Performance counter, low 32 bits. |
| 0x26 | 0x98 | `HASH_COUNT_HI` | RO | Performance counter, high 32 bits. |
| 0x27 | 0x9C | `SHARE_COUNT` | RO | Shares (target hits) since last reset. |

> **Header word count:** the OdoCrypt header is 80 bytes = 20 words, but the map
> reserves 24 words (`HEADER[0..23]`) so the daemon can write the full pre-padded
> input block in one contiguous burst without a separate padding register.

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

### `STATUS` (0x01, RO)

| Bit | Name | Description |
|---|---|---|
| 0 | `BUSY` | 1 = core array actively hashing. |
| 1 | `FOUND` | 1 = a nonce meeting target was found; `NONCE_FOUND` is valid. CDC-synced from hash domain. |
| 2 | `PLL_LOCKED` | 1 = hash-pipeline PLL locked (relevant once clocks are split; see §6). |
| 3 | `PIPE_VALID` | 1 = pipeline primed / first valid results available. |
| 31:4 | reserved | Reads 0. |

---

## 4. Known Caveat — 4-bit Address Decode

The current `odocrypt_top.v` decodes the Avalon `address` with a **narrow case
statement** that only resolves the low address bits. If the RTL declares
`address[3:0]` (4 bits), it can uniquely select **only 16 word locations
(0x00–0x0F)**.

This is a real mismatch with the map above, which extends to word 0x27:

- Registers at **0x10 and beyond** (the `HEADER`, `TARGET`, counters) either
  **alias** back onto 0x00–0x0F, or hit the `default` branch and silently
  read 0 / drop writes — depending on how the `case` default is coded.
- This will not surface in a simple CONTROL/STATUS smoke test, but **will** break
  header/target loading and counter readback during real mining.

**Required fix (RTL side):** widen the decode to cover the full map. With 0x27 as
the top offset you need at least `address[5:0]` (6 bits → 64 words). Update the
port/wire width and the `case (address[...])` selector together, and add a
`default` that drives `readdata <= 32'h0` so unmapped reads are deterministic.

Until that fix lands, the daemon must treat anything ≥ 0x10 as **not yet wired**.
Track this as a blocking bring-up item.

---

## 5. Access Sequences

**Load a job and start (daemon order):**

1. Clear: write `CONTROL = SOFT_RESET` (bit 1), then `CONTROL = 0`.
2. Write `EPOCH`.
3. Write `HEADER[0..23]` (full pre-padded block).
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
