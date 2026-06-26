# Review Action Plan (2026-06-22)

> **Status as of 2026-06-26:** Buckets A (stratum hardening), B (docs
> reconciliation), D (UIO — WS1–WS4 + WS3b), and E (fan/thermal + reset
> button) have all **shipped to `main`**. Bucket C (async-FIFO found handoff,
> `odo-webd` auth) remains deferred per accepted-risk decisions below.

Consolidated next-steps plan from a three-pass code + documentation review:
1. **Docs + RTL/register layer** (inline pass)
2. **Production HPS mining daemon** — `miner_pipe.c`, `miner_io_pipe.c`, `stratum.c`, `job.c`
3. **UI / web / UIO / thermal / PWM** — `odo_ui.c`, `odo_webd.c`, `miner_io_uio.c`,
   `thermal.c` (on `feat/fan-thermal`), `pwm_fan.v`, `soc_top.v`

**Headline:** no Critical (no reachable memory-corruption/RCE). The whole mining
data path (byte order, target math, epoch key, fd/mmap/socket lifecycle) and the
deployed RTL verified **correct**. Work falls into four buckets across three
branches. Keep them on separate branches — do not mix daemon hardening, the UIO
IRQ work, and the fan branch.

Severity legend from the reviews: H = High, M = Medium, L = Low.

---

## Bucket A — Production daemon hardening  →  branch `fix/daemon-hardening` off `main`

| Ref | Sev | Issue | Location | Effort |
|-----|-----|-------|----------|--------|
| H3 | High | `blocks_found` / `best_diff` incremented on fire-and-forget submits (never pool-confirmed); persisted to disk → corrupts stats | `miner_pipe.c:347-359` | ~30 min |
| H1 | High | `extranonce2_size` clamped against the EN1 array, not `JOB_MAX_EXTRANONCE` (benign now, silent overflow if the constant drops) | `stratum.c:233` | ~5 min |
| M5 | Med | `parse_hex_u32` stops silently at garbage → malformed `ntime`/`version` mines a zeroed field instead of rejecting the job | `stratum.c:123` | ~15 min |
| M6 | Med | No idle-pool watchdog — a silently half-dead socket is only detected on the next submit | `stratum.c:527` | ~1 hr |
| M1 | Med | A single >16 KiB line tears down the connection → reconnect loop, instead of rejecting just the line | `stratum.c:544` | ~30 min |
| H2 | Med | extranonce2 counter repeats every `2^(8*size)` jobs if a pool sets EN2_SIZE < 8 (duplicate coinbases); no guard | `stratum.c:340` | ~20 min |

Verify with `make test_units` + the stratum loopback test. No hardware needed.

## Bucket B — Documentation reconciliation  →  off `main` (can share Bucket A's branch)

- **Reconcile THROUGHPUT / hashrate** — ground truth is `odo_miner.qsf:51` = `THROUGHPUT=7`
  (150 MHz / 7 ≈ 21.4 MH/s raw). Conflicting figures live in CLAUDE.md, `docs/TODO.md`
  (T=8 / 16.9 MH/s), commit `f730cb6` (125 MHz / 14.4 MH/s), and the "37.5 MH/s" framing
  (that's T=4, the *upstream target*, not current). Pick the real measured number and fix all.
- **Rewrite `docs/register-map.md`** — it documents the retired FSM core (EPOCH,
  NONCE_START/END, table-streaming) and a "Known Issues" list marked *"Critical: won't
  produce valid shares"* — directly contradicted by 485 blocks mined. Replace with the
  pipelined map (`hps_regs_pipe.h`), archive the FSM map + stale bug list.
- **Promote the pipelined miner to CLAUDE.md "Current status."** The status block is still
  FSM-era (~57 KH/s); the shipped pipelined miner only appears as a *future* "Next step."
- Note the new found-nonce IRQ (f2h_irq0 line 3) in the register docs / `hps_regs_pipe.h`.

## Bucket C — Network-facing security on `odo-webd`  →  branch `fix/webd-hardening` off `main`

`odo_webd.c` listens on port 80 on the LAN. No path traversal and inputs are whitelisted
(verified), but:

| Ref | Sev | Issue | Location | Fix |
|-----|-----|-------|----------|-----|
| H1 | High | Unauthenticated client can trigger `iw scan` / bounce `wlan0` / reboot via expensive `system()`/`popen()` endpoints, no auth or rate limit | `odo_webd.c:241-242,660` | token-gate the mutating/expensive endpoints; cache scans; never `ip link set wlan0 up` on a GET |
| H2 | High | Single-threaded accept loop + 5 s `SO_RCVTIMEO` = trivial slow-loris; a few idle peers stall the dashboard | `odo_webd.c:446-515` | drop timeout to ~1 s; add request-size cap (413); consider non-blocking poll loop |
| M3 | Med | POST body > 8 KB silently truncated then parsed | `odo_webd.c:472-478` | reject with 413 |
| M4 | Med | Custom page > 64 KB silently truncated | `odo_webd.c:486-491` | log/​warn on truncation |
| M5 | Low | endpoint dispatch uses `strncmp` prefix match (`/wifi` also matches `/wifiscanFOO`) | `odo_webd.c:495-510` | match full token |

Urgency depends on LAN trust (board is on a home network), but unauthenticated **reboot**
is the kind of thing to close regardless.

## Bucket D — Continue UIO IRQ work  →  branch `feat/uio-miner-io` (current)

WS1 (IRQ output on `pipelined_miner_top.v`) is **done + regression-proven** (commit `7691227`).
The review found the *existing* `miner_io_uio.c` is more broken than the scope doc assumed,
so WS3 is closer to a rewrite than a finish:

- **H3** — `miner_io_uio.c` is missing `miner_io_check_result()` + `miner_io_read_perf()`
  → won't link against `miner_io.h` callers.
- **H4** — its IRQ path is a no-op: `uio_wait_irq(5)` caps latency at the 5 ms sleep
  (identical to polling), and it never **re-arms** the UIO interrupt (`write(fd,&1,4)`),
  so after the first IRQ `poll()` never fires again and it silently degrades to pure polling.
- It also targets the **FSM** register map, not `hps_regs_pipe.h`.

Revised WS plan:
- **WS2** — kernel `CONFIG_UIO` + `CONFIG_UIO_PDRV_GENIRQ`, DTS node for the miner reg
  window + IRQ line 3 (needs DTB rebuild + reflash). udev rule + non-root `miner` user.
- **WS3** — write `miner_io_pipe_uio.c` fresh against `hps_regs_pipe.h`, with a *correct*
  blocking-and-re-arming IRQ path and a **bounded** timeout (never infinite — scope-doc
  risk #3, so a stuck IRQ degrades to polling instead of hanging under the watchdog).
- **WS4** — hardware latency measurement vs the 5 ms poll baseline (the go/no-go number).

## Bucket E — Hardware-gated / deferred

- `feat/fan-thermal` hardware verification (tomorrow's test) → then merge. Thermal code
  review: 1-wire `delay_us` busy-wait protects duration but not the sampling *instant*
  under load (M1) — mitigated by 5-attempt CRC retry; consider `SCHED_FIFO` around a
  DS18B20 transaction. `pwm_fan.v` / `soc_top.v` conduits verified correct.
- Reset-button driver (J10 pin 36 / AE20 — wired, no software).
- Async-FIFO the 1-deep found handoff in `pipelined_miner_top.v` before heavier soak
  (already self-documented in the RTL).
- Drop the root-level `*.dtb` build artifacts from version control.

---

## Recommended order

1. **Bucket A + B** (off `main`) — highest value-to-risk: one real data-integrity bug (H3),
   quick correctness fixes, and docs that actively mislead. Safe, no hardware.
2. **Bucket C** (off `main`) — close the unauthenticated-reboot exposure; small, self-contained.
3. **Bucket D WS2/WS3** (`feat/uio-miner-io`) — the larger engineering effort; the in-flight
   branch's natural next step now that WS1 is proven.
4. **Bucket E** — as hardware test results land.
