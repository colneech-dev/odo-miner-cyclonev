# Plan: shorten the miner critical path by capping control-strobe fanout

Branch `perf/critical-path-fanout`. Opened 2026-09-18.

## Why

Measured, not assumed. `report_timing` against the shipping build
(epoch 1789344000, SEED=2) puts these at the top of the miner clock domain:

| slack (ns) | from | to |
|---|---|---|
| 0.156 | `odo_encrypt:crypt\|progress[1]` | `odo_encrypt_loop:crypter\|state[0][351]` |
| 0.167 | `odo_encrypt:crypt\|progress[1]` | `...\|state[0][338]` |
| 0.334 | `odo_sbox_small3:sbox4inst\|out[0]` | `...\|state[9][217]_OTERM5865~DUPLICATE` |
| 0.372 | `odo_encrypt_loop:crypter\|out[543]` | `...\|state[0][536]` |
| 0.372 | `odo_encrypt:crypt\|progress[1]` | `...\|state[0][305]` |

**Three of the six worst paths launch from one control register**, not from the
cipher datapath and not from the S-boxes. `progress[1]` is the enable into the
encrypt loop:

```verilog
odo_encrypt_loop crypter(clk, state[1], progress[1], out, write);
```

one register gating the load of a 640-bit state array. The fitter agrees — its
Non-Global High Fan-Out Signals table lists a whole family of these:

| signal | fanout |
|---|---|
| `...rst_controller\|...int_chain_out` | 2738 |
| `pipelined_miner_top:odo_0\|miner_rst_s2` | 902 |
| `pipelined_miner_top:odo_0\|settle_cnt[1]~14` | 864 |
| `odo_encrypt_loop:crypter\|progress[173]` | 811 |
| `odo_encrypt:crypt\|progress[1]` | **646** |

And the paths are **routing-dominated**, which is the reason to expect fanout to
be the lever: interconnect is 55–82% of the delay on the worst paths, with a
single net contributing 4.645 ns of a 5.637 ns path.

This mirrors what the AM01 project found independently on Kintex-7: their
critical path was `commit_pulse_h`, a control strobe, and S-box duplication
"works and loses". They won +0.090 ns from `max_fanout` and +0.438 ns from
over-constraining.

## Baseline — measure against exactly this

Shipping build, epoch 1789344000, SEED=2, deployed and mining:

```
Fmax (Slow 1100mV 100C)  160.15 MHz
setup slack              +0.156 ns   @ 156.25 MHz
hold slack               +0.347 ns
ALM                      20,425 / 41,910  (49%)
M10K                     281 / 553        (51%)
```

## Method

One variable at a time, so each delta is attributable.

**Step 1 (this commit).** `MAX_FANOUT 64` on `progress[1]` only. SDC untouched,
so slack remains directly comparable to the baseline above. ~10 duplicate
registers expected; functionally free, since `progress` is a plain shift
register with a single source.

**Step 2, only if step 1 helps.** Extend to the rest of the strobe family:
`progress[173]` (811). Note `settle_cnt[1]~14` carries a synthesis-generated
`~14` suffix, so an assignment to that exact name is fragile across builds —
constrain the source register instead, or leave it. `miner_rst_s2` is reset
distribution and interacts with the reset-race fix from the 2026-07-04 review
sweep; treat it as out of scope unless the others prove the approach.

**Step 3, separate build.** Over-constrain via `set_clock_uncertainty` on the
miner clock. **Read Fmax, not slack, when comparing over-constrained builds** —
slack is measured against whatever constraint is in force, so it stops being
comparable the moment the constraint moves. Fmax does not have that problem.

## Success criterion, and what it is worth

Success is a **higher Fmax**, not merely more slack at 156.25 MHz.

Be honest about the payoff. Baseline Fmax is already 160.15 MHz, so the clock
could rise ~2.5% today without any of this. The real ceiling is power, not
timing: ~1.8 A at T=6 against a ~2.0–2.2 A regulator limit, with T=5 a measured
hard brownout. Any Fmax won here converts to hashrate only inside that ~10–20%
headroom.

The reason it is still worth measuring: **routing is ~50% of total power**
(register routing alone is 847 mW, more than the entire M10K array at 646 mW)
*and* 55–82% of critical-path delay. Cutting fanout attacks both at once. That
is the only lever found so far that could plausibly move power and speed in the
same direction.

## Risks

| Risk | Handling |
|---|---|
| Duplication changes behaviour | It cannot here — single-source shift register, all copies identical. `run_tb_pipe.sh` still gates it. |
| Fitter ignores the assignment | Check the Non-Global High Fan-Out table in the new `fit.rpt`; if `progress[1]` still reads 646, it did not take. |
| Node path goes stale on epoch regen | Path uses module/instance names (`odo_encrypt:crypt`), not epoch-numbered ones, so it survives `odo_gen`. Verify it still resolves after the next epoch build. |
| Slack improves but Fmax does not | Then it bought nothing usable — Fmax is the figure of merit. |

## Do not merge without

1. `hdl/tb/run_tb_pipe.sh` bit-exact against the oracle.
2. Fmax and setup/hold recorded against the baseline table above.
3. Confirmation from `fit.rpt` that the fanout actually dropped.
4. Not deployed across an epoch boundary — land it on a quiet day, given the
   deployment history in `CLAUDE.md`.
