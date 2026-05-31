# HPS Build and Smoke Test

This directory contains the standalone HPS-side miner daemon and a simple FPGA register smoke test.

## Build

From the repository root:

```bash
cd hps
make
```

This builds `odod`.

To build the smoke test:

```bash
cd hps
make smoke_test
```

## Run the smoke test

The smoke test validates the HPS↔FPGA MMIO register interface using `/dev/mem`.

```bash
cd hps
sudo ./fpga_smoke_test
```

Expected output includes:

- `PASS EPOCH`
- `PASS NONCE_START`
- `PASS TARGET[...]`
- `PASS HEADER[...]`
- register values read back from the FPGA

## Notes

- The HPS daemon currently uses `hps/hps_regs.h` and expects the miner block to be mapped at `0xFF200000`.
- On the target board, the daemon requires root or a suitable UIO driver to open `/dev/mem`.
- The smoke test is useful before running the full miner daemon.
