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

- **Active daemon:** `miner_pipe.c` + `miner_io_pipe_uio.c` (UIO backend,
  `/dev/uio0`). Uses `hps/hps_regs_pipe.h` and `hps/miner_io_pipe.h`. Runs as
  `odo-miner-pipe-uio` at `/usr/bin/`. No root required; `/dev/mem` not used.
- **Legacy daemon:** `miner.c` + `miner_io.c` use `hps/hps_regs.h` and access
  the miner block at `0xFF200000` via `/dev/mem` (requires root). This targets
  the retired sequential-FSM core and is **not deployed** — kept for reference.
- The smoke test (`fpga_smoke_test`) validates the FPGA register interface using
  `/dev/mem` and is useful for bring-up before the full daemon is run.
