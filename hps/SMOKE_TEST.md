FPGA Smoke Test — build & run

Purpose
- Quick userspace utility to validate the HPS ↔ FPGA register interface before running the full miner.

Build locally (on HPS Linux or any Linux host with GCC)

1. Install a C toolchain if you don't have one:

For Debian/Ubuntu (or Buildroot host):

```bash
sudo apt update
sudo apt install -y build-essential
```

For WSL on Windows: install `build-essential` inside your WSL distro or install MSYS2/MinGW on native Windows.

2. Build the smoke test (from repo root):

```bash
cd hps
make smoke_test
```

This produces `hps/fpga_smoke_test`.

Run (on the target HPS — needs access to `/dev/mem` and typically root):

```bash
sudo ./fpga_smoke_test
```

Expected output
- The tool writes a set of known values into `REG_EPOCH`, `REG_NONCE_START`, `REG_NONCE_END`, the `TARGET` and `HEADER` arrays and reads them back.
- Example lines:

```
[smoke] mapped FPGA registers at 0xFF200000
[smoke] PASS EPOCH = 0xDEADBEEF
[smoke] PASS NONCE_START = 0x0000CAFE
[smoke] PASS TARGET[0] = 0x11110000
[smoke] PASS HEADER[0] = 0xA5A50000
[smoke] STATUS = 0x00000001
[smoke] NONCE_FOUND = 0x00000000
[smoke] HASH[0] = 0x00000000
[smoke] PERF_HASHES_LO = 0x00000000
[smoke] register validation succeeded
```

Notes & caveats
- The test requires read/write access to the LWH2F window; on the real board the daemon runs under root or via a UIO/kmod helper. Do not run this from an untrusted account.
- If you run this on a development host that does not have the FPGA mapped at `FPGA_BASE`, update `hps/hps_regs.h` accordingly or run it on the target HPS where the bridge base is correct.

CI build
- A GitHub Actions workflow is provided to compile `hps/fpga_smoke_test` on every push or via manual dispatch. This ensures the smoke-test always builds even if your local machine lacks `gcc`.

If you want, I can add an automated CI artifact upload and a small test job that runs under a QEMU user-mode environment (limited), but `/dev/mem` access can only be tested on real hardware.

Download the CI-built artifact

1. Via the Actions UI:

- Open the workflow run for `Build HPS Smoke Test` and download the `fpga_smoke_test` (Linux x86) or `fpga_smoke_test-arm` (ARM) artifact from the "Artifacts" panel.

2. Via the `gh` CLI (recommended for scripts):

```bash
# Install GitHub CLI: https://cli.github.com/
gh run list --workflow "Build HPS Smoke Test"
gh run view <run-id> --log
gh run download <run-id> --name fpga_smoke_test-arm --dir ./ci-artifacts
```

3. Notes on the ARM artifact:

- `fpga_smoke_test-arm` is cross-built for `armhf` (ARMv7 EABI) using `gcc-arm-linux-gnueabihf` and should run on Cyclone V SoC HPS Linux images that match the target ABI. If your rootfs is a different ABI (e.g., aarch64) you'll need to rebuild for that target or run in a compatible container.
