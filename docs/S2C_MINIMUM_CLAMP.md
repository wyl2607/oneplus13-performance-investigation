# S2c Phase 2: minimum effective `uclamp.min` ladder

**Answer: NO LOWER CANDIDATE ESTABLISHED.** Of the five tested values
(0, 256, 384, 448, 512), placement is a **sharp step, not a gradual
dose-response** -- 0/256/384/448 all sit at ~0% prime first-run share and 512
alone reaches ~91%. This held in **every one of the 4 blocks**, so it is not
a single-run fluke or an order/thermal confound.

Status key: **MEASURED**, **DERIVED**, **NOT ESTABLISHED**.

## Design

Randomized complete block: 5 arms (uclamp.min in {0, 256, 384, 448, 512}) x
4 blocks = 20 runs, each block's arm order independently shuffled with a
fixed seed (`20260826`) so the plan is reproducible --
[`experiments/s2c/ladder-plan.csv`](../experiments/s2c/ladder-plan.csv).
Driver: [`experiments/s2c/run-ladder.sh`](../experiments/s2c/run-ladder.sh),
built on the *unmodified* `experiments/s2b/run-one.sh` from PR #15 (same
worker `wake-pair-worker.sh --mode wake`, same tracer, same 92C/95C thermal
gates, same `--uclamp-offsets` kprobe). 15 s trace window per run, matching
PR #15. All 640/768 testing explicitly out of scope this round per the task
brief (512 already saturates within the tested range -- see below).

One real bug caught before any data was trusted: the host driver's
`tail -n +2 "$PLAN" | while read ...` piped the plan through a subshell whose
loop body also ran `adb shell` -- which silently drained the rest of the pipe
after run 1, terminating the whole block early with no error. Fixed by
reading the plan from a dedicated file descriptor (`done 3< <(tail ...)`,
`read ... <&3`) so nothing inside the loop body can compete with it for
stdin. Caught immediately because the script printed "Done" after exactly
one run instead of ten.

**Positive control, before trusting any null result at 256/384/448:**
`effective_min` (kprobe reading) and `find_best_target`'s own `min_util`
argument were checked to read back the exact requested value at every arm,
not just 0 and 512:

| arm | eff_min_at_wake (avg) | eff_min_at_place (avg) | min_util (avg) |
|---|---|---|---|
| 0   | 0.0   | 0.0   | 97.9 (= natural pred_demand, no clamp) |
| 256 | 256.0 | 256.0 | 256.2 |
| 384 | 384.0 | 384.0 | 384.0 |
| 448 | 448.0 | 448.0 | 448.0 |
| 512 | 512.0 | 512.0 | 512.0 |

Every arm separates cleanly and exactly. The flat ~0% placement at 256/384/448
is a genuine measured null, not an instrument that silently failed to apply
the clamp (see [[instrument-positive-control]] in project memory -- this is
exactly the trap it warns about, checked directly this time).

## Device / consistency

Same worker, burst (1200), sleep pattern (20 ms), cpuset (`/dev/cpuset/top-app/tasks`),
uid (10999), and thermal gates as PR #15. Screen kept `Awake` for the whole
ladder (`screen_off_timeout` was already 1800000 ms, no change needed), USB
powered (not AC), 85% battery at start. `perfd_running=0` and `cfb_enable=0`
verified before every single run via `check-state.sh` (20/20 checks clean,
logged in `run-ladder.log`). Ceilings `policy0=2918400` / `policy6=3283200`
unchanged throughout (op13perf's own values, matching PR #15's baseline).
**Peak junction across all 20 runs: 56.3C** (run r09, arm 512) -- nowhere
near the 92C soft gate; no run was aborted or skipped.

## Results (run-level; statistical unit is the RUN, n=4 per arm)

| uclamp.min | first-run prime% | candidate prime% | wake p50 (us) | wake p95 (us) | pred_demand p50 | cycles/s | peak temp C |
|---|---|---|---|---|---|---|---|
| 0   | 0.00 (sd 0.00)  | 0.00 (sd 0.00)  | 88.4 (sd 5.4)  | 167.8 (sd 2.8)  | 100.6 | 28.63 (sd 0.25) | 41.2 |
| 256 | 0.09 (sd 0.19)  | 0.09 (sd 0.19)  | 64.1 (sd 0.6)  | 122.4 (sd 1.7)  | 148.5 | 35.50 (sd 0.09) | 44.5 |
| 384 | 0.00 (sd 0.00)  | 0.00 (sd 0.00)  | 64.5 (sd 1.7)  | 128.3 (sd 2.1)  | 150.5 | 37.34 (sd 0.12) | 42.6 |
| 448 | 0.22 (sd 0.43)  | 0.13 (sd 0.26)  | 61.5 (sd 6.4)  | 152.9 (sd 39.9) | 151.3 | 38.35 (sd 0.20) | 43.6 |
| 512 | **90.75** (sd 8.8) | 90.71 (sd 8.8) | 77.8 (sd 15.4) | 314.5 (sd 53.9) | 103.3 | 38.77 (sd 0.57) | 46.3 |

(Full per-run table, all 20 rows, is in the analyzer's stdout / can be
regenerated: `python3 tools/analyze-s2c-ladder.py
experiments/s2c/data-20260826/s2c-ladder-runs.csv
experiments/s2c/data-20260826/s2c-ladder-cycles.csv`.)

**Per-block detail confirms this is not one bad block:** every block (1-4)
shows the same pattern -- 0/256/384/448 all near 0% first-run prime, 512
alone in the 78-98% range (block 2's 512 run, `s2c-lad-r09`, is the low
outlier at 78.45% -- still an order of magnitude above every other arm in
every block). No block shows a lower arm creeping up toward 512's rate.

## Retention vs 512

| uclamp.min | first-run prime% | retention vs 512 |
|---|---|---|
| 0   | 0.00% | 0.0% |
| 256 | 0.09% | 0.1% |
| 384 | 0.00% | 0.0% |
| 448 | 0.22% | 0.2% |
| 512 | 90.75% | 100.0% |

There is no partial-credit arm. Retention is ~0% for every value below 512
and 100% at 512 -- this is the clearest possible way the data could have come
out for "no lower candidate."

## Why this is a step, not a ramp: what's DERIVED and what's NOT ESTABLISHED

**DERIVED (consistent with S2c Phase 1's mechanism finding):** Phase 1
(`docs/S2C_PLACEMENT_MECHANISM.md`) established that the placement effect at
512 is carried by `start_cpu`/`candidate_mask` diverging at the very first
`find_best_target` call -- a single-candidate fastpath decision, not a
gradual multi-candidate energy comparison. A fastpath that is a threshold
comparison (does `min_util` clear some fixed line, e.g. a capacity or margin
constant on the mid cluster) would naturally produce exactly this shape: flat
until the line is crossed, then a step. The data are consistent with the
threshold sitting somewhere in `(448, 512]` on this device/workload.

**NOT ESTABLISHED:** the exact threshold value, or which constant it is
(candidates include a `fits_capacity`-style margin against mid cluster
capacity, or a WALT-specific boost/margin knob) -- resolving this would need
kernel source access not available in this session, or a finer bisection
(e.g. 464/480/496) between 448 and 512, which is explicitly out of scope for
this session per the task brief's "don't chase a lower number for its own
sake" instruction. Also not established: whether the threshold is a fixed
absolute `uclamp.min` value or itself depends on other concurrent load on the
mid cluster (not varied here -- the device was otherwise idle in every run).

## Secondary observations (not part of the primary question)

- **`pred_demand` is non-monotonic across arms** (100.6 at 0, ~148-151 at
  256/384/448, back down to 103.3 at 512) even though PR #15 already showed
  `uclamp.min` does not mechanically inflate `pred_demand`. This tracks
  `wake_p50` shifting between arms (WALT's predicted demand is derived from
  each cycle's own measured execution window, so a latency shift changes the
  measured window, not because uclamp is feeding into the demand estimator
  directly). **DERIVED, not independently confirmed** -- flagged for a future
  session rather than chased here.
- **`wake_p95` roughly doubles at 512** (314.5 us vs 122-168 us elsewhere),
  with the largest run-to-run spread (sd 53.9) -- a real latency cost of
  landing on prime, consistent with PR #15's own directional (if
  not-yet-significant-at-n=4) p95 finding.
- **`cycles_per_second` rises with uclamp.min even where placement doesn't
  move** (28.6 at 0 -> 35.5 at 256 -> 37.3 at 384 -> 38.4 at 448, all while
  staying on mid) -- the clamp is still raising `min_util`/`pred_demand` used
  in frequency selection on the mid cluster even when it isn't enough to move
  placement, which speeds up the fixed-size burst per cycle. This explains
  part of the ~25% cycle-count difference PR #15 flagged (Phase 1's doc
  attributed all of it to placement; this ladder shows some of the effect
  is present even without a placement change).

## Engineering decision

**`MINIMUM_EFFECTIVE_CLAMP_CANDIDATE = 512`** (i.e. **NO LOWER CANDIDATE
ESTABLISHED** among the tested values). The task's target was "lowest clamp
achieving ~80-90% prime first-run with acceptable latency/thermal cost," not
"highest prime share." Every arm below 512 misses the target by roughly two
orders of magnitude (0.0-0.2% vs the ~80-90% target), so there is nothing to
trade off -- 512 is not just the best of the tested values, it is the *only*
one that does anything. Choosing 384 or 448 to save headroom would not be a
defensible engineering call from this data; it would place the boost
squarely below the threshold with zero benefit.

If a lower value is wanted in the future, the next step is a **bisection
between 448 and 512** (e.g. 464/480/496), not a re-run of this ladder --
this data already rules out anything strictly below 448 as a false economy.

## Files

- `experiments/s2c/ladder-plan.csv` -- the block/arm/seed plan
- `experiments/s2c/run-ladder.sh` -- host-side driver
- `experiments/s2c/data-20260826/s2c-ladder-runs.csv` -- 20 run-level rows
- `experiments/s2c/data-20260826/s2c-ladder-cycles.csv` -- 10715 cycle-level rows
- `experiments/s2c/data-20260826/s2c-lad-r*.trace.gz` -- raw traces (all 20)
- `experiments/s2c/data-20260826/run-ladder.log` -- full run log incl. every
  pre-run `check-state.sh` snapshot
- `tools/analyze-s2c-ladder.py` -- analysis script
