# Project TODO — odo-miner-cyclonev

**Last updated:** 2026-07-04
**Owner:** odo-miner-cyclonev maintainers
**Device:** `5CSXFC6C6U23I7` — Cyclone V SX, 41,910 ALMs, 553 M10K, QMTECH KFB
dual-SDRAM board (DE10-Nano-compatible ball-out, MiSTer-style).

---

## Roadmap — next improvements (2026-06-19/20, branch `feat/pipelined-miner`)

**1–4 below are DONE.** Board mines autonomously; epoch transitions self-apply
with zero manual intervention, deploys go over SSH.

> **Deployed config (2026-06-26):** the bitstream is **THROUGHPUT=6 @ 156.25 MHz ≈
> 26.0 MH/s raw** (`odo_miner.qsf` VERILOG_MACRO + `soc_top.v` ×25/8 PLL). Epoch
> 1782432000 Fmax = 159.24 MHz @ Slow/100C (+2.99 MHz margin). Earlier notes citing
> T=7/150 MHz predate this update; treat the qsf macro as authoritative.

1. ✅ **SSH access restored** — `etc/init.d/S50sshd` (host-key gen, strict
   perms, start sshd), `etc/ssh/sshd_config` (key-only root login),
   `root/.ssh/authorized_keys` (key `tools/testnet/odo-miner`). Root cause of
   the original outage: openssh was already in the rootfs but no host keys
   had ever been generated, so sshd silently exited at boot.
2. ✅ **Epoch auto-renewal** — operator-side `scripts/epoch_build_deploy.ps1`
   builds + stages `/boot/fpga_next.rbf`; board-side
   `usr/sbin/epoch-update.sh` (cron */5 via `S91epochcron`) swaps it in and
   reboots once `status.json`'s `epoch` (current job) diverges from
   `bitstream_epoch` (what's baked) — the authoritative signal, not a
   wall-clock guess (block time lags wall-clock on a sparse chain). Verified
   live on a real boundary (1781827200→1781913600): zero manual steps beyond
   pre-staging, pool confirmed shares accepted post-reboot.
3. ✅ **More hashrate** — found the daemon's `stratum_poll` 50 ms timeout was
   capping found-FIFO drains at ~20/s regardless of clock (the real
   bottleneck, not the FPGA); dropped to 5 ms. Walked the miner clock
   100→125→137.5→150 MHz (T=8) then switched to the pipelined upstream core.
   **Deployed: THROUGHPUT=6 @ 156.25 MHz ≈ 26.0 MH/s raw** (Fmax 159.24 MHz
   @ Slow/100C, +2.99 MHz margin). T=8 notes above are intermediate steps.
4. ✅ **Backlog** — web dashboard was already working (port 80, not 8080 —
   earlier checks used the wrong port); pool failover ported from `miner.c`
   (`ODOD_POOL_HOST2/PORT2`, already exported by `S90odod`) and verified live.
   ~~Fan/thermal/reset-button~~ — **all DONE and hardware-verified**: DS18B20
   + PWM fan (2026-06-22), reset-button polling driver (2026-06-24). UIO
   non-root + IRQ daemon (`odo-miner-pipe-uio`) — **DONE 2026-06-25**. See
   `docs/FAN_SENSOR_WIRING.md` and `docs/uio-miner-io-scope.md`.
5. ✅ **Full security/correctness review hardening** (`fix/review-hardening`,
   merged 2026-06-29). RTL: strobe-based FIFO producer; `wfull` off-by-one
   fixed (depth-8 not 7); reset sync into miner_clk; overflow flag
   (STATUS bit3). Stratum: NaN/overflow diff rejected; EN1 overlong + EN2
   size guards; ≥32 branch cap; `resync` counter (not flag). Daemon:
   fork-in-thread fixed (`sync()+reboot()`); Y2038 `%lld`; Avalon COMMIT
   barrier; thermal read-fail fan-full fallback. Webd: cookie-header
   anchoring (C1 bypass closed); fail-closed token gen; SameSite=Lax;
   `ci_strstr` case-insensitive header scan; `ODO_WEB_CONF` env override.
   Ops: `.gitattributes` `eol=lf` for BusyBox init scripts; `PIPESTATUS[0]`
   in build scripts; DEPLOYMENT.md banner. Test suite: `test_stratum_fuzz`
   (ASan/UBSan), `test_webd_auth.sh` (10 assertions), `test_gfx_bounds`
   (ASan/UBSan), `tb_pipe_fifo.v`/`run_tb_fifo.sh` (FIFO burst/overflow/
   drain/irq). CI: lint job (shellcheck + `i/crlf` CRLF guard).
   Bitstream: 22,160/41,910 ALM (53%), timing met. Deployed and verified.
6. ✅ **Second independent deep-review sweep** (2026-07-04, 7 commits
   `9c440d2..9f30563`, merged to `main`). RTL: `pll_ok` STATUS bit wired to
   the real `u_pll_miner.locked` (was hardcoded `1'b1` — invisible PLL lock
   loss given this board's brownout history); `fabric_reset_n` gated by
   both PLLs, not just the fabric one (closed a reset race); commit-toggle
   synchronizer given a proper reset path. New `pll_lock` Qsys conduit;
   full recompile — 0 errors, Fmax 160.93 MHz vs 156.25 MHz required,
   22,066/41,910 ALM (53%, unchanged). Stratum/daemon: bounded
   `send_line()`/`tcp_connect()` timeouts (a stalled pool could block the
   daemon forever, bypassing the dead-pool watchdog); found-FIFO now drains
   against the *old* job before a new job dispatch (previously every job
   switch could silently drop a genuine find as "stale"); overlong
   job_id/coinb1/coinb2 rejected instead of truncated; epoch-interval
   constants de-duplicated. Webd: `/poll.json` consolidates 3 fetches/tick
   into 1 (fixed a latent OOB-read introduced in the same change);
   **`TCP_NODELAY` on accepted sockets** — turned out to be the actual fix
   for persistent dashboard slowness (Nagle + delayed-ACK was stalling
   every response ~40-200ms, independent of round-trip count). sshd:
   ed25519-only host key (RSA blocked on boot entropy). Ops: no more
   hardcoded board IP in deploy scripts; SSH host-key pinning instead of
   disabled checking. **Deployed and hardware-verified**: ~25.7 MH/s,
   123/123 shares accepted, `pll_ok` reads real lock, 0 FIFO overflow.

---

## State of the world (2026-06-14)

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

### 1. Quartus fit/timing closure — DONE ✅ (2026-06-10)
**Single-core baseline:** 18,046 / 41,910 ALMs (43%), 80 RAM blocks (14%),
clk_50 Fmax = 55.6 MHz (+2.016 ns slack at 50 MHz). Bitstream: 2.8 MB.

It took six fitter rounds; the killers, for posterity:
1. 12x-unrolled Keccak (~25K ALMs) → single iterated round (THROUGHPUT=12).
2. 60 parallel barrel rotators in the rotation mix → serialized to 10.
3. FF copy-commit of the pbox/rk tables (~10K ALMs) → single-copy FFs.
4. Small S-boxes silently became ~31K registers. Root cause: write-port bank
   bit was combinational complement of read-port bank bit (`load_bank =
   ~active_bank`) — blocks RAM inference. Fix: independent registers swapped
   on commit + separate read always block + ramstyle hint.

**Dual-core (`perf/dual-core` branch):** 34,072 / 41,910 ALMs (81%), 160 RAM
blocks (29%), Fmax = **55.6 MHz** (unchanged — no new critical paths between
cores). Bitstream: 3.3 MB, deployed to board 2026-06-14. ✅

### 2. Hardware gate checks — ALL DONE ✅ (2026-06-11 / 2026-06-14)
1. ✅ fpga_smoke_test passes — registers read back, CPU does not hang.
2. ✅ Epoch streaming works — STATUS.TABLES_VALID set, EPOCH_WR_ADDR==5964.
3. ✅ Known-nonce on silicon — FPGA hash matches C oracle.
4. ✅ Display up — fb_ili9341 + ads7846; odo-ui dashboard live on board.
5. ✅ Testnet stratum round-trip — ~485 blocks mined 2026-06-11.
   Board was **~52 KH/s** dual-core FSM at that time (2026-06-14); now
   **~26 MH/s** pipelined @ 156.25 MHz on mainnet (2026-06-26).

### 3. Performance — IN PROGRESS
- ✅ **Dual-core at 52 KH/s** (`perf/dual-core` branch, deployed 2026-06-14).
- ✅ **Stale-job guard** in `hps/miner.c`: saves `batch_job_id` at dispatch;
  discards found nonces when job ID has changed, eliminating the root cause
  of bridge rejections.
- ⬜ **75 MHz PLL clock bump** (next): add fractional PLL in `hdl/src/soc_top.v`,
  update `hdl/constraints/miner.sdc` to 13.33 ns. Zero RTL changes to core.
  Expected yield: ~78 KH/s if timing closes. BUG-7 (cdc_bus ready unsynced)
  becomes relevant if a separate miner clock domain is introduced.
- ⬜ **3rd/4th core**: each adds another `odocrypt_epoch_tables` instance
  (~14% BRAM); ALM constraint means max 2 cores with current sequential FSM.
  FSM pipelining required to scale further.
- Batch sizing: `ODOMIN_NONCE_RANGE` / `ODOMIN_POLL_TIMEOUT_MS` env-tunable.

### 4. Known soft spots / deferred
- ~~ads7846 touch calibration~~ — **DONE (2026-06-11)**: `swap_xy=1, inv_y=1`
  confirmed on hardware (rotate=270 panel). T_IRQ does not reach GIC; polling
  mode required. See `docs/DISPLAY_WIRING.md` bring-up checklist §5.
- ~~`hps/miner_daemon.c` (odod) is the legacy daemon loop~~ — **DONE
  (2026-06-20)**: retired, never launched by any init script and missing
  every consensus fix accumulated in `miner.c` since (prevhash byte-swap,
  stale-job guard, CLOCK_MONOTONIC). Makefile's `odod` target removed.
- stratum.c JSON parsing is hand-rolled (fine for pool basics; fragile for
  exotic pools). Pool failover (`ODOD_POOL_HOST2/PORT2` in S90odod) is wired
  into both `miner.c` and `miner_pipe.c`'s reconnect loops (verified
  2026-06-20 — already symmetric, this note was stale).
- ~~Fan/thermal/reset button~~ — **all DONE**: DS18B20 + PWM fan hardware-
  verified 2026-06-22; reset-button polling driver 2026-06-24. See
  `docs/FAN_SENSOR_WIRING.md`.
- Quartus Lite has no licensed Questa; sim runs on Icarus via WSL.
  Note: Qsys caches RTL in `soc_system/synthesis/submodules/` — copy updated
  `odocrypt_top.v` there manually after edits; do NOT rely on qsys-generate
  to pick up src changes automatically.

---

## Quick commands

```bash
# HPS: build + all tests (WSL)
cd hps && make all && make test_units && make check

# RTL: known-answer regression (WSL; needs ~/oss-cad-suite or iverilog)
cd hdl/tb && ./run_tb_pipe.sh   # deployed pipelined core (run_tb.sh = retired FSM)

# Qsys: regenerate after editing component RTL (the generate step COPIES
# hdl/src into soc_system/synthesis/submodules — always regenerate first!)
cd hdl/qsys && qsys-generate soc_system.qsys --synthesis=VERILOG \
    --output-directory=soc_system --search-path="$(pwd),\$"

# Quartus full compile
cd hdl/quartus && quartus_sh --flow compile odo_miner
```
