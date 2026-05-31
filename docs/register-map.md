# OdoCrypt Miner — Avalon-MM Register Map

**Status:** Draft v0.1 · **Owner:** colneech-dev · **Applies to:** `hdl/src/odo_avalon_wrapper.v` ↔ `sw/odod/transport_mmap.c`

> **Single source of truth.** Any change to this file MUST be matched in the RTL wrapper
> and the daemon transport layer in the same commit. A pre-commit/CI check should fail
> the build if the wrapper's register definitions drift from this table. Register-map /
> CDC mismatches are the #1 bring-up failure mode for this project.

---

## 1. Bus Parameters

| Property            | Value                                            |
|---------------------|--------------------------------------------------|
| Bridge              | HPS-to-FPGA Lightweight (`lwh2f`)                |
| Avalon-MM data width| 32 bits                                          |
| Address granularity | Word (4-byte) addressing                         |
| Base address (HPS)  | `0xFF200000` + wrapper offset (set in Qsys)      |
| Endianness          | Little-endian (matches ARM HPS)                  |
| Access from Linux   | `/dev/mem` + `mmap`, 4 KB page aligned           |

---

## 2. Register Map (word offsets)

All offsets are byte offsets from the wrapper base. Access is 32-bit aligned.

| Offset  | Name           | Dir | Reset      | Description                                              |
|---------|----------------|-----|------------|----------------------------------------------------------|
| `0x00`  | `CTRL`         | R/W | `0x0`      | Control: start/stop, soft-reset, enable bits             |
| `0x04`  | `STATUS`       | R   | `0x0`      | Busy, found, lock, idle flags                            |
| `0x08`  | `VERSION`      | R   | `0xODO_xx` | Bitstream/build version + core count                     |
| `0x0C`  | `EPOCH`        | R/W | `0x0`      | Current OdoCrypt mutation epoch (drives tweak)           |
| `0x10`–`0x4F` | `HEADER[0..15]` | W | `0x0` | 512-bit block header / midstate input (16 words)         |
| `0x50`–`0x6F` | `TARGET[0..7]`  | W | `0xFF..`| 256-bit difficulty target (8 words, big-endian compare)  |
| `0x70`  | `NONCE_START`  | W   | `0x0`      | Lower bound of nonce search range                        |
| `0x74`  | `NONCE_END`    | W   | `0xFFFFFFFF`| Upper bound of nonce search range                       |
| `0x78`  | `RESULT_NONCE` | R   | `0x0`      | Winning nonce (valid when `STATUS.found`=1)              |
| `0x7C`  | `RESULT_CORE`  | R   | `0x0`      | Index of core that found the share                       |
| `0x80`–`0x9F` | `RESULT_HASH[0..7]` | R | `0x0`| 256-bit hash of the winning nonce                        |
| `0xA0`  | `PERF_HASHES`  | R   | `0x0`      | Total hashes attempted (low word, see `PERF_HASHES_HI`)  |
| `0xA4`  | `PERF_HASHES_HI`| R  | `0x0`      | Upper 32 bits of hash counter                            |
| `0xA8`  | `PERF_SHARES`  | R   | `0x0`      | Shares found since reset                                 |
| `0xAC`  | `PERF_CYCLES`  | R   | `0x0`      | Active cycle counter (for hashrate calc)                 |
| `0xB0`  | `IRQ_STATUS`   | R/W1C| `0x0`     | Interrupt status — write 1 to clear `found` latch        |

---

## 3. Field Definitions

### `CTRL` (`0x00`, R/W)

| Bits   | Field        | Description                                             |
|--------|--------------|---------------------------------------------------------|
| `[0]`  | `START`      | 0→1 latches HEADER/TARGET/range and begins search       |
| `[1]`  | `SOFT_RESET` | Pulse high to reset cores, counters, and found latch    |
| `[2]`  | `IRQ_EN`     | Enable `found` interrupt to HPS                          |
| `[3]`  | `AUTO_EPOCH` | Let HW advance `EPOCH` on mutation boundary             |
| `[31:4]`| _reserved_  | Write 0                                                  |

### `STATUS` (`0x04`, R)

| Bits   | Field    | Description                                                |
|--------|----------|------------------------------------------------------------|
| `[0]`  | `BUSY`   | At least one core actively hashing                         |
| `[1]`  | `FOUND`  | A share was found; `RESULT_*` valid until cleared          |
| `[2]`  | `IDLE`   | All cores idle / range exhausted                           |
| `[3]`  | `PLL_LOCK`| Hash-pipeline PLL locked                                   |
| `[31:4]`| _reserved_| Reads 0                                                   |

### `IRQ_STATUS` (`0xB0`, R/W1C)

| Bits   | Field       | Description                                            |
|--------|-------------|--------------------------------------------------------|
| `[0]`  | `FOUND_IRQ` | Set when a share is latched; write 1 to clear          |
| `[31:1]`| _reserved_ | Reads 0                                                |

---

## 4. Access Sequences

**Load a new job (daemon → FPGA):**

1. Poll `STATUS.BUSY` or assert `CTRL.SOFT_RESET` to halt the current search.
2. Write `HEADER[0..15]`, then `TARGET[0..7]`.
3. Write `NONCE_START` and `NONCE_END` (per-board range slice).
4. Write `EPOCH` (unless `AUTO_EPOCH` is set).
5. Set `CTRL.IRQ_EN` (optional), then pulse `CTRL.START` (write 1).

**Read a result (FPGA → daemon):**

1. Wait on IRQ, or poll `STATUS.FOUND`.
2. Read `RESULT_NONCE`, `RESULT_CORE`, and `RESULT_HASH[0..7]`.
3. Validate the hash on the HPS before submitting the share upstream.
4. Write 1 to `IRQ_STATUS.FOUND_IRQ` to clear the latch.
5. Continue scanning (range not exhausted) or load the next job.

> All multi-word fields (`HEADER`, `TARGET`, `RESULT_HASH`) must be written/read as a
> complete block. The hardware only samples them on the `START` edge, so partial updates
> mid-search are ignored — this is intentional to avoid torn reads across the bus.

---

## 5. CDC Notes

The Avalon bus runs in the HPS bridge clock domain; the OdoCrypt cores run in the
hash-pipeline PLL domain. Every register crossing must be synchronized:

- **Control pulses** (`START`, `SOFT_RESET`): single-cycle pulse crossed via `cdc_sync`
  / `cdc_bus` (pulse-to-pulse handshake), never combinationally fanned into the core domain.
- **Found event + nonce**: latched in the hash domain and crossed to the bus domain via
  `cdc_found`, which carries both the `found` flag and the captured `nonce_hash` together so
  the daemon never reads a stale or torn nonce.
- **Wide config (`HEADER`, `TARGET`)**: held stable in the bus domain and only sampled on the
  synchronized `START` edge — no per-bit synchronizer needed since the data is static at capture.
- **Performance counters**: free-running in the hash domain, gray-coded or captured on a
  synchronized read-strobe before being presented on the bus.

> If you change which domain a register lives in, update both the wrapper's CDC
> instantiation and this section in the same commit.
