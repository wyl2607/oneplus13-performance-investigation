# S2d: threshold bisection and DVFS/placement separation

**This is the last synthetic-mechanism round in this line of investigation.**
S2a-c established that `uclamp.min` moves scheduler placement through a
step-function threshold somewhere in `(448, 512]`, and that part of the
cycle-rate gain PR #15 originally attributed to prime placement happens even
when the thread never leaves the mid cluster. S2d (1) bisects that interval
and (2) gets **direct, measured** frequency evidence for the DVFS
explanation instead of the indirect "consistent with" reasoning S2c relied
on. Next stage is the real-app pilot, not S2e/S2f.

Status key: **MEASURED**, **DERIVED**, **NOT ESTABLISHED**.

## Design

Randomized complete block: 7 arms (uclamp.min in
`{0, 448, 464, 480, 496, 504, 512}`) x 4 blocks = 28 runs, fixed seed
`20260826`, each block's order independently shuffled off the same seeded
RNG stream (`experiments/s2d/gen-threshold-plan.py` ->
[`threshold-plan.csv`](../experiments/s2d/threshold-plan.csv)). `0` is kept
as the DVFS/frequency baseline; `448`/`512` are S2c's own established
inactive/active endpoints; `464/480/496/504` bisect between them.

Driver: [`experiments/s2d/run-threshold-ladder.sh`](../experiments/s2d/run-threshold-ladder.sh),
calling [`experiments/s2d/run-one.sh`](../experiments/s2d/run-one.sh) --
a copy of PR #15's `run-one.sh` with two additions, both opt-in/backward
compatible:

- `stats/time_in_state` for `policy0` (mid) and `policy6` (prime) is
  snapshotted immediately before and after the trace window. Zero tracing
  overhead (two sysfs reads per cluster); diffed by
  [`tools/s2d-tis-delta.py`](../tools/s2d-tis-delta.py).
- `--trace-freq` passes a new `--freq` flag through to
  `tools/scheduler-event-tracer.sh`, which adds `power:cpu_frequency`
  (systemwide, no pid field, cannot be kernel-filtered) to the same trace.
  Off by default, so every existing S2b/S2c invocation is byte-identical.

Same worker (`wake-pair-worker.sh --mode wake`), burst (1200), sleep
(20 ms), cpuset, uid 10999, `--uclamp-offsets 1560,848,856,4` kprobe, 15 s
trace window, and 92C/95C thermal gates as PR #15/#16.
[`tools/s2c-trace-to-csv.py`](../tools/s2c-trace-to-csv.py) is reused
unmodified for cycle parsing; [`tools/analyze-s2d.py`](../tools/analyze-s2d.py)
is the new analyzer (per-arm summaries + threshold search + DVFS split),
structurally parallel to `analyze-s2c-ladder.py` but not touching it.

## Phase 1: frequency telemetry capability

Full survey: [`experiments/s2d/data-20260826/capability/CAPABILITY.md`](../experiments/s2d/data-20260826/capability/CAPABILITY.md).
Summary: `power:cpu_frequency` tracepoint, `time_in_state` cpufreq stats, and
WALT's `waltgov_next_freq`/`sched_freq_uncap`/`ipc_freq` are all present on
this kernel. `time_in_state` was chosen as the **primary, zero-overhead**
per-run residency metric; `power:cpu_frequency` as a **secondary, opt-in**
trace-level metric after an explicit overhead check
([`experiments/s2d/data-20260826/overhead-ab/overhead-ab.md`](../experiments/s2d/data-20260826/overhead-ab/overhead-ab.md)):
4 runs at uclamp.min=512 (ABBA, noFreq/withFreq/withFreq/noFreq) gave
**identical mean cycle counts (581.0 vs 581.0, 0.0% difference)** and zero
overrun/dropped/commit_overrun in every run despite `cpu_frequency` adding
~4200-4650 extra entries per 15 s run. **MEASURED: no detectable
perturbation from `--trace-freq`.**

## Device / consistency

`perfd_running=0` and `cfb_enable=0` verified before every run
(`check-state.sh`, logged in `run-threshold-ladder.log`). Ceilings
unchanged throughout. **Peak junction across all 28 runs: 57.1C** (run 28,
arm 0, the last run of the last block after the least inter-run cooldown) --
nowhere near the 92C soft gate; no run was aborted or skipped. All 28 traces
loss=none (verified individually, not just spot-checked).

## Results (run-level; statistical unit is the RUN, n=4 per arm)

| uclamp.min | first-run prime% | cycles/s | mid weighted freq (kHz) | prime weighted freq (kHz) | wake p50 (us) | wake p95 (us) | peak temp C |
|---|---|---|---|---|---|---|---|
| 0   | 0.00 (sd 0.00) | 28.90 (sd 0.30) | 946,206  | 1,034,631 | 79.50 | 182.99 | 44.5 |
| 448 | 0.00 (sd 0.00) | 38.08 (sd 0.16) | 1,708,817 | 1,033,528 | 61.75 | 138.49 | 44.7 |
| 464 | 0.17 (sd 0.35) | 38.25 (sd 0.24) | 1,781,096 | 1,040,489 | 62.00 | 139.77 | 42.7 |
| 480 | 0.00 (sd 0.00) | 38.15 (sd 0.14) | 1,721,102 | 1,019,451 | 65.00 | 140.50 | 41.7 |
| 496 | 0.00 (sd 0.00) | 38.37 (sd 0.13) | 1,745,982 | 1,027,122 | 64.50 | 137.85 | 39.7 |
| 504 | 0.00 (sd 0.00) | 38.33 (sd 0.09) | 1,745,905 | 1,022,063 | 63.75 | 136.00 | 40.7 |
| 512 | **89.35** (sd 6.56) | 38.72 (sd 0.20) | 938,678 | 1,538,541 | 75.12 | 331.40 | 45.3 |

Full per-run and per-arm tables:
[`experiments/s2d/data-20260826/s2d-analysis.txt`](../experiments/s2d/data-20260826/s2d-analysis.txt).
"Weighted freq" is the `time_in_state`-jiffies-weighted mean frequency over
each run's trace window, per cluster -- MEASURED, not derived.

**464's single non-zero block (0.69% first-run prime, 4/579 cycles in one
of four blocks) is noise, not a partial dose-response**: the other three
464 blocks are exactly 0%, matching S2c's own positive-controlled "step,
not ramp" finding. Treated as a genuine null, same trap S2c already
flagged in [[instrument-positive-control]].

## Primary analysis 1: threshold interval

```
highest reliably inactive (<20% first_run_prime): 504
lowest reliably active (>=80% first_run_prime):   512
THRESHOLD INTERVAL: 504 < T <= 512
```

This halves S2c's `(448, 512]` interval to 8 clamp units without finding a
lower usable candidate -- **512 remains the only tested value that produces
the target ~80-90% first-run prime share.** No engineering recommendation
changes: `MINIMUM_EFFECTIVE_CLAMP_CANDIDATE` is still 512.

## Primary analysis 2: DVFS vs placement, now MEASURED not DERIVED

Comparing arm 0 to arm 448 (both firmly below the placement threshold, both
0.00% prime):

- `cycles_per_second`: 28.90 -> 38.08 (+31.8%)
- `mid_weighted_freq`: 946,206 kHz -> 1,708,817 kHz (**+81%**), MEASURED
  directly from `time_in_state` deltas, not inferred from cycle counts.

This directly confirms the hypothesis `docs/S2C_PLACEMENT_MECHANISM.md` was
corrected to state (Phase 0.5 of this task): raising `uclamp.min` raises the
mid-cluster frequency floor well before it's large enough to move placement.
**DVFS-below-threshold status is now MEASURED, not a leading hypothesis.**

Taking the full 0->512 span as 100%:

```
uclamp.min=  0: cycles/s=28.90  pct_of_span=  0.0%
uclamp.min=448: cycles/s=38.08  pct_of_span= 93.5%
uclamp.min=464: cycles/s=38.25  pct_of_span= 95.2%
uclamp.min=480: cycles/s=38.15  pct_of_span= 94.2%
uclamp.min=496: cycles/s=38.37  pct_of_span= 96.4%
uclamp.min=504: cycles/s=38.33  pct_of_span= 96.1%
uclamp.min=512: cycles/s=38.72  pct_of_span=100.0%
```

**93.5-96.4% of the total cycle-rate gain is already present below the
placement threshold.** Crossing the threshold to reach prime (504 -> 512)
adds only about 3.6-6.5 more percentage points of the span -- roughly
**1-2% additional cycles/s** on top of the ~38.1-38.4 already reached by
DVFS alone. This reproduces S2c's derived estimate almost exactly (S2c:
"most of the ~25% cycle-count difference... some of the effect is present
even without a placement change") but now from a direct measurement instead
of a cycles/run inference.

**Consistency check on the arm-512 frequencies themselves:** at 512,
`mid_weighted_freq` drops back to ~939 kHz (the thread is no longer resident
on mid at all) and `prime_weighted_freq` rises to ~1,538,541 kHz. Prime
capacity is 1024 vs mid ~792 (per project memory); a `min_util`=512 target
translates to roughly `512/1024 * 3283200 (ceiling) ~= 1,641,600 kHz` on
prime -- the measured 1,538,541 kHz is close to that back-of-envelope
figure, a useful sanity check that the frequency floor is doing what the
placement math implies, though the exact capacity-to-frequency mapping is
NOT independently re-derived here.

## What's MEASURED / DERIVED / NOT ESTABLISHED

- **MEASURED:** mid-cluster frequency residency rises sharply (0->448:
  +81%) while placement stays at 0%. Threshold interval narrowed to
  `(504, 512]`. `wake_p95` roughly doubles at 512 (331 vs 136-183 us
  elsewhere) -- reproduces S2c's latency-cost finding independently.
- **DERIVED:** the DVFS effect is what shortens the fixed-length burst and
  produces more completed cycles per fixed trace window (frequency and
  cycle-rate move together across every arm below threshold; causality
  runs frequency -> faster burst -> more cycles, consistent with the fixed
  burst-size design, not independently proven by an intervention on
  frequency alone).
- **NOT ESTABLISHED:** the exact kernel constant the placement fastpath
  compares `min_util` against (same open question as S2c -- this session
  did not get kernel source access). Whether the threshold moves under
  concurrent mid-cluster load (Phase 3, see below). Whether the DVFS
  mechanism generalizes past this fixed synthetic burst shape to real
  variable-length work.

## Optional Phase 3 (load sensitivity): SKIPPED

Conditions nominally allowed it (threshold narrowed to 8 clamp units,
thermal stable throughout, telemetry clean on every run). A synthetic
mid-cluster background-load generator
(`experiments/s2d/bg-mid-load.sh`, a `taskset`-pinned busy/sleep duty-cycle
script) was written to test it, but hit real problems during its own smoke
test: this device's toybox `taskset` takes a hex affinity mask, not a
`-c cpulist` (the first version used the wrong flag), and even after fixing
that, `pgrep -f <marker>` self-matched its own invocation's argv,
momentarily making cleanup look inconclusive. No experiment data was ever
collected under this generator, and no thermal or measurement problem
resulted (peak junction returned to the 42-44C baseline immediately). Per
this task's own instruction ("if no time or conditions are unstable, SKIP,
don't force it"), Phase 3 was not run this session. The broken load
generator was deleted rather than left half-working in the repo -- a
future session should build and independently validate one (e.g. against
`/proc/stat` per-cpu deltas) before trusting it for a real measurement.

## Files

- `experiments/s2d/gen-threshold-plan.py`, `threshold-plan.csv` -- plan and generator
- `experiments/s2d/run-one.sh` -- per-run driver (time_in_state + `--trace-freq`)
- `experiments/s2d/run-threshold-ladder.sh` -- host-side orchestrator
- `experiments/s2d/data-20260826/capability/` -- Phase 1 capability survey
- `experiments/s2d/data-20260826/overhead-ab/` -- `--trace-freq` overhead A/B
- `experiments/s2d/data-20260826/s2d-threshold-runs.csv` -- 28 run-level rows
- `experiments/s2d/data-20260826/s2d-threshold-cycles.csv` -- cycle-level rows (via `tools/s2c-trace-to-csv.py`)
- `experiments/s2d/data-20260826/s2d-threshold-tis.csv` -- time_in_state deltas per run/cluster
- `experiments/s2d/data-20260826/s2d-thr-r*.trace.gz` -- raw traces (all 28)
- `experiments/s2d/data-20260826/s2d-analysis.txt` -- full analyzer output
- `tools/analyze-s2d.py`, `tools/s2d-tis-delta.py` -- analysis scripts
- `tools/scheduler-event-tracer.sh` -- extended with opt-in `--freq` (this session)

## Recommendation for the real-app pilot

Use **`uclamp.min=512`** as the boost value carried into the real-app pilot
-- unchanged from S2c, now with a narrower confirmed threshold `(504, 512]`
and direct frequency evidence that most of its benefit on short bursts
comes from the DVFS floor rather than the placement change itself. This
means a real-app pilot should expect **most of the throughput win even on
work that never gets promoted to prime** (e.g. background/short bursts),
with the placement crossing adding a comparatively small further gain at
the cost of roughly doubled wake p95 latency.
