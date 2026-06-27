# Pipelined OdoCrypt miner (Phase 1)

Avalon-MM integration of the upstream pipelined `odo_encrypt` (~37.5 MH/s on our
`5CSXFC6C6`, see `docs/pipelined-miner-scope.md` / `docs/pipelined-phase1-plan.md`).

## Files

| File | Source | Notes |
|------|--------|-------|
| `pipelined_miner_top.v` | ours | Avalon-MM slave + 55↔150 MHz CDC + free-running core. Contract in `hps/hps_regs_pipe.h`. |
| `odo_miner_core.v` | upstream `miner.v`, trimmed | `cmp_256` + `odo_keccak` + `miner` only (JTAG `miner_top` + CRC `pad_nonce` removed). |
| `keccak800.v` | upstream | Pipelined Keccak-800 (THROUGHPUT param). NOT our `hdl/src/keccak/keccak800.v`. |
| `odo_<seed>.v` | **generated** | Per-epoch pipeline (`module odo_encrypt`). Gitignored — regenerate. |

## Regenerate the per-epoch RTL

The epoch is baked into `odo_<seed>.v` (`seed = ntime - ntime % 864000`):

```sh
cd third_party/odo-miner/src/verilog && make odo_gen
./odo_gen <seed> 4 "odo_" > ../../../../hdl/src/pipelined/odo_<seed>.v
```

`4` is THROUGHPUT (one hash / 4 cycles). Define `THROUGHPUT` and `ODOKEY=<seed>`
as Verilog macros for the build (qsf `VERILOG_MACRO`, or `-D` for iverilog).

## Elaborate / lint

```sh
iverilog -g2005 -s pipelined_miner_top -DTHROUGHPUT=4 -DODOKEY=<seed> \
  -o /dev/null pipelined_miner_top.v odo_miner_core.v keccak800.v odo_<seed>.v
```
