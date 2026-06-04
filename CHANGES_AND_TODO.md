# Changes, Notes, and TODOs — odo-miner-cyclonev

This file summarizes all code and configuration artifacts I added during the recent integration session, the assumptions made, risks discovered, how to test the changes on hardware, and a prioritized TODO list for a future reviewer.

Treat this as a review / handoff document. It is intended to make it easy for someone to review, integrate, and continue the work.

---

## Summary of added files (created in this session)

These files were created and presented in the session. They exist in the session storage and were provided for download. Before committing, please review, adapt register offsets, rename to canonical filenames, and run hardware tests.

- hps.minerc.c — concise miner main skeleton (integration entry points, logging, signal handling). (temporary name)
- hps.minor_io.c — UIO-backed MMIO bridge (compact polling implementation, default /dev/uio0 and assumed register map). (temporary name)
- hps.minor_io_test.c — small test program to exercise `miner_io` (dispatch test header, poll for result). (temporary name)
- hps_epoch_watcher.c — epoch watcher thread module (start/stop API; callback-based epoch and epoch-data providers).
- hps.miner_with_watcher.c — integrated example that starts the watcher, loads epoch files from `./epochs/epoch_<N>.bin`, and runs a simplified mining loop.
- hps.Makefile.local — non-destructive local Makefile to build `miner_with_watcher` and `miner_io_test` without overwriting existing Makefile.
- (modified) hps/Makefile — appended safe targets for miner/test to the existing Makefile.
- services/odo-miner.service — detailed systemd unit file with example `/etc/default/odo-miner` environment snippet.

> Note: Several files were created using temporary names (dots in the filename) to avoid clobbering repository files. Before committing, rename the files to canonical names (suggested mapping below).

### Suggested canonical filenames (rename before commit)
- hps.minerc.c -> hps/miner.c (or integrate into the existing `hps/miner.c`) 
- hps.minor_io.c -> hps/miner_io.c
- hps.minor_io_test.c -> hps/miner_io_test.c
- hps_epoch_watcher.c -> hps/epoch_watcher.c
- hps.miner_with_watcher.c -> hps/miner_with_watcher.c
- hps.Makefile.local -> hps/Makefile.local (keep as-is)

---

## High-level description of each new artifact

- miner_io (hps/miner_io.c):
  - Purpose: MMIO UIO bridge that writes headers and nonce ranges into the FPGA, issues a dispatch command, and waits for a result.
  - Mode: Polling-based fallback. The code uses mmio mmap, writes header bytes to a `HEADER_BASE` area, sets `NONCE_START` and `NONCE_COUNT`, writes `CONTROL` with `CMD_DISPATCH`, then polls `STATUS` for `STAT_RESULT_READY`.
  - NOTE: Register offsets and ACK semantics are assumed and must be aligned with the canonical register-map (see `docs/register-map.md` and `hps/hps_regs.h`).

- miner_io_test (hps/miner_io_test.c):
  - Purpose: Small binary to dispatch a test header and a small nonce range and poll/present the result (or timeout) for hardware bring-up.

- epoch_watcher (hps/epoch_watcher.c):
  - Purpose: Thread-based watcher that polls a user-supplied epoch getter callback. When the epoch changes it fetches epoch table bytes (optional data getter callback) and calls `odo_fpga_load_epoch(epoch, epoch_data, epoch_words)`.
  - Intended use: Start at boot (or from miner main); keeps the FPGA epoch synchronized to the chain.

- miner_with_watcher (hps/miner_with_watcher.c):
  - Purpose: Example miner program that ties together `stratum`, `miner_io`, and `epoch_watcher`. It includes a disk-backed epoch data getter (`./epochs/epoch_<N>.bin`) and reads the current epoch from `./current_epoch` by default.

- systemd unit (services/odo-miner.service):
  - Purpose: Comprehensive systemd service template and example environment file to run the miner as a service. Includes guidance for runtime dirs and optional security flags.

---

## Assumptions made in the added code (important)

1. MMIO register map (assumed offsets in miner_io) — verify against docs/register-map.md:
   - CONTROL = 0x00
   - NONCE_START = 0x04
   - NONCE_COUNT = 0x08
   - STATUS = 0x0C
   - RESULT_NONCE = 0x10
   - RESULT_DIGEST = 0x20
   - HEADER_BASE = 0x80
   - EPOCH_BASE = 0xC0

2. Dispatch protocol:
   - Copy header bytes to HEADER_BASE.
   - Write NONCE_START and NONCE_COUNT.
   - Write CONTROL = CMD_DISPATCH (1).
   - The FPGA sets STATUS bit STAT_RESULT_READY (0x1) when a candidate is found; reading digest and nonce is done from RESULT_DIGEST and RESULT_NONCE.
   - Clearing result-ready is done by writing STAT_RESULT_READY back to STATUS (this is an assumption; hardware may require different ACK/clear semantics).

3. Endianness and digest layout: digest bytes are read as 32 contiguous bytes from RESULT_DIGEST region. The code assumes this is already in correct byte order for submission. If the FPGA presents digest words in different endianness or word order, byte-swapping will be necessary.

4. UIO device presence: default uses `/dev/uio0`. Running on the board may require root or proper udev rules.

5. Simple privilege model: service file suggests running as a `miner` system user; device access will require udev rules or group membership.

---

## Risks, known issues, and items requiring human review

- Mismatch between assumed register offsets and the repository's canonical register map will cause incorrect behavior. This is the single highest-risk item. Must be resolved before hardware tests.
- ACK/clear semantics are hardware-specific. The miner_io code writes STAT_RESULT_READY into STATUS to clear; this may be wrong if the hardware expects a separate ACK register or clear-on-read behavior.
- miner_io currently uses polling (busy/wait). If the UIO device supports interrupts, implement an IRQ wait path using `poll()` and reading from the UIO fd to consume/re-arm IRQs.
- Some session files were created with temporary names to avoid overwriting repo files. Ensure renaming and integration is done carefully to avoid losing existing code.
- The miner_with_watcher program is an example and not a complete production-ready miner. It lacks persistent nonce allocation, advanced error handling, and robust target verification.

---

## How to test on hardware — recommended bring-up steps

1. Ensure device and permissions:
   - Confirm `/dev/uio0` exists. If running as non-root, add a udev rule to set group and mode or run as root for the first test.
   - Example udev rule (create `/etc/udev/rules.d/99-odo-miner.rules`):

```text
KERNEL=="uio0", GROUP=="miner", MODE="0660"
```

2. Build test binary:
   - Using local Makefile: `make -f hps.Makefile.local miner_io_test`
   - Or compile manually: `gcc -O2 -pthread -o miner_io_test hps.minor_io.c hps.minor_io_test.c`

3. Run miner_io_test:
   - `sudo ./miner_io_test /dev/uio0` (or drop `sudo` if udev rules permit)
   - Expected: either a timeout (no result) or printout of found nonce and digest.
   - Monitor kernel logs for faults: `sudo dmesg -w` or `sudo journalctl -k -f`.

4. If miner_io_test fails:
   - Check register offsets in `docs/register-map.md` and update `hps/miner_io.c` accordingly.
   - Check `hps/odocrypt_state.c` for epoch streaming order and ensure the epoch file format matches the loader.

5. Run integration example (after renaming & building):
   - Place epoch files into `./epochs/epoch_<N>.bin` and create `./current_epoch` with the epoch number.
   - Build: `make -f hps.Makefile.local miner_with_watcher` or integrate into the repo Makefile.
   - Run under supervisor or directly: `./miner_with_watcher` and monitor logs.

6. Install systemd unit (after validation):
   - Copy `services/odo-miner.service` to `/etc/systemd/system/odo-miner.service`.
   - Create `/etc/default/odo-miner` (see example in the service file).
   - `sudo systemctl daemon-reload && sudo systemctl enable --now odo-miner`.
   - Monitor logs: `sudo journalctl -u odo-miner -f`.

---

## Prioritized TODOs (for future reviewer / developer)

Priority: HIGH
- [ ] Align `hps/miner_io.c` register offsets and ACK semantics to canonical register map in `docs/register-map.md` or `hps/hps_regs.h`.
- [ ] Rename temporary session filenames to canonical repository filenames and integrate into the repo build.

Priority: HIGH → MEDIUM
- [ ] Implement IRQ-driven waiting in `miner_io` using `poll()` / `read()` on the UIO fd and fallback to polling if IRQs not configured.
- [ ] Confirm endianness and digest word order; add byte-swap logic if necessary.

Priority: MEDIUM
- [ ] Create udev rules to grant the `miner` system user access to `/dev/uioX` safely.
- [ ] Add a persistent nonce allocator and restart recovery (store last_nonce in a small file or use atomic counters in shared memory).
- [ ] Add thorough error handling and retry/backoff strategies for `odo_fpga_load_epoch` failures (including rollback or safe-mode behavior).

Priority: LOW → MEDIUM
- [ ] Add Prometheus or JSON metrics for shares found, reject counts, epoch loads, and FPGA fault counters.
- [ ] Expand unit tests and static analysis (clang-tidy; add compile-time warnings as CI gates).
- [ ] Add integration tests or a hardware-in-the-loop CI runner if feasible.

---

## Suggested commit/PR checklist for the reviewer

1. Verify and correct register offsets in miner_io against repo docs.
2. Rename and place files into `hps/` with canonical names.
3. Run `make -f hps.Makefile.local miner_io_test` on a development board and capture logs.
4. If tests pass, add build targets to the repository Makefile (or accept `hps.Makefile.local`) and commit changes in a single PR.
5. Add a README section describing service installation, udev rule, and bring-up steps.
6. Add a brief code review focusing on concurrency and mmio usage (look for `__sync_synchronize()` usage and memory barriers).

---

## Useful references and pointers inside the repo

- docs/register-map.md — canonical register offsets (use this as authoritative for `miner_io` mapping).
- hps/odocrypt_state.c — existing epoch loading/streaming behavior (follow its ordering exactly for epoch files).
- hdl/ — FPGA HDL sources for internal signals and literal register names; use them to cross-check register behaviors and ACK semantics.

---

If you want, I can now perform one of the following immediately:
- Update `hps/miner_io.c` to match the canonical register map (if you permit me to read `docs/register-map.md` or provide its contents here).
- Implement IRQ support in miner_io with fallback to polling.
- Rename session files to canonical names and produce a commit-ready diff/patch for you to apply.

Reply with one action (for example: "Align miner_io to register map and rename files") and I'll proceed. If you'd like the new Markdown file edited or expanded I can update it before saving into the repo.