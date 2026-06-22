# Scope: UIO-based FPGA Register Access (non-root + interrupt-driven)

Status: **in progress** (updated 2026-06-22). Branch: `feat/uio-miner-io`.

### Progress

- **WS1 — RTL interrupt output: DONE.** `pipelined_miner_top.v` has an `irq`
  output (= `found_valid`, level, clears on FNONCE read), wired to `f2h_irq0`
  line 3 in Qsys; `tb_pipelined_miner.v` asserts one rising edge per nonce,
  cleared on consume. `run_tb_pipe.sh` PASS, nonce VERIFY_OK. *(Needs a Quartus
  recompile + reflash before it's on the board.)*
- **WS3 — UIO software backend: DONE (untested on HW).** `hps/miner_io_pipe_uio.c`
  is a drop-in for the `miner_io_pipe.h` contract (supersedes the broken
  `miner_io_uio.c`): correct UIO IRQ **re-arm** and a **bounded** wait
  (`miner_io_pipe_wait()`, also added to the `/dev/mem` backend) so a stuck IRQ
  degrades to polling, not a hang. `make odo-miner-pipe-uio` builds clean.
- **WS2 — device exposure: DONE (untested on HW).** `linux-uio.fragment`
  (`CONFIG_UIO` + `CONFIG_UIO_PDRV_GENIRQ`), a `generic-uio` DTS node at
  `0xff200000` with IRQ DT `<0 43 ...>` (= GIC 75 = f2h line 3), the
  `uio_pdrv_genirq.of_id=generic-uio` bootarg, and the build-script copy. Needs
  a **kernel/DTB rebuild + reflash** to verify `/dev/uio0` appears.

### Remaining

- **WS2b — non-root user + udev rule + `S90odod` privilege-drop: DEFERRED**
  per decision 3 below — must fold in the fan/thermal privilege footprint
  (framebuffer, thermal/PWM regs) that's pending tomorrow's hardware test.
- **WS3b — daemon integration:** switch `miner_pipe.c`'s fixed-interval found
  drain to call `miner_io_pipe_wait()` (the actual latency win). Not yet done —
  kept separate so the production `/dev/mem` build is untouched until measured.
- **WS4 — hardware verification:** Quartus recompile + reflash, confirm
  `/dev/uio0` + a non-root open, measure found-nonce latency vs the 5 ms poll
  (the go/no-go number), soak for missed/double nonces.

## 1. Why

`hps/miner_io.c` (the path both `miner.c` and `miner_pipe.c` actually use today)
accesses the FPGA register block via `/dev/mem` — direct physical-memory mmio.
That requires **root**, and `/dev/mem` grants access to *all* physical memory,
not just the ~4 KiB miner register window. A bug in the daemon is a root
compromise, not a contained one.

`hps/miner_io_uio.c` is a half-built alternative using the Linux **UIO**
(Userspace I/O) framework: it exposes just the miner's register block via
`/dev/uioN`, permission-gated by a normal udev rule (no root needed), and UIO
natively supports **blocking on a hardware interrupt** instead of polling a
status register.

The interrupt angle isn't just a nicety here — **this session's single
biggest hashrate win was tightening `miner_pipe.c`'s poll interval (50ms →
5ms)**, because polling was the bottleneck, not the FPGA core itself. An
interrupt-driven completion path
would eliminate that tradeoff entirely: zero latency between "FPGA found a
nonce" and "daemon knows," zero CPU spent polling in between — not just
polling *faster*.

## 2. What exists vs what's missing

| Area | Finding | Implication |
|------|---------|-------------|
| `miner_io_uio.c` | Implements `init/shutdown/load_epoch/dispatch_job/dispatch_range/poll_result/stop/start/status` against the **FSM-era register map** (`hps_regs.h`, with epoch-table streaming) | Targets `miner.c`'s API, not `miner_pipe.c`'s (`hps_regs_pipe.h`) |
| `miner_io_pipe.c` (the daemon actually on the board) | No UIO equivalent exists | As-is, finishing `miner_io_uio.c` would benefit `miner.c` (not currently deployed) but **not** the production `miner_pipe.c` daemon — a `miner_io_pipe_uio.c` would be separate, additional work if the goal is to help the live system |
| API completeness | Missing `miner_io_check_result()` and `miner_io_read_perf()` — both declared in `miner_io.h`, both used by `miner.c` | Wouldn't link today; must be added for parity |
| Header file | None — `miner_io_uio.c` has no `.h`, just borrows `miner_io.h`'s declarations | Fine as-is (same API), but worth a short doc comment confirming intentional |
| IRQ wait latency (current code) | `uio_wait_irq()` is called with a hardcoded 5ms timeout (`miner_io_poll_result`'s `poll_ms`), then falls through to a manual `STATUS` register read either way | **As written, this does not realize the latency benefit of interrupts** — it's polling `/dev/uioN` on the same 5ms cadence as the plain busy-poll fallback. Needs a real fix: block indefinitely (`poll_ms = -1`) and trust the wakeup, with the manual `STATUS` check only as the *result* of that wakeup, not a parallel cadence |
| Qsys IRQ wiring | `f2h_irq0` lines 0/1/2 are taken (`spi_lcd`, `spi_touch`, `pio_in` — `hdl/qsys/qsys_add_peripherals.tcl:99-104`). **Neither `odocrypt_top.v` nor `pipelined_miner_top.v` has an interrupt output port at all today.** | This is new RTL, not just a software/kernel change — must add a `STAT_FOUND`-driven IRQ output to whichever core variant is targeted, then wire it to a free line (`irqNumber 3`+) |
| Kernel/DTS | Buildroot kernel config for `uio_pdrv_genirq` (or a custom UIO driver) and a devicetree node declaring the miner's register range + IRQ — **neither exists yet** | Same blocker class as the fan/thermal work: needs a DTB rebuild + reflash, can't be done by a software-only patch |
| `miner_io.h` comment | Claims a UIO alternative is "available" | Not true today — would fail to link. Worth fixing regardless of whether this project proceeds |

## 3. Workstreams

### WS1 — RTL: interrupt output (the part that doesn't exist yet)
- Add a 1-bit interrupt output to the Avalon wrapper (`odocrypt_top.v` and/or
  `pipelined_miner_top.v` depending on §6 decision), asserted when
  `STAT_FOUND` becomes set, cleared on `CTRL_CLEAR_FOUND` (mirrors the
  existing found-latch logic — should be a small, low-risk addition).
- Wire it into `qsys_add_peripherals.tcl` on a free `f2h_irq0` line.
- Regression: `hdl/tb/run_tb.sh` unaffected (interrupt is additive, doesn't
  change register semantics) — extend the testbench to assert the IRQ line
  fires exactly once per found nonce, not double-fired or missed.

### WS2 — Kernel/DTS: UIO device declaration
- Buildroot kernel config: enable `CONFIG_UIO` + `CONFIG_UIO_PDRV_GENIRQ`.
- Devicetree node: `compatible = "generic-uio"`, reg = the miner's LW bridge
  offset + `MINER_SPAN`/`PIPE_MINER_SPAN`, `interrupts` = the assigned
  `f2h_irq0` line. Add to `linux/socfpga_cyclone5_qmtech_odo.dts`.
- udev rule: `KERNEL=="uio0", GROUP=="miner", MODE="0660"` (per the existing
  comment in `miner_io_uio.c`) + create a non-root `miner` user/group in the
  rootfs overlay, switch `S90odod` to drop privileges after opening the
  device (or run as that user from the start, if `/dev/mem` is no longer
  needed for anything else the daemon does).

### WS3 — Software: API completeness + the real IRQ fix
- Add `miner_io_check_result()` and `miner_io_read_perf()` to
  `miner_io_uio.c` to match `miner_io.c`'s contract.
- Fix `uio_wait_irq()`'s usage in `miner_io_poll_result()` to actually block
  (no artificial 5ms cap) so the latency win is real, not theoretical.
- If targeting the production daemon (§6): build `miner_io_pipe_uio.c`
  against `hps_regs_pipe.h` (no epoch-table streaming, much shorter file —
  the pipe daemon's register set is already simpler).

### WS4 — Verification
- Hardware bring-up: confirm `/dev/uio0` appears, confirm a non-root user can
  open/mmap/poll it, confirm an interrupt actually fires on a real found
  nonce (not just a timeout-driven false positive from the 5ms fallback).
- Latency measurement: compare time-to-detect a found nonce against the
  current 5ms-poll baseline — this is the number that justifies the project.
- Soak test: confirm IRQ-driven detection doesn't introduce missed/double
  nonces under sustained load, same bar as the T=6/T=7 throughput soak tests
  this session.

## 4. Top risks

1. **Scope creep risk: which daemon benefits.** If this only targets
   `miner.c` (not currently deployed), it's a security improvement with no
   measured performance payoff on the live system. Decide §6 before WS1.
2. **IRQ line is scarce.** Only `f2h_irq0` lines 3-31 are free (or use
   `f2h_irq1`, currently fully unused) — low risk, but confirm during WS1
   rather than assuming.
3. **The "fix" in WS3 (blocking indefinitely on IRQ) changes failure-mode
   behavior** — if the kernel UIO driver ever stops delivering interrupts
   (misconfigured DTS, IRQ storm masking, etc.) the daemon could hang
   instead of degrading to polling. Needs a watchdog-visible timeout even in
   the "block on IRQ" path, not truly infinite.
4. **Non-root daemon may need other privileges** beyond the register window
   (e.g. the framebuffer/touch device for `odo-ui`, GPIO for the planned
   fan/reset work) — confirm the full privilege footprint before assuming
   "drop root" is a clean one-line change to `S90odod`.

## 5. Phased plan

| Phase | Goal | Output | Rough effort |
|-------|------|--------|--------------|
| **0 — Spike** | Does a found-nonce IRQ actually reduce detection latency vs the current 5ms poll, on a non-production test build? | Minimal IRQ output on `odocrypt_top.v` (FSM core, lower stakes than touching the live pipelined core), `miner_io_uio.c` fixed (WS3) + API-complete, measured on hardware. Go/no-go gate. | 3-5 days |
| **1 — Software hardening** | Non-root operation, even without the IRQ win | udev rule, non-root user, `S90odod` updated, confirm `/dev/mem`-free operation works end-to-end on the FSM daemon | 2-3 days |
| **2 — Production target** (if §6 says yes) | Same benefit on `miner_pipe.c`, the daemon actually running | `pipelined_miner_top.v` IRQ output, `miner_io_pipe_uio.c`, full soak test, deploy | 1 week |

## 6. Decisions (resolved 2026-06-22)

1. **Which daemon is this for?** → **`miner_pipe.c` (production)**. Skip the
   FSM-core-only spike in §5 — go straight at the live pipelined daemon and
   `pipelined_miner_top.v`. Accepted tradeoff: this means a new IRQ output on
   the core that's currently stable in production, with a full
   re-fit/re-timing-closure/re-soak cycle before it can replace what's
   deployed.
2. **Non-root worth doing standalone?** → **Yes.** Proceed with Phase 1
   (udev rule, non-root user, `S90odod` change) even if the IRQ latency
   measurement in Phase 0/2 comes back marginal — `/dev/mem` root exposure is
   worth closing on its own.
3. **Sequencing vs. fan/thermal hardware verification** → **Start scoping
   now, in parallel.** This branch is independent of `feat/fan-thermal`'s
   pending hardware test; both can proceed concurrently. Risk item 4 below
   (privilege footprint across miner regs + thermal/PWM regs + framebuffer)
   still needs to fold in whatever fan/thermal lands on, so the *implementation*
   of WS2's non-root user/udev setup should wait until that footprint is known
   even though scoping/RTL work here can start immediately.

Given decision 1, the phased plan in §5 collapses: skip the FSM-core spike,
start directly on **WS1 (IRQ output on `pipelined_miner_top.v`)** as the
first concrete step. Effort estimate accordingly closer to the original
Phase 2 number (~1 week) than the staged 3-5/2-3/1-week breakdown, since
there's no separate lower-risk spike absorbing early unknowns.
