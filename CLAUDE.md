# CLAUDE Project Brief

This repository contains a standalone Cyclone V SoC port of the `odo-miner` OdoCrypt FPGA miner, based on the upstream source tree in `third_party/odo-miner/`.

> **⚠️ PUBLIC REPO — NO PERSONAL INFORMATION IN COMMITS.** This is a public,
> GPL-3.0-or-later project. Never commit personal or environment-specific data:
> real names, emails, SSH **private or public** keys, real wallet/payout
> addresses, home/LAN IP addresses, absolute user paths (`C:\Users\<name>\…`,
> `/mnt/c/Users/<name>/…`), `wpa_supplicant` WiFi secrets, or device metadata
> (strip EXIF from any committed image — `git ls-files '*.png' '*.jpg'`).
> Use placeholders, relative paths, and env vars (`${REPO}`, `${BOARD_IP}`)
> instead. `linux/overlay/root/.ssh/authorized_keys` ships as an empty template
> and the rootfs default root password must be changed on first boot (see the
> README Security section). When in doubt, keep it out of git.

## Purpose

`CLAUDE.md` is the top-level project brief for an AI or engineer to understand the repository intent, the target architecture, and where to find the detailed design artifacts.

## Project summary

- Goal: run the OdoCrypt miner fully autonomously on a QMTECH Cyclone V SoC board.
- The HPS runs Linux and a Stratum-capable miner daemon.
- The system is based on the upstream `odo-miner` design and reworks it into a standalone Cyclone V SoC implementation.
- The FPGA fabric performs OdoCrypt hashing using an Avalon-MM memory-mapped register interface.
- The system should boot from SD card and function without a host PC.

## Key documentation

- `docs/architecture.md` — main architecture and execution plan
- `docs/register-map.md` — FPGA register interface contract
- `docs/project-plan.md` — phase-based project execution brief
- `docs/working-notes.md` — working notes and implementation ideas

## Source layout

- `hdl/` — FPGA and RTL source files
- `hps/` — HPS daemon, job handling, and register definitions
- `boot/` — bootloader, device-tree, and SD card boot assets
- `linux/` — Buildroot and rootfs build support
- `sw/` — supporting user-space software and services
- `scripts/` — build and deployment helpers
- `services/` — init/service unit files

## Current status (2026-07-19)

- **INCIDENT (2026-07-19): epoch renewal failed a second, independent way —
  crond silently died, not the operator-side script this time.** The Jul 16
  boundary (bitstream_epoch 1783296000 -> job epoch 1784160000) was staged
  correctly days ahead as `/boot/fpga_next.rbf`, but never applied: `crond`
  exited within ~30s of boot with zero trace in `dmesg`/syslog (no OOM, no
  segfault) and never restarted, so the crontab entry that should have run
  `usr/sbin/epoch-update.sh` every 5 min was simply never executed by
  anything for 9.5 days. Board mined the stale epoch the whole time:
  **4,535,737 of 4,645,408 shares rejected (97.6%)**. Fixed manually (mount
  `/boot`, swap `fpga_next.rbf` into `fpga.rbf`, reboot — board back to 100%
  accepted immediately). Root-fixed by removing the crond dependency
  entirely: `S91epochcron` now runs `epoch-update.sh` from a plain
  `while true; do ...; sleep 300; done` loop instead of a crond-executed
  crontab entry (nothing else on this board used cron). Two independent
  single-point-of-failure incidents in the epoch-renewal safety net in one
  month (see the June 20 Task Scheduler entry below) — treat epoch renewal
  as still fragile until it's survived a real boundary unattended.



- **DEPLOYED: pipelined core** (`feat/pipelined-miner`, merged to `main`). The
  upstream pipelined `odo_encrypt` (epoch baked into LUTs, free-running nonce
  sweep) is what the board runs today: **THROUGHPUT=6 @ 156.25 MHz miner clock ≈
  26.0 MH/s raw** (`odo_miner.qsf` VERILOG_MACRO + `soc_top.v` `u_pll_miner`
  ×25/8) — ~375× the old sequential FSM. Wrapper `hdl/src/pipelined/
  pipelined_miner_top.v`, register map `hps/hps_regs_pipe.h` /
  `docs/register-map.md`, daemon `hps/miner_pipe.c` + `hps/miner_io_pipe.c`.
  Autonomy intact: per-epoch bitstreams are precompiled off-board and
  hot-swapped + reboot when `job.epoch != SEED` (`usr/sbin/epoch-update.sh`).
  Sim regression: `hdl/tb/run_tb_pipe.sh` (bit-exact vs the oracle).
- **Algorithm correct in RTL, proven**: the testbenches drive the full register
  interface and reproduce upstream OdoCrypt+Keccak hashes bit-exact for multiple
  (epoch, header, nonce) vectors. The C oracle in `hps/odocrypt_state.c` matches
  upstream `odocrypt.cpp` (`make check`).
- **Mining on hardware, proven**: board mined ~485 blocks on the testnet
  (2026-06-11) and has accepted shares on mainnet. WiFi stable (0 DEAUTH events,
  USB autosuspend disabled).

### Superseded: sequential-FSM history (path retired)

> The bullets below document the **sequential-FSM** core (`hdl/src/odocrypt_top.v`,
> `~57 KH/s`), which the pipelined core above replaced. Kept for context on why
> the FSM was abandoned (logic/routing ceiling). The FSM RTL + `hps/miner.c`
> path still exist but are not deployed.

- **Dual-core FSM** ran at **~57 KH/s** @ 55 MHz (was ~52 KH/s @ 50 MHz) — the
  FSM ceiling on this device.
- **Dual-core FPGA** (`perf/dual-core` branch): two independent
  `odocrypt_core` + `odocrypt_epoch_tables` pairs in `hdl/src/odocrypt_top.v`;
  epoch write stream fanned out to both; nonce range split at midpoint; first
  found nonce latched (core 0 wins ties). Fit: **81% ALM, 29% BRAM**,
  Fmax = **52.42 MHz** (slower than single-core 55.6 MHz due to routing at
  81% utilization). Bitstream: `hdl/quartus/output_files/odo_miner.rbf`
  (3.3 MB, deployed to SD card 2026-06-14).
- **75 MHz PLL attempted** (`perf/pll-75mhz` branch, 2026-06-15): `altpll`
  synthesizes correctly (1 PLL), but fitter fails `Can't fit design in device`
  — aggressive register retiming at 81% ALM pushes past 100% capacity. Fabric
  critical path is ~19 ns vs 13.33 ns required; not achievable on this device.
- **Shared epoch tables + 55 MHz** (`perf/quad-core` branch, 2026-06-16):
  the pmask/prot/rot/rk FF tables are identical for both cores, so the second
  full `odocrypt_epoch_tables` (~3.8k ALMs) was pure waste. Split the S-box
  BRAMs into `hdl/src/odocrypt/odocrypt_sbox_bank.v` (one per core, ~0 ALM,
  pure M10K) and broadcast ONE shared FF table + write strobes. Drops the
  design **81% → 71% ALM** and lifts Fmax **52.42 → 55.9 MHz** (less routing
  congestion). 75 MHz still fails (−3.8 ns); 56.25 MHz fails the 100C corner
  (−0.111 ns); **55 MHz (11/10 PLL) signs off clean** (clk_fab setup +0.291 ns
  @ Slow/100C, all hold positive). **Deployed to SD card boot partition
  2026-06-16; verified 57,224 H/s on hardware (+10% over 52,033), 0 DEAUTH.**
  Rollback: `fpga_50mhz.rbf` on the board's FAT boot partition. Regression
  `run_tb.sh` bit-exact. Branch name is a misnomer — quad-core is infeasible
  (each core ~11.7k ALM; 3 cores > 100%).
- **Shared Keccak** (`perf/shared-keccak` branch, 2026-06-16): each
  `odocrypt_core` carried its own `keccak_hasher` (~1.8k ALM, measured), but
  Keccak runs only ~58 of every ~1910 cycles per hash (<1% duty/core). Pulled
  the unit out of the core into `odocrypt_top.v` as ONE `keccak_shared` +
  a 2-state lowest-index-priority arbiter (`kec_req`/`kec_result` handshake).
  Collisions self-skew (both cores run a fixed, data-independent FSM), so the
  throughput cost is a one-time ~58-cycle hit. **81%→** no: drops **71% → 67%
  ALM** (28,242/41,910; freed 1,333 net after the arbiter/mux). `run_tb.sh`
  bit-exact 4/4. CAVEAT: the central shared unit's routing dropped clk_fab
  Fmax **55.9 → 55.15 MHz @ Slow/100C** (only +0.05 ns at 55 MHz) — fine as an
  intermediate (NOT deployed; same ~57 KH/s as the board), but register the
  Keccak interface to reclaim margin when building the real next step. This is
  the ALM-freeing ENABLER for adding throughput — see Next steps.
- `hdl/src/odocrypt/odocrypt_core.v` is a multi-cycle FSM (~22 cycles/round,
  ~26 KH/s per core @ 50 MHz); S-boxes live in BRAM in
  `hdl/src/odocrypt/odocrypt_epoch_tables.v` (ping-pong banks, streamed from
  the HPS with waitrequest flow control). Old pipeline/mutator RTL is archived.
- The miner is integrated into Platform Designer (`hdl/qsys/soc_system.qsys`)
  as a proper Avalon component at LW bridge offset 0x0, alongside SPI display
  (ILI9341), SPI touch (XPT2046), and PIO blocks for LCD control/keys/LEDs.
  Use `hdl/qsys/qsys_add_peripherals.tcl` as the reference for how it was
  added — do NOT rebuild from `soc_system.tcl` (stale HPS parameter names).
- HPS software: stratum client with set_difficulty/share targets, correct
  Odo epoch key (`ntime - ntime % 864000`), per-job extranonce2, preemptive
  job switching, stale-job guard (`batch_job_id` checked at harvest to discard
  nonces found for switched jobs), status JSON export. `make all`,
  `make test_units`, `make check` all green.
- Touch UI: `sw/odo-ui` renders a dashboard on `/dev/fb0` with touch
  restart/reboot. Background image `linux/overlay/etc/odo-ui/bg.png` (dim=10).
  Linux side: `linux/socfpga_cyclone5_qmtech_odo.dts` +
  `linux/linux-display.fragment` + BusyBox init overlay in `linux/overlay/`.
- Board identified as DE10-Nano ball-compatible (MiSTer-style); display
  wiring on the GPIO_0 header — see `docs/DISPLAY_WIRING.md`.

Merged to `main` (2026-07-04): independent deep-review sweep (7 commits,
`9c440d2..9f30563`) — **deployed and hardware-verified** (~25.7 MH/s,
123/123 shares accepted, `pll_ok` STATUS bit reads real lock, 0 FIFO
overflow). Key fixes:
- **RTL**: `pipelined_miner_top.v` STATUS bit1 (`pll_ok`) now wired to the
  real `u_pll_miner.locked` signal (was hardcoded `1'b1` — a PLL lock loss
  was previously invisible given this board's brownout history); added a
  2-flop synchronizer into the Avalon clk domain. `soc_top.v`'s
  `fabric_reset_n` now gated by both PLLs' lock, not just the fabric one
  (closed a reset-race where the miner-domain reset synchronizer could
  sample against a not-yet-locked `clk_miner`). Commit-toggle synchronizer
  now has a proper `miner_rst`-gated reset path instead of relying solely on
  `initial` power-up state. New Qsys conduit `pll_lock` added to
  `pipelined_miner_hw.tcl` + `soc_system.qsys`; full qsys-generate +
  Quartus recompile done (0 errors, Fmax 160.93 MHz vs 156.25 MHz required,
  22,066/41,910 ALM (53%) — unchanged from the prior build).
- **HPS (`hps/stratum.c`, `hps/miner_pipe.c`, `hps/miner_io_pipe.c`)**:
  bounded `send_line()`/`tcp_connect()` timeouts (a stalled pool could
  previously block the daemon forever, bypassing the dead-pool watchdog);
  found-FIFO now drains against the *old* job before a new job is
  dispatched (previously a genuine find sitting in the FIFO at a job switch
  was validated against the new header and silently counted as stale —
  happened on every switch, not just a race window); bounded the drain
  loop and back off on backend errors instead of busy-spinning; reject
  overlong `job_id`/`coinb1`/`coinb2` instead of silently truncating;
  `odo_interval` now shares `ODO_EPOCH_INTERVAL_MAINNET/TESTNET` instead of
  duplicating the literal seconds.
- **`sw/odo-webd/odo_webd.c`**: combined status/sysinfo/wifi into one
  `/poll.json` round-trip (was 3 separate fetches every 3s against a
  single-threaded, `Connection: close` server); fixed a latent OOB-read in
  that new endpoint (unclamped `snprintf` return used to advance a shared
  buffer offset); **`TCP_NODELAY` on accepted sockets** — `send_response()`
  writes the header and body as two separate `write()` calls, and without
  `TCP_NODELAY` this stalled every single response for the delayed-ACK
  timeout (~40-200ms) regardless of round-trip count; this was the actual
  fix for the "still very slow" dashboard complaint after the `/poll.json`
  consolidation alone didn't resolve it.
- **sshd**: generates only the ed25519 host key (not RSA/ECDSA too) — RSA
  needs much more boot-time entropy than ed25519 and blocked for minutes
  early in boot; the old script silenced stderr so this looked like a
  clean but silent failure to start sshd.
- **Ops**: `epoch_autorenew.ps1`/`epoch_build_deploy.ps1` no longer default
  `-BoardIp` to the real LAN IP; SSH host-key checking is now `accept-new` +
  a persistent pinned `known_hosts` instead of disabled outright.

## Notes

- `docs/TODO.md` is the authoritative status/plan document.
- `docs/register-map.md` — the deployed pipelined-core Avalon register contract.
- `docs/review-action-plan.md` — prioritized findings from the 2026-06-22 review.
- `docs/DISPLAY_WIRING.md` — physical wiring for the SPI touch screen.
- `docs/FAN_SENSOR_WIRING.md` — J10 ("GPIO_1") fabric-PIO wiring for DS18B20,
  PWM fan, reset button; pending software tasks listed there.
- Pipelined RTL regression: `hdl/tb/run_tb_pipe.sh`. The FSM regression
  `hdl/tb/run_tb.sh` still applies to the retired FSM core; run the relevant one
  after a core/tables/keccak change, then copy updated RTL into
  `hdl/qsys/soc_system/synthesis/submodules/` before recompiling Quartus
  (Qsys caches its own copy — do NOT rely on auto-copy without re-generating).

## Next steps

**The performance path is DONE and deployed.** The architectural rewrite scoped
in `docs/pipelined-miner-scope.md` shipped: the upstream pipelined `odo_encrypt`
(epoch baked into LUTs) runs on the board at **THROUGHPUT=6 @ 156.25 MHz ≈ 26.0
MH/s raw** — ~375× the retired sequential FSM. Autonomy is preserved by
precompiling each epoch's bitstream off-board and hot-reconfiguring the fabric
on the HPS (`CONFIG_FPGA_MGR_SOCFPGA` + bridges + region; `epoch-update.sh`).

For history: the **sequential FSM maxed at ~57 KH/s** and both ways to push it
(3rd core, widen-Mix) failed to fit/route — a logic+routing ceiling, which is
exactly why the pipelined rewrite was pursued. The FSM RTL is retired in place
(`hdl/src/odocrypt_top.v`, not deployed).

Further throughput would need **THROUGHPUT=4** (~37 MH/s, the upstream max on
this Cyclone V class), but that ~2× unroll browned the core rail in earlier
tests — power/regulator-bound, **deferred** (see the `soc_top.v` POWER NOTE).

Merged to `main` (2026-06-22): the code-review hardening (stratum extranonce2
clamp / dead-pool watchdog / pool-confirmed share accept-reject, `odo-webd`
slow-loris + trusted-LAN model, docs reconciliation) and **`feat/fan-thermal`**
(PWM fan + J10 fabric-PIO thermal, hardware-verified).

Merged to `main` (2026-06-25): **`feat/uio-miner-io`** — non-root +
interrupt-driven register access. WS1 (found-nonce IRQ RTL), WS2 (kernel UIO
+ DTS), WS3 (`miner_io_pipe_uio.c`), WS3b (daemon blocks on found-nonce IRQ)
all **DONE and deployed**. `/dev/uio0` present; `backend: "uio"` confirmed in
`status.json`; daemon runs as `odo-miner-pipe-uio` from `/usr/bin/`.

Merged to `main` (2026-06-29): **`fix/review-hardening`** — full independent
code-review sweep. Key fixes: RTL async-FIFO `wfull` off-by-one (depth-7 →
depth-8 via `wgray` not `wgray_nxt`); strobe-based FIFO producer (value-compare
→ found-strobe, plus reset sync into miner domain); overflow flag (STATUS bit3);
stratum NaN/overflow/EN1-overlong/EN2-oversized hardening + resync counter;
daemon fork-in-thread fixed (`sync()+reboot()` replaces `system("reboot")`),
Y2038 `%lld`/`(long long)` for time fields, barrier before Avalon COMMIT,
thermal read-fail fan-full fallback; `odo-webd` cookie-header anchoring (C1
bypass fixed), fail-closed token gen, `SameSite=Lax`, `ci_strstr` for
case-insensitive header scan, `ODO_WEB_CONF` env override for tests; wpa SSID
sanitize; BusyBox init script EOL (`eol=lf` in `.gitattributes`); build scripts
`PIPESTATUS[0]` fix; DEPLOYMENT.md banner correcting stale info. New tests:
`test_stratum_fuzz` (ASan/UBSan), `test_webd_auth.sh` (10 assertions),
`test_gfx_bounds` (ASan/UBSan), `tb_pipe_fifo.v`/`run_tb_fifo.sh` (FIFO burst/
overflow/drain/irq); CI lint job (shellcheck + CRLF `i/crlf` guard). Bitstream
refit: **22,160/41,910 ALM (53%), timing met**, deployed to board.

Non-performance backlog:
1. ~~Fan/thermal~~ — done + **hardware-verified 2026-06-22** (PWM fan, DS18B20,
   tach, 50/45 °C hysteresis; see `docs/FAN_SENSOR_WIRING.md`).
   ~~Reset-button~~ — **DONE 2026-06-24** (J10 pin 36/AE20, `pio_thermal` bit2,
   active-low ~2 s hold → reboot; polling driver in `thermal.c`).
2. ~~Pool failover~~ — done; `ODOD_POOL_HOST2/PORT2` wired into the reconnect
   loop in both `hps/miner.c` and the active `hps/miner_pipe.c`.
3. ~~async-FIFO the found handoff~~ — **DONE 2026-06-28**: depth-8 dual-clock
   async FIFO (Gray-code CDC) in `pipelined_miner_top.v` replaces the 1-deep
   handshake; sim bit-exact + hardware-verified (finds delivered + pool-accepted,
   0 rejected). ~~`odo-webd` auth~~ — **DONE**: opt-in styled login (set
   `PASSWORD=` in `/etc/odo-web.conf`), off by default. Web dashboard reached
   touch-UI parity (fan boost / reset stats / pool-failover indicator).
4. ~~stratum `parse_hex_u32` / oversized-line hardening~~ — **DONE 2026-06-28**
   (M5: reject >8-digit hex overflow; M1: drop the oversized-line tail to the
   next newline). ~~Full review hardening~~ — **DONE 2026-06-29** (see above).
   Throughput is power-bound at T=6 (T=4 ~37 MH/s browns the core rail —
   deferred, needs an external 1.1 V supply / regulator change).
