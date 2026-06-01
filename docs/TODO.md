# Project TODO — odo-miner-cyclonev

**Last updated:** 2026-05-31
**Owner:** colneech-dev / Claude
**Device confirmed:** `5CSXFC6C6U23` — Cyclone V SX F6, 110K LE, 204 M10K, 112 DSP, 484-ball BGA

---

## Current blocking status

The smoke test reads `0xFFFFFFFF` from every register at `0xFF200000`.

**Root cause:** `hdl/quartus/` and `hdl/qsys/` are empty — no Quartus project and
no Platform Designer system exist in the repo yet. The FPGA has never been programmed
with this design. Reading over LWH2F from an unconfigured FPGA returns `0xFFFFFFFF`
(fabric floats high), which is exactly what is observed.

**Address note:** `0xFF200000` is the LWH2F bridge base fixed by Cyclone V SoC
architecture — it is not set by the Quartus project. What the Platform Designer
system assigns is the *offset within that window* for the miner slave.
`hps_regs.h` assumes `MINER_BASE_OFFSET = 0x0` (slave at `0xFF200000` directly).
This is intentional and the Qsys assignment must match it.

**Bridge enable:** Even with a correct bitstream loaded, the LWH2F bridge must be
explicitly enabled after FPGA configuration — via `/sys/class/fpga-bridge/` sysfs
or U-Boot `bridge enable`. A missing bridge enable also returns `0xFFFFFFFF`. This
step must be part of every bring-up and bitstream-reload sequence.

The gate to unlock hardware testing: create Quartus/Qsys project → synthesise →
load `.rbf` → enable bridge → re-run smoke test.

Even once the FPGA is programmed, the OdoCrypt hash algorithm in RTL is an
approximation and will not produce network-valid shares.

---

## Critical bugs — fix before any hardware testing

### BUG-1: STATUS register bit 3 (EPOCH_LOCK) always reads 0
**File:** [hdl/src/odocrypt_top.v:212](../hdl/src/odocrypt_top.v)
**Symptom:** `STAT_EPOCH_LOCK = 1u << 3 = 32'h8` is a 32-bit constant. Placing
it in `{28'h0, STAT_EPOCH_LOCK, 1'b1, found_latched, core_busy}` makes the
concatenation 63 bits wide. After Verilog truncates to 32 bits, bit 3 is always 0.
**Fix:**
```verilog
avs_readdata = {28'h0, 1'b1 /*EPOCH_LOCK*/, 1'b1 /*CORE_READY*/,
                found_latched, core_busy};
```
**Impact:** STATUS.EPOCH_LOCK always reads 0 instead of 1. Low severity now
(both bits are informational stubs), but must be correct before any software
tests against STAT_EPOCH_LOCK.

### BUG-2: `busy` is driven from two always blocks — multi-driver violation
**File:** [hdl/src/odocrypt/odocrypt_core.v](../hdl/src/odocrypt/odocrypt_core.v)
**Symptom:** `busy` is an `output reg` assigned in BOTH the `always @(posedge clk)`
(reset only) and `always @(*)` (combinatorial). Two always blocks driving one reg
is undefined in Verilog; synthesisers warn or silently pick one driver.
**Fix:** Remove `busy <= 1'b0` from the sequential block. Drive `busy` only from
the combinatorial `always @(*)`. Optionally change port declaration to `output wire`.

### BUG-3: `odocrypt_array.v` header_words port mismatch (24 words vs 20)
**File:** [hdl/src/odocrypt/odocrypt_array.v:18](../hdl/src/odocrypt/odocrypt_array.v)
**Symptom:** Array module declares `[0:23]` (24 words); `odocrypt_core` expects
`[0:19]` (20 words). Connecting them at synthesis is a port-width error.
**Fix:** Change the array module to `input wire [31:0] header_words [0:19]`.

### BUG-4: `core_start_pulse` is a combinatorial one-cycle Avalon-write glitch
**File:** [hdl/src/odocrypt_top.v:88](../hdl/src/odocrypt_top.v)
**Symptom:** `core_start_pulse` is derived directly from `avs_write`. It is high
for exactly one clock cycle. If the core is not in `ST_IDLE` when the HPS writes
CONTROL, the start pulse is silently dropped and the new job never launches.
There is no STATUS bit to indicate "core is idle and ready."
**Fix:** Register a `start_pending` latch in the top-level; set it on the write,
clear it once the core accepts it (i.e., transitions out of ST_IDLE). Alternatively,
require the HPS to first confirm `!STAT_BUSY` before writing START.
Add `STAT_IDLE` or `STAT_CORE_READY` as a meaningful bit (currently tied high).

### BUG-5: `miner_daemon.c` (hdl/src/hps/) references non-existent headers and API
**File:** [hdl/src/hps/miner_daemon.c](../hdl/src/hps/miner_daemon.c)
**Symptom:** Includes `fpga_regs.h` (does not exist), uses `REG_CTRL`, `CTRL_LOAD`,
`CTRL_STOP`, `STATUS_FOUND`, `REG_NONCE_OUT`, `stratum_t`, `stratum_callbacks_t`,
`stratum_free` — none of which exist in `hps_regs.h` or `stratum.h`.
**Root cause:** The `hdl/src/hps/` subtree is a stale draft. The canonical HPS
source is in `hps/`. The two trees must be consolidated.
**Fix:** Delete `hdl/src/hps/` entirely. All HPS development goes in `hps/` only.

### BUG-6: `stratum.c` callback fields not in `stratum_ctx_t`
**File:** [hdl/src/hps/stratum.c](../hdl/src/hps/stratum.c) (stale draft)
**Symptom:** `process_line()` calls `ctx->on_job(...)` and `ctx->on_difficulty(...)`
which do not exist in `stratum_ctx_t` as defined in `stratum.h`. Won't compile.
**Fix:** Eliminated when `hdl/src/hps/` is removed (see BUG-5).

### BUG-7: `cdc_bus.v` ready signal crosses domains without a synchronizer
**File:** [hdl/src/cdc/cdc_bus.v:33](../hdl/src/cdc/cdc_bus.v)
**Symptom:** `assign ready_src = ready_dst` directly connects the destination-domain
ready signal back into the source domain without a synchronizer. Harmless now
(single clock), but will cause metastability when the PLL hash clock is added.
**Fix:** Add a `cdc_sync` stage on `ready_dst` before exposing it as `ready_src`.

---

## Algorithm correctness — required before valid shares

> **Updated 2026-05-31 after reading upstream source.**
> The real OdoCrypt algorithm is substantially different from what the current RTL
> implements. The complete pipeline is:
>
>   `80-byte block header (640 bits)`
>   → **odo_encrypt** (84 rounds: Pbox0 → Sbox → Pbox1 → Rotations → RoundKey)
>   → `640-bit midstate`
>   → **Keccak-800** (sponge hash)
>   → `256-bit PoW hash`
>   → **compare ≤ target**
>
> All S-boxes, P-boxes, rotations, and round keys are derived per-epoch from a
> 32-bit seed using a non-standard LCG (`OdoRandom` in `odocrypt.cpp`). The
> upstream design bakes these as hardcoded ROM and resynthesises per epoch. Our
> design computes them on the HPS and loads them into FPGA BRAM over MMIO.

### ALGO-1: Real LCG + epoch table loading — DONE
`hps/odocrypt_state.c` implements `odo_epoch_generate()` (faithful LCG port) and
`odo_fpga_load_epoch()` (streams 5964 words to `REG_EPOCH_WR_DATA`).
`hdl/src/odocrypt/odocrypt_epoch_tables.v` stores all tables with auto-commit.
`REG_EPOCH_WR_DATA/RESET/COMMIT/WR_ADDR` added to both RTL and `hps/hps_regs.h`.
`STAT_TABLES_VALID` (bit 4) added to STATUS — core will not start until set.

### ALGO-1 (historical description, now implemented)
**Current:** `odocrypt_epoch_mutator.v` uses a placeholder XOR formula.
**Correct approach:** Run the epoch-table generation on the HPS (it's just C),
then write the resulting tables into new FPGA BRAM-backed registers over MMIO.
No LCG logic is needed in RTL.

**HPS-side action (implement first):** Create `hps/odocrypt_state.h/c` that
replicates the LCG and all table generation from `odocrypt.cpp`:
- `OdoRandom`: LCG with epoch seed → sequence of uint32/uint64/permutations
- Generates: 40 small S-boxes (6-bit, 64-entry each), 10 large S-boxes (10-bit,
  1024-entry each), 2 P-boxes (6 subrounds × 5 masks + 5 rotations each),
  6 global rotations, 84 round keys.

**RTL-side action (redesign required):** Replace `odocrypt_epoch_mutator.v` with
BRAM-backed S-box and P-box register banks. The existing `odocrypt_round.v` and
`odocrypt_sbox_dsp.v` must be rewritten to implement the actual Pbox→Sbox→Pbox→
Rotations→RoundKey sequence. The existing pipeline structure (84 registered stages)
is still correct in outline.

**New registers needed (major register map extension):**
- S-box write port: address + data for loading S-box entries
- P-box register bank: 2 × (6 subrounds × 5 masks + 5 rotations) = 60+50 = 110 words
- Rotation registers: 6 × 6-bit rotation amounts
- Round key array: 84 × 10-bit values (packed)
- An `EPOCH_LOAD_DONE` strobe to commit the tables

### ALGO-2: Real OdoCrypt round function — DONE
`hdl/src/odocrypt/odocrypt_core.v` rewritten as a **sequential FSM**:
- One hash per 111 cycles: 1 (PreMix) + 84 (rounds) + 1 (Keccak feed) + 25 (Keccak wait)
- 640-bit state (10 × 64-bit words), real PreMix (XOR-fold)
- Full round: `apply_pbox → apply_sboxes → apply_pbox → apply_rotations → apply_round_key`
- All sub-functions implemented as Verilog functions (combinatorial, 1 cycle per round)
- Epoch tables read from `odocrypt_epoch_tables` via flat packed input wires
- `odocrypt_compress.v` and `odocrypt_round.v` are superseded but left in place

**Throughput at 50 MHz:** 50M/111 ≈ 450 KH/s per core; 4 cores ≈ 1.8 MH/s.
To increase: raise clock frequency or instantiate more cores.

### ALGO-2 (historical description, now implemented)

Each of the 84 rounds applies (in order):
1. **Pbox0** (`ApplyPbox`): 6 subrounds of masked-swap → word-shuffle(×3) → rotation
2. **Sbox** (`ApplySboxes`): per-word substitution using 4 small (6-bit) and 4 large
   (10-bit) S-boxes interleaved across each 64-bit word
3. **Pbox1** (`ApplyPbox`): same structure as Pbox0 with independent tables
4. **Rotations** (`ApplyRotations`): state ← rotate_copy(state, 1); for each word,
   XOR with 6 rotations of the same-position word from the previous state
5. **RoundKey** (`ApplyRoundKey`): XOR state[i] with bit i of the round key integer

**S-box detail (per word, 64 bits processed as 4 × 16-bit chunks):**
- Bits [5:0]   → small S-box → 6-bit output at [5:0]
- Bits [15:6]  → large S-box → 10-bit output at [15:6]
- Bits [21:16] → small S-box → 6-bit output at [21:16]
- Bits [31:22] → large S-box → 10-bit output at [31:22]
- (repeat for high 32 bits using next small-sbox indices, same large sbox)

### ALGO-3: Keccak-800 post-processing stage — DONE
`hdl/src/keccak/keccak800.v` ported from upstream (MIT-compatible GPL v3).
`odocrypt_core.v` wired: compress_out → keccak_hasher (WIDTH=256, THROUGHPUT=1,
latency=25 cycles) → 256-bit hash → target compare.
Total pipeline depth: 84 + 25 = 109 clock cycles.
**Remaining:** Change WIDTH from 256 to 640 when the real 640-bit state is implemented
(ALGO-1/ALGO-2). The keccak_hasher is parameterised and will not need structural changes.

### ALGO-4: Validate pipeline nonce alignment (off-by-one risk)
**Files:** `odocrypt_core.v`, `odocrypt_compress.v`
**Action:** Write a Verilog testbench with a known (header, epoch, nonce) → hash
triple. Count cycles from compress_in_valid to compress_out_valid. Verify
pipe_nonce[PIPE_DEPTH] equals the input nonce at that exact cycle.

### ALGO-5: Validate hash comparison endianness
**Files:** `hps/miner_daemon.c:248`, `odocrypt_core.v`
**Action:** Once the correct hash is produced, verify the byte ordering of the
256-bit Keccak output matches the byte ordering used in the target comparison.
Cross-check with the upstream `cmp_256` module (compares 16-bit chunks MSB-first).

### ALGO-3: Validate hash comparison endianness
**Files:** [hps/miner_daemon.c:248](../hps/miner_daemon.c),
[hdl/src/odocrypt/odocrypt_core.v:218](../hdl/src/odocrypt/odocrypt_core.v)
**Current:** The HPS writes the big-endian target bytes MSB-first into TARGET[0].
`odocrypt_top.v` packs TARGET as `{reg[7],...,reg[0]}` making `target_256[255:224]`
the bytes originally at TARGET[0] (MSB). `hash_meets_target` does `hash_state <= target`.
The correctness of this comparison depends on `compress_out_state` being in the same
byte order. This is unvalidated.
**Action:** Pick a known (header, nonce, epoch) → hash triple. Write it into
registers in simulation and confirm the comparison fires at the right nonce.

### ALGO-4: Validate pipeline nonce alignment (off-by-one risk)
**Files:** [hdl/src/odocrypt/odocrypt_core.v:79](../hdl/src/odocrypt/odocrypt_core.v),
[hdl/src/odocrypt/odocrypt_compress.v:46](../hdl/src/odocrypt/odocrypt_compress.v)
**Current:** The compressor registers `in_state` at stage 0 (adding 1 extra clock).
`pipe_valid[PIPE_DEPTH]` and `compress_out_valid` may arrive 1 cycle apart.
If off by one, the nonce reported in `NONCE_FOUND` is 1 behind the actual
winning nonce.
**Action:** Write a Verilog testbench. Drive a single known (header, nonce) in,
count the clock between `compress_in_valid` and `compress_out_valid`, verify
`pipe_nonce[PIPE_DEPTH]` equals the input nonce at that exact cycle.

---

## Missing implementations (code stubs that don't work)

### IMPL-1: `job_from_notify()` not implemented
**File:** [hps/job.c](../hps/job.c)
**Declared in:** [hps/job.h:72](../hps/job.h)
**Impact:** The daemon cannot parse `mining.notify` into a `job_t`. Without this,
no job is ever sent to the FPGA.
**Action:** Implement. Parse `job_id`, `prevhash` (32 bytes, byte-swap per
Stratum convention), `version`, `nbits`, `ntime`, `merkle_branch[]`, `clean_jobs`.
Call `job_target_from_nbits()`. The `stratum.h` `handle_notify()` should call this
then set `ctx->have_job = true`.

### IMPL-2: `miner_io_open()` / `miner_io_close()` not implemented
**File:** [hps/hps_regs.h:91](../hps/hps_regs.h)
**Declared but not defined.** `fpga_smoke_test.c` rolls its own open/map because
these are missing.
**Action:** Implement in a new `hps/miner_io.c`. Use the same mmap pattern as
`fpga_smoke_test.c`. The daemon should use `miner_io_t` rather than raw globals.

### IMPL-3: `hash_pll.v` wraps non-existent Quartus IP
**File:** [hdl/src/odocrypt/hash_pll.v](../hdl/src/odocrypt/hash_pll.v)
**Current:** Instantiates `hash_pll_qsys` which Quartus IP Catalog would generate.
No `.qip` or Qsys wrapper exists yet.
**Action:** Generate the PLL IP in Quartus (IP Catalog → Clocks; 50 MHz in,
150 MHz out). Commit the generated `.qip` + `.v` files. Until then, the design
will not synthesize.

### IMPL-4: No Quartus project or Platform Designer system
**Directories:** `hdl/quartus/` and `hdl/qsys/` are empty.
**Action:** Create the Quartus project (`.qpf`/`.qsf`) targeting the exact Cyclone V
SoC device on the QMTECH board. Build the Qsys system: HPS + LWH2F bridge +
`odocrypt_top` slave. Assign the slave base address and export `soc_system.qsys`.
This is the single largest remaining hardware task.

### IMPL-5: `stratum_poll()` has no `timeout_ms` support
**File:** [hps/stratum.c:318](../hps/stratum.c)
**Current:** `stratum_poll(ctx)` takes no timeout argument but `stratum.h` declares
`stratum_poll(ctx, timeout_ms)`. The implementation ignores the timeout and does a
single non-blocking receive attempt.
**Action:** Add `select()` or `poll()` with the supplied timeout before `recv()`.
This is essential for the daemon's 50 ms polling cadence to be reliable.

### IMPL-6: `stratum_get_job()` and `stratum_submit()` not implemented in stratum.c
**File:** [hps/stratum.c](../hps/stratum.c)
**Declared in:** [hps/stratum.h:123](../hps/stratum.h)
**Action:** Implement `stratum_get_job()` (copy `current_job` to out, clear
`have_job` flag). Implement `stratum_submit()` (build and send `mining.submit`
JSON-RPC with nonce + ntime + extranonce2 hex strings).

### IMPL-7: `stratum.c` `handle_notify()` does not parse the full job
**File:** [hps/stratum.c:391](../hps/stratum.c)
**Current:** `handle_notify()` only extracts `job_id` from the params array.
It does not parse `prevhash`, `coinb1`, `coinb2`, `merkle_branch[]`, `version`,
`nbits`, `ntime`, or `clean_jobs`.
**Action:** Parse the full `mining.notify` params array. Call `job_from_notify()`
and `odocrypt_build_header()`. Then set `ctx->current_job` and `ctx->have_job = true`.

### IMPL-8: `stratum_submit_share()` in `stratum.c` uses wrong params order
**File:** [hps/stratum.c:325](../hps/stratum.c)
**Current:** Sends `[user, job_id, "", ntime, nonce]` — extranonce2 is empty string.
**Action:** Include the real extranonce2 hex from `job->extranonce2`. Update
the call site in the daemon once `job_t` carries extranonce2 correctly.

---

## Performance counter correctness

### PERF-1: `perf_hashes_lo/hi` counts busy cycles, not hashes
**File:** [hdl/src/odocrypt_top.v:188](../hdl/src/odocrypt_top.v)
**Current:** Increments while `core_busy=1` — measures clock cycles, not throughput.
With an 84-stage full-throughput pipeline this approximates hash/cycle but is
semantically wrong and misleading in telemetry.
**Fix:** Increment on `core_hash_valid` instead of `core_busy`.

---

## Structural / repo hygiene

### REPO-1: Duplicate HPS source trees
`hdl/src/hps/` and `hps/` both contain `miner_daemon.c`, `stratum.c/h`,
`hps_regs.h`, `job.h`. The `hdl/src/hps/` copies are stale and broken (BUG-5).
**Action:** Delete `hdl/src/hps/`. The canonical source is `hps/`. Update any
references in docs or Makefiles.

### REPO-2: No `.gitignore` entries for build artifacts
`hps/miner_daemon.o`, `hps/stratum.o`, `hps/job.o`, `hps/odocrypt_header.o`,
`hps/odod` are committed to the repo.
**Action:** Add `*.o`, `odod`, `fpga_smoke_test` to `.gitignore` in `hps/`.

### REPO-3: `docs/working-notes.md` is raw chat/paste content, not structured notes
**Action:** Replace with structured dated entries (done as of 2026-05-31).

---

## Integration and build

### BUILD-1: Complete Quartus project and generate Platform Designer system
**Device confirmed: `5CSXFC6C6U23`** (Cyclone V SX F6 C6 U23 484-ball BGA).
`hdl/quartus/odo_miner.qpf` and `odo_miner.qsf` are created with all RTL sources.
`hdl/src/soc_top.v` is the top-level wrapper (soc_system instantiation commented
out until Platform Designer generates it).

**Remaining steps:**
1. Open the QMTECH GHRD in Platform Designer to get the correct HPS/DDR3/EMAC
   pin-mux config. Do NOT invent pin assignments — use the QMTECH reference.
2. Create the Qsys system in `hdl/qsys/soc_system.qsys`: add HPS component,
   connect LWH2F bridge master to `odocrypt_top` slave at base offset 0x0.
3. Run Platform Designer → generate HDL → uncomment soc_system in soc_top.v.
4. Run Analysis & Elaboration first (catches port errors without full compile).
5. Full synthesis → verify timing closes at 50 MHz Avalon clock.
6. Confirm `CLOCK_50` pin (currently set to PIN_V11 in .qsf — verify vs schematic).

### BUILD-2: Run `make` in `hps/` after fixing broken includes
Current `hps/` build works for `fpga_smoke_test`. After fixing `miner_daemon.c` API
and implementing missing functions, full `make` (`odod` target) must compile clean.

### BUILD-3: Add RTL testbenches
At minimum:
- Register read/write smoke test (pure Verilog tb, no hardware)
- Single-nonce pipeline test with known (epoch, header, nonce) → expected hash
- Start/found/clear FSM sequence test

### BUILD-4: Cross-compile `hps/` for ARM (armhf)
Set `CC=arm-linux-gnueabihf-gcc` in Makefile or via env. Verify the binary runs
on the Cyclone V HPS Linux image.

---

## Hardware bringup sequence (ordered gate checks)

1. **Gate 1 — Bitstream + bridge:**
   a. Load `.rbf` via FPGA Manager (`/sys/class/fpga_manager/fpga0/firmware`) or JTAG.
   b. Explicitly enable the LWH2F bridge (`/sys/class/fpga-bridge/lwhps2fpga/enable` = 1,
      or U-Boot `bridge enable`). **This is a separate step from loading the bitstream.**
   c. Re-run `fpga_smoke_test`. All register read/write checks must pass (not 0xFFFFFFFF).
2. **Gate 2 — FSM control:** Write START; confirm BUSY=1. Write SOFT_RESET;
   confirm BUSY=0 and FOUND=0. Confirm STATUS fields update as expected.
3. **Gate 3 — Known-nonce test:** Program a (header, target, epoch) whose
   winning nonce is known from the upstream C++ reference. Confirm FOUND=1
   and NONCE_FOUND equals the expected value.
4. **Gate 4 — Hashrate:** Measure PERF_HASHES over a known interval. Confirm
   it matches expected pipeline throughput (1 hash/cycle × clock frequency).
5. **Gate 5 — Stratum round-trip:** Point `odod` at a test pool. Confirm
   subscribe → authorize → notify → submit works end to end.
6. **Gate 6 — Autonomy soak:** Cable-free power-on, runs for 24 h without
   manual intervention.

---

## Legend
- **BUG-x** — confirmed code defect, must fix
- **ALGO-x** — algorithm correctness, required for valid mining
- **IMPL-x** — missing implementation (declared but not written)
- **PERF-x** — counter/metric correctness
- **REPO-x** — housekeeping
- **BUILD-x** — build and integration tasks
