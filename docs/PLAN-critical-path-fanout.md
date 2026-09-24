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

## RESULT — step 1 measured 2026-09-18

Same epoch (1789344000), same SEED=2, SDC untouched. Only `MAX_FANOUT 64` on
`progress[1]` changed, so the delta is attributable.

| | baseline | MAX_FANOUT 64 | delta |
|---|---|---|---|
| **Fmax (Slow 1100mV 100C)** | 160.15 MHz | **164.31 MHz** | **+4.16 MHz** |
| **setup slack @ 156.25 MHz** | +0.156 ns | **+0.314 ns** | **+0.158 ns** |
| hold slack | +0.347 ns | +0.341 ns | −0.006 ns |
| ALM | 20,425 (49%) | 21,011 (50%) | +586 |

**Mechanism confirmed, not just the outcome:** `progress[1]` no longer appears
in the fitter's Non-Global High Fan-Out Signals table at all (was 646 loads), so
the duplication happened and each copy now drives ≤64. The +586 ALM is larger
than the ~10 registers predicted, because Quartus duplicated the driver's logic
cone rather than only the flop — immaterial against ~21k spare.

Slightly better than AM01's +0.090 ns from the same technique.

### Step 2 is now refuted — do not do it

The critical path moved off the strobe entirely:

```
0.314  odo_sbox_small33:sbox49inst|out[2]   -> odo_encrypt_loop|state[4][556]
0.315  odo_encrypt_loop:crypter|out[380]    -> odo_encrypt_loop|state[0][258]
0.434  keccak_hasher:hash|state[0][469]     -> keccak_buffer:buffer|stateout[758]
0.460  odo_sbox_small14:sbox21inst|out[1]   -> odo_encrypt_loop|state[8][622]
```

`progress[1]` is gone from the worst-path list; the limiter is now S-box→state
datapath, i.e. the cipher itself. The remaining high-fanout strobes
(`miner_rst_s2` 903, `settle_cnt[1]~14` 864, `progress[173]` 813) are **not on
the critical path**, so constraining them should be expected to buy nothing.
Recorded as a negative result so nobody spends builds rediscovering it. This is
also where AM01 arrived: once the strobe is fixed, what is left is the cipher,
and their S-box duplication "works and loses".

### What the win is actually worth

Fmax 164.31 MHz against a 156.25 MHz constraint is 5.2% of timing headroom.
Converting it needs a PLL ratio change, and the honest arithmetic is tight:

| target | PLL (50 MHz ×M/N) | slack vs Fmax 164.31 | verdict |
|---|---|---|---|
| 160.00 MHz | 16/5 | +0.164 ns | clears the 0.1 ns bar |
| 162.50 MHz | 13/4 | +0.068 ns | **below our own MinMarginNs gate** |
| 164.29 MHz | 23/7 | ~0 | no margin at all |

So the realistic step is **160 MHz, ~+2.4% (≈26.6 MH/s)** — not the full 5.2%.
And it must be treated as a separate controlled experiment, because raising the
clock raises power on a board whose ceiling is power: ~+2.4% frequency on ~1.8 A
against a ~2.0–2.2 A limit is comfortable, but it is a different variable and
should not be folded into this one.

## RESULT — 160 MHz FAILED, and the reasoning behind it was wrong

Built 2026-09-19: PLL 25/8 → 16/5, fanout fix retained, same epoch, SEED=2.

| build | constraint | Fmax | setup | verdict |
|---|---|---|---|---|
| A deployed | 156.25 MHz | 160.15 MHz | +0.156 ns | shipping |
| B fanout | 156.25 MHz | 164.31 MHz | +0.314 ns | good |
| **C clock** | **160.00 MHz** | **158.96 MHz** | **−0.041 ns** | **FAILS** |

Negative slack, and **Fmax fell** from 164.31 to 158.96 when the constraint rose.

### The mistake, stated plainly

The prediction table above ("160.00 MHz → +0.164 ns") treated Fmax as a fixed
property of the netlist — a budget of speed that could be spent. It is not. The
fitter solves whatever constraint it is handed; at 156.25 MHz with slack to
spare it happened to land a placement good for 164.31 MHz, and asked for 160 MHz
it explored a different, harder problem and landed on one worth only 158.96.

Reading Fmax off a loose build to justify a tighter constraint is invalid. The
only way to know whether a clock closes is to build at that clock.

AM01 documented the same anti-correlation before this build was started
(`880f660`, "212.5 MHz: slower, more slack, far worse. Slack is
anti-correlated") — the evidence was available and was not applied.

### What survives

Build B is unaffected and stands on its own merit. It is **not** a hashrate
change; it is a robustness change:

- setup margin doubles, +0.156 → +0.314 ns, for +586 ALM and no RTL edit
- this project has had epochs land at **+0.022 ns** and **−0.211 ns**, forcing
  seed retries, and an epoch boundary was missed while that played out

Double the baseline margin means future epochs are materially more likely to
close on the first seed. That is worth shipping even at identical MH/s.

### If 160 MHz is revisited

SEED=2 is a single sample and seeds move Fmax by more than the ~1.2 MHz shortfall
here — `epoch_build_deploy.ps1` already automates that sweep. It was not run
because the prize is +2.4% and **power, not timing, is this board's binding
constraint**: ~1.8 A against a ~2.0–2.2 A limit, with T=5 a measured brownout.
Spending hours of compile to chase 2.4% into a power wall is poor value while
the fanout win is already banked.

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
