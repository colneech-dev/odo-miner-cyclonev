# odo-miner-cyclonev

This repository contains a standalone Cyclone V SoC port of the `odo-miner` OdoCrypt FPGA miner, built on top of the vendored upstream source in `upstream/odo-miner/`.

The project targets an autonomous appliance and may optionally include an external ESP32-based WiFi/display module (Liligo-like) for local status/management and output.

## Key documentation

- docs/architecture.md — main project architecture and execution plan
- docs/register-map.md — FPGA register interface contract
- docs/project-plan.md — validation-first execution brief and phase breakdown
- docs/working-notes.md — working notes and implementation ideas

## Source layout

- upstream/odo-miner/ — vendored upstream baseline source and original host/FPGA design
- hdl/ — FPGA/RTL sources
- hps/ — HPS Linux daemon, register definitions, and FPGA smoke-test utilities
- boot/ — bootloader, device-tree, SD card build artifacts
- linux/ — Buildroot and rootfs image scripts
- sw/ — user-space software and services
- scripts/ — build and deployment helpers
- services/ — unit/service files
- docs/ — project documentation and bring-up notes
