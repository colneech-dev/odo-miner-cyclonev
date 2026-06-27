# odo-miner-cyclonev

This repository contains a standalone Cyclone V SoC port of the `odo-miner` OdoCrypt FPGA miner, built on top of the vendored upstream source in `third_party/odo-miner/`.

The project targets an autonomous appliance that boots from SD card and mines DigiByte's OdoCrypt algorithm fully autonomously — no host PC required.

## ⚠️ Security — read before flashing a build

This image is built for a **trusted LAN**. Before exposing a board, you **must**:

- **Change the default root password.** Buildroot ships the rootfs with root
  password **`odo-miner`** (`linux/buildroot_cyclonev_defconfig`,
  `BR2_TARGET_GENERIC_ROOT_PASSWD`). It is public and identical on every build —
  log in and `passwd` immediately, or change the defconfig before building.
- **Add your own SSH key.** `linux/overlay/root/.ssh/authorized_keys` ships as an
  **empty template** — root SSH is key-only and disabled until you add a key
  (use the serial console, or `deploy-staging/fix-ssh-key.ps1`). Do **not**
  commit a personal key you don't want public.
- **`odo-webd` (port 80) has no authentication** — it's a LAN-only dashboard.
  Never port-forward it or expose the board to the internet.

## Key documentation

- docs/architecture.md — main project architecture and execution plan
- docs/register-map.md — FPGA register interface contract
- docs/project-plan.md — validation-first execution brief and phase breakdown
- docs/working-notes.md — working notes and implementation ideas

## Source layout

- third_party/odo-miner/ — vendored subset of the upstream `odo-miner` project (the OdoCrypt/Keccak reference in `src/crypto/` and the per-epoch RTL generator `odo_gen` in `src/verilog/`); see its `NOTICE` for provenance + per-file licensing
- hdl/ — FPGA/RTL sources
- hps/ — HPS Linux daemon, register definitions, and FPGA smoke-test utilities
- boot/ — bootloader, device-tree, SD card build artifacts
- linux/ — Buildroot and rootfs image scripts
- sw/ — user-space software and services
- scripts/ — build and deployment helpers (includes HPS build and smoke-test scripts)
- services/ — unit/service files
- docs/ — project documentation and bring-up notes
- third_party/ — vendored upstream source (see above)

## License

This project is distributed under **GPL-3.0-or-later** (see [LICENSE](LICENSE)).
The FPGA core derives from the upstream `odo-miner` RTL (GPLv3), so the project
as a whole is GPLv3. The vendored upstream subset under `third_party/odo-miner/`
mixes licenses per file — GPLv3 for `odo_gen`/`keccak800.v`, MIT/X11 for the
OdoCrypt sources, and CC0 for the Keccak reference — all documented with
preserved headers in [third_party/odo-miner/NOTICE](third_party/odo-miner/NOTICE).
