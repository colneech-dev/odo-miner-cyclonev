# Complete Setup From Scratch

Everything needed to go from a blank Windows PC to a standalone mining
appliance. Each stage links to the detailed doc; this page is the spine.

What you end up with: a QMTECH Cyclone V SoC board that boots from SD,
loads the miner bitstream, joins your network (Ethernet or WiFi), mines
DigiByte OdoCrypt against your pool, shows status on a touch TFT, and is
managed from a web browser. No PC attached for day-to-day operation; epoch
rollovers are handled with zero manual steps (a per-epoch bitstream is
precompiled off-board and auto-staged + applied — see §9).

---

## 1. Hardware

| Item | Notes |
|---|---|
| QMTECH Cyclone V SoC KFB board (dual SDRAM, 5CSXFC6C6U23) | the target |
| 5 V regulated PSU for the board | per board spec |
| microSD card, 16 GB+ | the 8 GB rootfs needs headroom |
| ILI9341 SPI TFT with XPT2046 touch (2.2"–3.2") | the common 14-pin red modules |
| 14 female-female jumper wires | display → GPIO_0 header |
| mini-USB cable | board console (CH340, always-works recovery path) |
| Ethernet cable | first-time setup (WiFi is configured afterwards, via browser) |
| *(optional)* USB WiFi dongle, Realtek RTL8188/87xx/88xx family | firmware already in the image |
| *(optional)* DS18B20 + 4.7 kΩ resistor | temperature sensing (post-bring-up) |
| *(optional)* SD card reader for the PC | for flashing |

## 2. Windows software

| Tool | Source | Notes |
|---|---|---|
| Git for Windows | git-scm.com | includes Git Bash, which the FPGA script uses |
| **Quartus Prime Lite 25.1std** | intel.com FPGA download center (free, no license) | select **Cyclone V device support** during install. ~25 GB disk. Scripts assume `C:\altera_lite\25.1std` — set `QUARTUS_ROOT` if elsewhere. Includes Platform Designer (qsys) tools. |
| WSL2 + Ubuntu 22.04/24.04 | `wsl --install -d Ubuntu` (admin PowerShell, then reboot) | hosts the Linux/Buildroot side |

Questa/ModelSim is NOT needed — simulation uses Icarus Verilog inside WSL
(next section). Python 3 on Windows is optional (only used by maintenance
scripts).

## 3. WSL one-time setup

```bash
# Build dependencies (Buildroot + kernel + host tools)
# One command installs every build dependency (Buildroot + SD imaging + HPS):
bash /path/to/odo-miner-cyclonev/scripts/install-deps.sh

# (equivalent manual list, if you prefer:)
sudo apt update && sudo apt install -y \
  build-essential libncurses-dev flex bison libssl-dev \
  git wget curl bc cpio unzip rsync file python3 \
  dosfstools mtools e2fsprogs util-linux u-boot-tools

# Buildroot — MUST live on the Linux filesystem (~), not /mnt/c
# (kernel builds fail on case-insensitive NTFS)
cd ~
wget https://buildroot.org/downloads/buildroot-2025.11.3.tar.gz
tar xzf buildroot-2025.11.3.tar.gz

# Icarus Verilog for the RTL testbench — via the OSS CAD Suite
# (no sudo needed, self-contained; ~2 GB extracted)
# Pick the latest linux-x64 release from
#   https://github.com/YosysHQ/oss-cad-suite-build/releases
wget -O oss-cad.tgz https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-06-09/oss-cad-suite-linux-x64-20260609.tgz
tar xzf oss-cad.tgz && rm oss-cad.tgz
~/oss-cad-suite/bin/iverilog -V | head -1   # sanity check
# hdl/tb/run_tb_pipe.sh finds ~/oss-cad-suite/bin automatically
```

## 4. Get the source

```bash
# From Git Bash (Windows) or WSL — a plain clone is enough:
# the OdoCrypt reference (crypto/) and the per-epoch RTL generator (odo_gen)
# are vendored in-tree under third_party/odo-miner/ — no submodule to init.
git clone https://github.com/<your-github-user>/odo-miner-cyclonev.git
cd odo-miner-cyclonev   # clone lands on the default 'main' branch (what to build)
```

## 5. Verify the toolchain before building anything big

```bash
# In WSL, from the repo:
cd hps
make all           # builds miner + tools, zero warnings expected
make test_units    # 12 unit checks
make check         # C port vs upstream C++ — must print MATCH
cd ../hdl/tb
./run_tb_pipe.sh   # pipelined-core known-answer TB — must print "PIPE TB: PASS"
```

If all four pass, every tool is correctly installed.

## 6. Build (three commands, in order)

Commands 1 and 2 are independent and can run in parallel in separate terminals.
Command 3 requires both to have finished first.

```bash
# 1. FPGA bitstream — Git Bash on WINDOWS (~30-60 min)
#    Runs odo_gen (epoch RTL), testbench gate, qsys-generate, Quartus compile.
bash scripts/build-fpga.sh
#    -> hdl/quartus/output_files/odo_miner.rbf

# 2. Linux image — WSL (~60-90 min first time, faster on incremental)
#    Rebuilds kernel + DTB + rootfs; cross-compiles HPS daemon binaries.
BUILDROOT_DIR=~/buildroot-2025.11.3 bash scripts/build-buildroot.sh

# 3. SD card image — WSL (needs sudo for loop devices; run after 1 and 2)
BUILDROOT_DIR=~/buildroot-2025.11.3 bash scripts/build-sdcard.sh
#    -> sdcard-output/odo-miner-cyclonev-<date>.img
```

## 6b. Flash the SD card

**Option A — Rufus (Windows GUI, easiest):**
1. Download Rufus from rufus.ie
2. Insert SD card; select it in Rufus
3. Set Image option to **DD Image**
4. Browse to `sdcard-output/odo-miner-cyclonev-<date>.img`
5. Click START → write

**Option B — balenaEtcher (Windows GUI):**
Works identically; supports sparse images. Available at etcher.balena.io.

**Option C — `dd` in WSL (command line):**

The SD card reader must be passed through to WSL via `usbipd`:

```powershell
# In PowerShell (admin) — find and attach the card reader
usbipd list
usbipd bind --busid <X-Y>      # only needed once per device
usbipd attach --wsl --busid <X-Y>
```

```bash
# In WSL — confirm the device appeared, then flash
lsblk                          # find the SD card — typically /dev/sdX
# DOUBLE-CHECK: dd destroys the target device with no undo
sudo dd if=sdcard-output/odo-miner-cyclonev-*.img \
        of=/dev/sdX bs=4M status=progress conv=sparse
sync
```

After flashing, eject the card and insert it into the board's microSD slot.

## 7. Wire the display

Follow [DISPLAY_WIRING.md](DISPLAY_WIRING.md) exactly — including the
one-time **meter check of the GPIO_0 header power pins** before connecting
the module.

## 8. First boot

1. SD card in, Ethernet in, display wired, power on.
2. U-Boot loads the FPGA bitstream, enables the bridges, boots Linux
   (~30 s). The TFT shows the dashboard — including the board's **IP
   address**.
3. Browse to `http://<board-ip>` → set pool host/port/worker, optionally
   scan + join WiFi, then unplug Ethernet if going wireless.
4. Console fallback at any time: mini-USB (CH340) at **115200 8N1**,
   login `root` / `odo-miner` (change it: `passwd`).
5. Run the hardware gate checks in [TODO.md](TODO.md) §2 — smoke test,
   known-nonce check, then point at **DigiByte testnet first**
   (`ODO_TESTNET=1`, 1-day epochs prove the epoch-roll path in a day).
6. After a clean 24 h soak: set `ODOD_WATCHDOG=1` in `/etc/odod.conf`.

## 9. Rebuilding later — what triggers what

| You changed | Rebuild with | On |
|---|---|---|
| RTL / Platform Designer / pins | `scripts/build-fpga.sh` | Windows |
| Kernel config, DTS, packages, overlay | `scripts/build-buildroot.sh` | WSL |
| Miner / UI / web app C code | `make` in `hps/` or `sw/*` (the buildroot script also rebuilds them) | WSL |
| Pool, WiFi, watchdog settings | nothing — web dashboard or `/etc/odod.conf` | board |
| **OdoCrypt epoch (every 10 days)** | off-board recompile (`scripts/epoch_build_deploy.ps1`), auto-staged + applied by the board's `epoch-update.sh` cron — no manual step if `epoch_autorenew.ps1` is scheduled | Windows + board |

## 10. Troubleshooting entry points

- Build details: [BUILD_QUARTUS.md](BUILD_QUARTUS.md), [BUILD_LINUX.md](BUILD_LINUX.md)
- Board facts and headers: [BOARD_REFERENCE.md](BOARD_REFERENCE.md)
- Register interface: [register-map.md](register-map.md)
- Current status / known soft spots: [TODO.md](TODO.md)
- Deployment / SD layout: [DEPLOYMENT.md](DEPLOYMENT.md)
