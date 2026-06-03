# Quick Start: Build Everything for Hardware

This is the fastest path from zero to a bootable SD card. Total time: **~2 hours** (mostly waiting for Buildroot).

## Prerequisites (One-Time Setup)

### On Windows: Install WSL2 (if not already done)
```powershell
wsl --install
# Reboot and set up Ubuntu 22.04
```

### In WSL2 / Linux: Install dependencies
```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git wget curl bc cpio unzip rsync file \
  parted losetup kpartx dosfstools e2fsprogs u-boot-tools \
  arm-linux-gnueabihf-gcc arm-linux-gnueabihf-g++
```

### Download Buildroot
```bash
cd ~/projects  # or your preferred location
wget https://buildroot.org/downloads/buildroot-2023.11.tar.xz
tar xf buildroot-2023.11.tar.xz
```

---

## The Fast Path (Copy-Paste)

### Step 1: Clone/navigate to the project
```bash
cd ~/odo-miner-cyclonev
# or wherever you cloned it
```

### Step 2: Build everything in one command
```bash
BUILDROOT_DIR=~/projects/buildroot-2023.11 \
PARALLEL_JOBS=8 \
bash scripts/build-all.sh
```

**That's it!** The script will:
1. ✓ Build HPS software (miner daemon, FPGA bridge)
2. ✓ Build Linux rootfs (takes 30-90 min)
3. ✓ Assemble bootable SD card image

---

## What Happens Step-by-Step

```
📦 Build HPS Software
   • Compiles odo-miner, odo-miner-watcher, fpga_smoke_test
   • Tests algorithm validation
   Time: ~2 min

📦 Build Linux with Buildroot
   • Downloads Linux kernel 5.15 LTS
   • Downloads U-Boot, GCC cross-compiler
   • Compiles everything for ARM Cortex-A9
   • Creates ext4 root filesystem
   Time: 30-90 min (downloads + compilation)

📦 Assemble SD Card Image
   • Creates 4GB bootable image file
   • Partitions: FAT32 (boot) + ext4 (root)
   • Installs U-Boot, kernel, device tree
   • Embeds FPGA bitstream (if available)
   • Adds miner binaries to rootfs
   • Creates U-Boot boot script
   Time: ~2 min

✅ Ready to write to physical SD card!
```

---

## After the Build Completes

### 1. Find your SD card image
```bash
ls -lh sdcard-output/
# You'll see: odo-miner-cyclonev-YYYYMMDD-HHMMSS.img
```

### 2. Write to physical SD card (Linux/WSL)
```bash
# Find your SD card device
lsblk | grep -i sd
# Example: /dev/sdb

# Write the image (replace sdb with your device!)
sudo dd if=sdcard-output/odo-miner-cyclonev-*.img \
         of=/dev/sdb \
         bs=4M status=progress && sync

# Or use Etcher (graphical, safer):
# https://www.balena.io/etcher/
```

### 3. Eject and test on hardware
```bash
# Eject (Linux/WSL)
sudo eject /dev/sdb

# Then:
# 1. Insert SD card into QMTECH Cyclone V board
# 2. Connect Ethernet (for mining pool)
# 3. Connect serial console (optional, for debugging)
#    • Device: /dev/ttyUSB0 (or similar)
#    • Baud: 115200
#    • 8 data, 1 stop, no parity
# 4. Power on
# 5. Wait for Linux to boot (~10-15 seconds)
# 6. Login: root / odo-miner
```

### 4. Test on the board
```bash
# Once logged in via serial console:

# Test FPGA (should not show 0xFFFFFFFF)
fpga_smoke_test

# Start mining
odo-miner pool.example.com 3333

# Or with auto-epoch reload
odo-miner-watcher pool.example.com 3333
```

---

## Customization (Optional)

### Adjust image size
```bash
# Default 4GB; customize for your SD card
IMAGE_SIZE=8192 bash scripts/build-sdcard.sh  # 8GB image
```

### Adjust parallel compilation
```bash
# Faster on multi-core (8 or 16 jobs typical)
PARALLEL_JOBS=16 bash scripts/build-all.sh
```

### Different Buildroot version
```bash
# Use latest LTS instead
BUILDROOT_DIR=~/buildroot-latest bash scripts/build-all.sh
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Buildroot directory not found" | Set `BUILDROOT_DIR` to correct path |
| Build fails with "compiler not found" | Run: `sudo apt-get install arm-linux-gnueabihf-gcc` |
| SD card write fails with permission | Use: `sudo dd ...` or try Etcher |
| Board doesn't boot | Check: power supply, SD card adapter, serial console messages |
| FPGA shows 0xFFFFFFFF | FPGA bitstream not loaded; wait for LWH2F bridge enable |
| No Ethernet on board | Check cable, try: `dhclient eth0` (once Linux boots) |

---

## Time Breakdown

| Phase | Time | Can Parallelize? |
|-------|------|------------------|
| HPS build | 2 min | No (very fast) |
| Buildroot | 30-90 min | Yes (compile in background) |
| SD card assembly | 2 min | Yes (after Buildroot) |
| **Total** | **~2 hours** | **Mostly parallelizable** |

**Pro tip:** While Buildroot compiles, you can:
- Set up Quartus/create the Qsys project
- Prepare the FPGA bitstream
- Test the board hardware

---

## Files Created

After running `build-all.sh`, you'll have:

```
hps/
  ├── odo-miner              ← Mining daemon (HPS software)
  ├── odo-miner-watcher      ← Miner with epoch auto-reload
  ├── fpga_smoke_test        ← FPGA register validation
  └── miner_io_test          ← Hardware bring-up test

buildroot-2023.11/output/images/
  ├── zImage                 ← Linux kernel
  ├── socfpga_cyclone5.dtb   ← Device tree
  ├── u-boot-spl.sfp        ← Bootloader (SPL + U-Boot)
  └── rootfs.ext4           ← Root filesystem (includes miner binaries)

sdcard-output/
  └── odo-miner-cyclonev-YYYYMMDD-HHMMSS.img  ← Complete SD card image
```

---

## What's Included on the SD Card

- **Boot partition (FAT32):**
  - U-Boot bootloader
  - Linux kernel (zImage)
  - Device tree (socfpga_cyclone5.dtb)
  - FPGA bitstream (fpga.rbf, if available)
  - U-Boot boot script (boot.scr)

- **Root filesystem (ext4):**
  - Linux (from Buildroot)
  - SSH server
  - Networking tools
  - Your compiled miner binaries at `/usr/bin/odo-*`
  - Build tools (optional)

---

## Next Steps (After Hardware Testing)

1. **Validate hardware gates:**
   - Gate 1: Register access (fpga_smoke_test)
   - Gate 2: FSM control (start/stop)
   - Gate 3: Known-nonce hash verification
   - Gate 4: Hashrate measurement
   - Gate 5: Stratum pool integration
   - Gate 6: 24-hour autonomous soak test

2. **Optimize:**
   - Fine-tune `ODOMIN_*` environment variables
   - Monitor power consumption
   - Profile CPU usage vs hashrate

3. **Deploy:**
   - Cable-tie the board
   - Arrange cooling if needed
   - Point at a real pool
   - Monitor from remote management (SSH)

---

## Getting Help

- **Build issues?** Check docs/BUILD_*.md
- **Hardware issues?** See BRINGUP.md (hardware validation sequence)
- **Code issues?** See CODE_REVIEW.md
- **Upstream context?** Check upstream/odo-miner (reference)

---

**Ready? Run:**
```bash
BUILDROOT_DIR=~/projects/buildroot-2023.11 bash scripts/build-all.sh
```

🚀
