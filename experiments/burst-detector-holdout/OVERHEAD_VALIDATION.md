# R4 overhead validation (run before the 88-run holdout, not after)

Status: **plan only, not yet executed.** This is Phase 7 of R4 preparation --
a smoke test that the dominant-thread-observer instrument does not
contaminate the very workloads it is measuring, before any of its 88 runs
are trusted.

## Why this is required, not optional

`docs/DOMINANT_THREAD_OBSERVER.md` (V6, 2026-08-22) already measured this
observer costing **45% of one core at 250 ms / top 5** while scanning ~516
top-app threads, and found it **"clean at one busy core, contaminating at
eight."** `steady_gameplay` and, to a lesser degree, `steady_game_title` are
exactly the many-thread regime where that finding applies. If the observer's
own CPU cost measurably changes scheduler behavior on a busy-thread workload,
any C2/C4 activation difference the holdout attributes to `module_state`
could instead (or additionally) be an artifact of the observer's own load.

This validation does **not** touch C2/C4 or workloads.csv. It only asks
whether the instrument is safe to trust, using a synthetic workload chosen
for the property that matters (thread count), not for shape similarity to
any holdout workload.

## What to measure

For each of two synthetic thread-count regimes -- **1 busy thread** (matches
V6's clean case) and **8 busy threads** (matches V6's contaminating case,
and brackets `steady_gameplay`'s likely thread count from above) -- run the
same fixed-iteration arithmetic workload (`docs/METHODOLOGY.md`'s "Benchmark
proxy": `taskset <mask> sh -c 'i=0; while [ $i -lt N ]; do i=$((i+1)); done'`,
one instance per thread, same N per thread) twice:

- **observer OFF**: the workload alone.
- **observer ON**: the workload plus `tools/dominant-thread-observer.sh`
  running at the same 250 ms / top-5 cadence R4 uses.

Record, per arm:

- **wall-clock completion time** for the fixed-iteration workload (overhead
  shows up as the workload taking longer to finish the same amount of work);
- **CPU overhead**: `/proc/stat` busy-jiffy delta attributable to the
  observer process itself (pid isolated, not the workload's);
- **dropped/degraded observer output**: count of `EVENT|...|type=no_top_app`
  lines, and windows where `wall_ms` deviates from the nominal 250 ms by
  more than the tolerance already characterized in
  `docs/DOMINANT_THREAD_OBSERVER.md` (the `nap_until` deadline-pull design
  exists precisely to bound this; a validation run that still drifts is
  itself a finding);
- **observer cadence**: actual inter-window `wall_ms`, mean and max;
- **thermal**: junction/shell start and end, same sensors as R4's own gate
  (`cpu-1-1-1`, `shell_front`).

## Pass / fail

Not a single pass/fail number -- report the two regimes separately, the same
"do not collapse to one accuracy number" discipline as the legacy detector
analysis (README, "Two separate R4 questions"). A regime is
**OVERHEAD_LIMITED** if:

- wall-clock completion time under observer ON exceeds observer OFF by more
  than the run-to-run spread of the OFF arm's own repeats (i.e. the slowdown
  is not distinguishable from noise -- same statistical discipline as
  R3, docs/R3_REAL_APP_PILOT.md), or
- `no_top_app` events or `wall_ms` drift appear under ON that do not appear
  under OFF.

## What a limited regime means for R4

**Do not use overhead-validation results to retune C2/C4 or to drop
workloads from workloads.csv.** If the 8-thread regime comes back
OVERHEAD_LIMITED, the holdout still runs on `steady_gameplay` and
`steady_game_title` as planned, but the R4 report must say so explicitly --
e.g. tag those workloads' legacy-detector rows as measured under a
known-contaminating instrument regime -- rather than presenting their
activation numbers with the same confidence as workloads in the clean
1-thread-equivalent regime. This is a limitation to disclose, not a reason
to exclude data or to declare the holdout invalid.

## Relation to the 88-run holdout

This validation is independent of, and must run before, the frozen 88-run
plan (`r4-plan.csv`). It uses its own synthetic workload and does not consume
any of the holdout's runs or repeats.
