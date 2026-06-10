# Project TODO — odo-miner-cyclonev

**Last updated:** 2026-06-10
**Owner:** colneech-dev / Claude
**Device:** `5CSXFC6C6U23I7` — Cyclone V SX, 41,910 ALMs, 553 M10K, QMTECH KFB
dual-SDRAM board (DE10-Nano-compatible ball-out, MiSTer-style).

---

## State of the world (2026-06-10 session)

### DONE — algorithm proven correct in RTL ✅

The single biggest milestone: `hdl/tb/run_tb.sh` runs a known-answer
testbench where the **C oracle** (hps/odocrypt_state.c — itself verified
bit-exact against upstream `odocrypt.cpp` via `make check`) generates epoch
tables, a header, and the expected OdoCrypt+Keccak hash; the RTL is driven
through the real Avalon register interface (table streaming with waitrequest,
START, FOUND latching) and must reproduce the hash. **Three vectors pass**,
including a realistic mainnet epoch key.

What was fixed/rebuilt to get there:

- **odocrypt_core.v** rewritten: multi-cycle FSM (~22 cycles/round —
  6 pbox subrounds + 3-cycle BRAM S-box stage + 6 pbox + 7-cycle serialized
  rotation mix), S-boxes read from BRAM ports, single Keccak round iterated
  (THROUGHPUT=12). ~26 KH/s @ 50 MHz.
  - fixed the critical premix bug `{nonce, hdr[18]}` → `{nonce, hdr[32*18+:32]}`
    (bit-select instead of word — every hash was garbage before)
- **odocrypt_epoch_tables.v** rewritten for BRAM: large S-boxes in 40
  dual-port M10Ks (bank-interleaved ping-pong), small S-boxes in MLABs
  (`ramstyle` attribute required — without it Quartus burned ~20K ALMs),
  pbox/rot/roundkey tables in single-copy FFs. Multi-cycle write unpacker
  with Avalon **waitrequest** flow control.
- **odocrypt_top.v**: EPOCH_WR_RESET decode implemented; found-latch is
  edge-triggered (no double-count / re-latch after CLEAR_FOUND); waitrequest
  asserted during table-word unpack.
- Stale RTL (epoch_mutator, odocrypt_array, hash_pll, AXI shims, etc.)
  archived under `hdl/src/odocrypt/archive/` and `hdl/src/archive/`, removed
  from the .qsf.

### DONE — HPS mining bugs fixed ✅

- Epoch key derived correctly: `ntime - ntime % 864000` (mainnet; env
  `ODO_TESTNET=1` → 86400; `ODO_EPOCH_INTERVAL` to override). Upstream
  reference: pool/stratum/header.py.
- Merkle branch stride bug fixed (`char[32][72]` cast to `(*)[128]` read out
  of bounds for ≥2 branches).
- `mining.set_difficulty` parsed; share target derived (cpuminer
  diff_to_target); FPGA receives the **share** target, HPS double-checks and
  flags block candidates against the network target.
- `target_met()` compares LE uint256 from byte 31 down (was backwards).
- extranonce2 chosen per job before the coinbase build; submitted value
  always matches the merkle root.
- miner.c loop: non-blocking `miner_io_check_result()` (FOUND / idle /
  busy), stratum serviced during batches, clean_jobs preempts the FPGA,
  dispatch refuses to clobber an unread FOUND (-EAGAIN).
- Status JSON export to `/run/odod/status.json` each heartbeat (hashrate
  from FPGA perf counters via `miner_io_read_perf`).
- Unit tests: `make test_units` (12 checks) + `make check` (C vs upstream).

### DONE — system integration ✅ (compile verification in progress)

- `soc_system.qsys` extended **incrementally** (qsys_add_peripherals.tcl —
  do NOT rebuild from soc_system.tcl, its HPS params are stale): odocrypt_top
  @ LW 0x0000, spi_lcd @ 0x1000, spi_touch @ 0x1100, pio_lcd @ 0x1200,
  pio_in @ 0x1300, pio_led @ 0x1400; IRQs f2h_irq0 0/1/2.
- odocrypt_top_hw.tcl completed (it was an empty stub): clock/reset/Avalon
  slave with **addressUnits=SYMBOLS** (byte addressing — must stay that way
  to match hps_regs.h offsets).
- soc_top.v wires the SPI/PIO conduits; SDRAM_CS0/1_n held high (GPIO_0 is
  shared with the onboard SDRAM chips).
- Pin assignments for display/touch/keys/LEDs in odo_miner.qsf (DE10-Nano
  ball-out, cross-checked against the KFB schematic).
- Linux: `linux/socfpga_cyclone5_qmtech_odo.dts` (SoCDK base + fabric
  devices), `linux/linux-display.fragment` (fbtft/ads7846/spi-altera/
  gpio-altera), rootfs overlay with BusyBox init scripts (S90odod, S95odoui)
  — note: **the repo's systemd .service files don't run under the default
  BusyBox init**; the init.d scripts are the live ones.
- `sw/odo-ui`: framebuffer + touch dashboard (restart/reboot with
  confirmation). Builds clean.
- See docs/DISPLAY_WIRING.md for the physical hookup of the SPI module.

---

## OPEN ITEMS (priority order)

### 1. Quartus fit/timing closure — DONE ✅ (2026-06-10 21:44)
Final result: **18,132 / 41,910 ALMs (43%)**, 15,535 registers, 80 RAM
blocks (440 Kbit — all S-boxes in BRAM), **timing met with margin**
(clk_50 setup slack +1.707 ns, zero violations in any domain).
Bitstream: `hdl/quartus/output_files/odo_miner.rbf` (2.8 MB).

It took six fitter rounds; the killers, for posterity:
1. 12x-unrolled Keccak (~25K ALMs) → single iterated round (THROUGHPUT=12).
2. 60 parallel barrel rotators in the rotation mix → serialized to 10.
3. FF copy-commit of the pbox/rk tables (~10K ALMs) → single-copy FFs.
4. Small S-boxes silently became ~31K registers. Root cause (found by
   standalone bisection, NOT reported by any Quartus warning): the
   write-port bank bit was the combinational complement of the read-port
   bank bit (`load_bank = ~active_bank`) — that alone blocks RAM
   inference. Fix: independent registers swapped on commit. Also needed:
   read in a separate always block, ramstyle hint. build-fpga.sh now has
   a >=60-RAM-blocks tripwire against regression.

### 2. Hardware gate checks (unchanged sequence)
1. Load rbf via U-Boot boot.scr (it does `fpga load` + `bridge enable`),
   run `fpga_smoke_test` — registers must read back (NOT 0xFFFFFFFF, and the
   CPU must not hang; a hang means the bridge is enabled but the design
   isn't answering).
2. Stream an epoch (odo-miner does this automatically), check
   STATUS.TABLES_VALID and EPOCH_WR_ADDR==5964.
3. Known-nonce test on hardware: `hdl/tb/gen_vectors` prints the expected
   hash for any (key, nonce); program the same header/target and compare
   NONCE_FOUND/HASH registers.
4. Display: dmesg shows fb_ili9341 + ads7846; odo-ui dashboard appears.
5. Stratum round-trip on **testnet** first (1-day epochs), then pool soak.

### 3. Performance (after it works)
- ~26 KH/s @ 50 MHz is the correctness-first baseline. Options, in order:
  fabric PLL to 100–125 MHz (logic is shallow, S-box BRAMs are fast);
  second core (tables have a second read port free on small sboxes? no —
  add per-core table RAM copies, plenty of M10K left); overlap premix with
  Keccak of the previous nonce.
- Batch sizing in miner.c assumes ~25–250 KH/s; env-tunable
  (ODOMIN_NONCE_RANGE, ODOMIN_POLL_TIMEOUT_MS).

### 4. Known soft spots / deferred
- ads7846 touch calibration values in the DTS and odo_ui.c are generic
  defaults; calibrate on real hardware.
- GPIO_0 header pin numbering (11/12/29/30 power pins) verified only against
  DE10-Nano convention — meter-check the QMTECH silkscreen before wiring.
- `hps/miner_daemon.c` (odod) is the legacy loop and didn't get the new
  share-target/preemption logic; `odo-miner` (miner.c) is canonical. Either
  port the fixes or retire odod.
- stratum.c JSON parsing is hand-rolled (fine for pool basics; fragile for
  exotic pools). Reconnect/resubscribe storm behaviour untested.
- Buildroot image rebuild needed (new defconfig: display fragment, custom
  DTS, rootfs overlay). U-Boot env assumes boot.scr flow from
  scripts/build-sdcard.sh.
- Quartus Lite has no licensed Questa; sim runs on Icarus via WSL
  (`~/oss-cad-suite/bin`). hdl/tb/run_tb.sh handles everything.

---

## Quick commands

```bash
# HPS: build + all tests (WSL)
cd hps && make all && make test_units && make check

# RTL: known-answer regression (WSL; needs ~/oss-cad-suite or iverilog)
cd hdl/tb && ./run_tb.sh

# Qsys: regenerate after editing component RTL (the generate step COPIES
# hdl/src into soc_system/synthesis/submodules — always regenerate first!)
cd hdl/qsys && qsys-generate soc_system.qsys --synthesis=VERILOG \
    --output-directory=soc_system --search-path="$(pwd),\$"

# Quartus full compile
cd hdl/quartus && quartus_sh --flow compile odo_miner
```
