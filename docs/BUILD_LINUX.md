# Building Linux for Cyclone V SoC with Buildroot

## Quick Summary

This guide walks you through building a minimal embedded Linux for the HPS (Hard Processor System) on the QMTECH Cyclone V SoC (5CSXFC6C6U23). The resulting image includes:

- Linux kernel 6.6.26 LTS (multi_v7 + project fragments: SoCFPGA FPGA manager/bridges, Realtek USB WiFi)
- Bootlin external toolchain — gcc 14.3 + **glibc 2.41** (2.42 is avoided deliberately: known C library bug; the prebuilt toolchain also saves ~1h of build time)
- Essential utilities (busybox, coreutils, util-linux)
- Mining daemon dependencies (openssl, libcurl, jansson) + supervisor/python3
- Networking (Ethernet via dhcpcd, WiFi via wpa_supplicant + USB adapter drivers)
- SD card boot support (U-Boot 2023.10 SPL, `.sfp` preloader image)

**Expected output (in `output/images/`):**
- `zImage` — Linux kernel
- `socfpga_cyclone5_qmtech_odo.dtb` — device tree (QMTECH board DTS: SoCDK base + fabric SPI display/touch/keys/LEDs)
- `rootfs.ext4` — root filesystem (8 GB)
- `u-boot-with-spl.sfp` — bootloader image for the raw 0xA2 partition

**Build time:** 1–2 hours on first build (downloads + compilation)

---

## Prerequisites

### 1. Build environment (WSL2 or native Linux)

```bash
sudo apt update
sudo apt install -y build-essential libncurses-dev flex bison libssl-dev \
                    bc rsync wget cpio unzip file python3 git u-boot-tools
```

**Windows note:** Buildroot requires a POSIX environment — use WSL2 or native Linux.

**Two WSL-specific rules (builds fail without them):**

1. **Build from the Linux filesystem, not `/mnt/c`.** The kernel source has files that differ only by case; case-insensitive NTFS breaks the build. Keep the Buildroot tree in `~`.
2. **Use a clean PATH.** WSL appends the Windows PATH (entries with spaces like `Program Files`), which Buildroot rejects:
   ```bash
   export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
   ```

### 2. Download Buildroot 2025.11.x

```bash
cd ~
wget https://buildroot.org/downloads/buildroot-2025.11.3.tar.xz
tar xf buildroot-2025.11.3.tar.xz
```

### 3. Cross-compiler

None to install — the defconfig selects the prebuilt Bootlin `armv7-eabihf` stable toolchain (gcc 14.3, glibc 2.41), which Buildroot downloads automatically. After the build it lives at `output/host/bin/arm-buildroot-linux-gnueabihf-gcc` and is also what `scripts/build-buildroot.sh` uses to cross-compile the HPS miner binaries.

---

## Building Step-by-Step

### Step 1: Install the project configuration

The authoritative configuration lives in this repository — **do not maintain a separate copy by hand** (Kconfig silently drops unknown or dependency-unsatisfied symbols, which has caused hard-to-find breakage before):

- `linux/buildroot_cyclonev_defconfig` — Buildroot defconfig
- `linux/linux-wifi.fragment` — Realtek USB WiFi kernel drivers (RTL8XXXU, RTW88)
- `linux/linux-fpga.fragment` — SoCFPGA FPGA manager, bridges, simple framebuffer

```bash
BR=~/buildroot-2025.11.3
REPO=/path/to/odo-miner-cyclonev

cp $REPO/linux/buildroot_cyclonev_defconfig $BR/configs/cyclonev_defconfig
mkdir -p $BR/board/qmtech/cyclonev
cp $REPO/linux/linux-wifi.fragment $REPO/linux/linux-fpga.fragment \
   $REPO/linux/linux-display.fragment $REPO/linux/socfpga_cyclone5_qmtech_odo.dts \
   $BR/board/qmtech/cyclonev/
```

(Or just run `BUILDROOT_DIR=$BR bash scripts/build-buildroot.sh`, which does all of this plus the build and HPS cross-compile.)

### Step 2: Build

```bash
cd $BR
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
make cyclonev_defconfig
make 2>&1 | tee build.log     # do NOT pass -j to the top-level make
```

Per-package parallelism comes from `BR2_JLEVEL` in the defconfig.

### Step 3: Verify nothing was silently dropped

Kconfig drops options whose dependencies aren't met, without warning. After `make cyclonev_defconfig`, sanity-check:

```bash
grep -E 'BOOTLIN_ARMV7_EABIHF_GLIBC_STABLE|^BR2_ARM_EABIHF|PYTHON3=|SUPERVISOR=' .config
```

All four should be `=y`. For a full audit: `make savedefconfig BR2_DEFCONFIG=./check.cfg` and diff `check.cfg` against `configs/cyclonev_defconfig`.

Known dependency chains to be aware of:
- `BR2_ARM_ENABLE_VFP/NEON` must be set on Cortex-A9 (optional FPU) or EABIhf — and with it the Bootlin toolchain and python3 — silently vanish.
- `BR2_PACKAGE_SUPERVISOR` requires `BR2_PACKAGE_PYTHON3` to be set explicitly.

---

## Cross-Compiling the Miner Binaries

The rootfs has no on-target compiler (Buildroot does not support one). Build on the host with the Buildroot toolchain so the binaries link against the same glibc 2.41 the rootfs ships:

```bash
cd $REPO/hps
make clean
make CC=$BR/output/host/bin/arm-buildroot-linux-gnueabihf-gcc \
     CFLAGS="-O2 -march=armv7-a -mfpu=neon -mthumb"
```

Then copy the binaries onto the rootfs (the SD-card script does this automatically) or `scp` them to a running board.

---

## SD Card Layout (Cyclone V specific!)

The Cyclone V BootROM does **not** read filesystems — it loads the preloader from a raw partition of MBR type **0xA2**. The card must look like:

| Partition | Type | Size | Contents |
|-----------|------|------|----------|
| p1 | FAT32 (`0x0C`, bootable) | 256 MiB | `zImage`, `socfpga_cyclone5_qmtech_odo.dtb`, `boot.scr`, `fpga.rbf` |
| p2 | ext4 (`0x83`) | rest | `rootfs.ext4` contents |
| p3 | raw (`0xA2`) | 16 MiB | `u-boot-with-spl.sfp`, written with `dd` (no filesystem) |

`scripts/build-sdcard.sh` builds a complete image with this layout, injects the miner binaries, and generates the U-Boot boot script. Use it rather than hand-assembling:

```bash
BUILDROOT_DIR=$BR bash scripts/build-sdcard.sh
sudo dd if=sdcard-output/odo-miner-cyclonev-*.img of=/dev/sdX bs=4M status=progress conv=sparse && sync
```

The boot script it installs does, in order: load `fpga.rbf` into the fabric (`fpga load 0`), enable the HPS↔FPGA bridges, then load DTB + kernel and boot with `root=/dev/mmcblk0p2`.

---

## Boot Sequence

1. **Power on** → BootROM finds the 0xA2 partition and loads SPL
2. **SPL** initializes HPS clocks, pinmux, DDR3, then loads U-Boot (both from the same `.sfp` image)
3. **U-Boot** runs `boot.scr` from the FAT partition: programs the FPGA (if `fpga.rbf` present), enables bridges, loads `zImage` + DTB
4. **Kernel** boots, mounts the ext4 rootfs
5. **Linux** brings up Ethernet (dhcpcd), starts sshd and supervisor → miner daemon

---

## Loading the FPGA from Linux (alternative to U-Boot loading)

The kernel fragment enables the SoCFPGA FPGA manager:

```bash
cp odo_miner.rbf /lib/firmware/
echo 0 > /sys/class/fpga_manager/fpga0/flags
echo odo_miner.rbf > /sys/class/fpga_manager/fpga0/firmware
cat /sys/class/fpga_manager/fpga0/state    # "operating" = loaded
```

---

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| No SPL output at all on UART | No 0xA2 partition, or `.sfp` not written raw | Re-check partition table; `u-boot-with-spl.sfp` must be `dd`'d to p3, not copied to FAT |
| SPL hangs at DDR init | SoCDK DDR handoff mismatch vs QMTECH DDR3 | Regenerate handoff from the Quartus project (bsp-editor) |
| Kernel build fails with case-conflict / patch errors | Tree on `/mnt/c` (NTFS) | Move tree to `~` (WSL ext4) |
| `PATH contains spaces` error from Buildroot | Windows PATH leaked into WSL | `export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` |
| Options missing from `.config` | Kconfig silently dropped them (unmet deps) | See Step 3 verification |
| "Kernel panic: VFS unable to mount root" | rootfs partition corrupted/missing | Re-write SD image |
| FPGA registers read 0xFFFFFFFF | Bitstream not loaded or bridges disabled | Load via U-Boot/FPGA manager; `bridge enable` in U-Boot |
| Ethernet not working | PHY mismatch in DTS (SoCDK assumes Micrel; QMTECH boards typically Realtek) | Usually auto-detected via MDIO; check `dmesg | grep mdio` |
| No login prompt on UART | getty misconfigured | Defconfig sets `BR2_TARGET_GENERIC_GETTY_PORT="ttyS0"` @ 115200 — verify it survived (Step 3) |

---

## Current Configuration Summary

The defconfig at `linux/buildroot_cyclonev_defconfig` is authoritative. Highlights:

**Toolchain & kernel:**
- Bootlin external armv7-eabihf stable: gcc 14.3, **glibc 2.41** (not 2.42 — known bug), NEON hard-float
- Linux 6.6.26 LTS, `multi_v7` defconfig + two project fragments (FPGA manager + USB WiFi)
- DTB: `socfpga_cyclone5_qmtech_odo` (extends SoCDK with the SPI display/touch, keys, and LEDs; SoCDK dtb is still built as a fallback)

**Mining stack:**
- openssl, libcurl, jansson (Stratum + TLS)
- supervisor (+python3) auto-restarts the miner daemon; watchdog reboots on hang
- Cross-compile the miner on the host — no on-target compiler exists

**Display (KFB carrier):**
- Kernel side ready: ADV7511/7513 DRM bridge driver (multi_v7), framebuffer console, `CONFIG_FB_SIMPLE`
- Pending: FPGA-side video pipeline + DTS node (tracked separately; no rootfs rebuild needed)

**Rootfs:** ext4, 8 GB. Root password `odo-miner`, hostname `odo-miner`, console on ttyS0 @ 115200.

**See `docs/DEPLOYMENT.md` for post-build configuration** (NTP, watchdog, passwords, supervisor).

---

## References

- Buildroot: https://buildroot.org/
- Bootlin toolchains: https://toolchains.bootlin.com/
- QMTECH GHRD: https://github.com/ChinaQMTECH/QMTECH_CycloneV_SoC
