# R3 — real-app uclamp mechanism pilot

S1–S2d answered questions about a synthetic wake worker: `uclamp.min=512` crosses
WALT's placement threshold and lands 89–91 % of first-runs on the prime cluster
([S2C_MINIMUM_CLAMP.md](S2C_MINIMUM_CLAMP.md)), and below that threshold the same
lever still moves the DVFS floor even when placement does not change
([S2D_THRESHOLD_DVFS.md](S2D_THRESHOLD_DVFS.md)). None of that is a claim about a
real app. R3 is the first time `uclamp.min=512` is applied to real foreground
interaction work instead of a controlled single-thread worker.

**Question:** does `uclamp.min=512` improve real foreground interaction work, and
does it do so without unacceptable latency / thermal / steady-load cost? Not yet
established. This document is the pilot design; it does not assume a positive
result, and per the project's cardinal rule ([DATA.md](DATA.md)), the verdict
below is written after the runs, not before them.

This is a **mechanism pilot**, not the C2/C4 detector holdout. It does not build,
enable or ship any controller. See [Scope](#scope) and [What R3 does not do](#what-r3-does-not-do).

## Why real apps are a different measurement

S1 already established that real foreground windows (launch, switch, scroll) are
3–4 thread workloads with a rotating leader thread, not the single continuous
worker S2a–S2d studied
([DOMINANT_THREAD_OBSERVER.md](DOMINANT_THREAD_OBSERVER.md)). Two things follow:

1. There is no single "the" thread to clamp. R3 tests two mechanism levels
   (below) instead of assuming one.
2. `uclamp.min=512` may move placement (Path B), the DVFS floor (Path A), both,
   or neither, depending on what demand the real workload's threads actually
   generate. The synthetic threshold crossover does not transfer by assumption.

## Mechanism levels

| level | what gets clamped | how |
|---|---|---|
| **process** | every thread in the foreground app's task group, for the run's duration | `uclampset -m 512 -a -p <pid>` applied to the main pid; `uclamp_fork()` copies the clamp onto every worker the pool spawns, same primitive as `mitigation/experimental/performance.sh` |
| **active-set** | only the threads currently in `/dev/cpuset/top-app/cgroup.procs` with runtime since the last scan, re-ranked every 250 ms | reuses `tools/dominant-thread-observer.sh`'s top-app enumeration; clamp is applied to the top-K active threads each tick and **not** reapplied to threads that drop out of the active set |

Both levels are tested per workload where feasible. The pilot records, per run:
how many threads received the clamp, their anonymized rank/role (`leader`,
`rank2`, …, not a thread name), and how long the clamp stayed applied
(`clamp_ticks / total_ticks`). No fixed package whitelist is used; every app is
resolved from the manifest at run time (see [App privacy](#app-privacy)).

## Workloads

| id | class | mechanism(s) tested | event window |
|---|---|---|---|
| A | cold app launch | process, active-set | `am start -W` TotalTime |
| B | app switch | process, active-set | `am start -W` TotalTime (second app already resident) |
| C | scroll / fling | active-set (process optional) | `dumpsys gfxinfo framestats` window around a fixed `input swipe` sequence |
| D | steady renderer (negative control) | process, active-set | no latency event — throughput/pacing over the whole run |
| E | camera launch (optional) | process, active-set | `am start -W` TotalTime, only if instrumentation stays clean |

D is not a smaller version of A–C. It exists to answer a different question:
does `uclamp.min=512` push a workload that never needed the prime cluster onto
it anyway, for no measured benefit. See
[Steady negative control](#steady-negative-control).

## Experiment arms

- **A (control):** `uclamp.min` unchanged — stock behaviour, no clamp applied by
  this pilot.
- **B (512):** foreground-target `uclamp.min=512`, applied only for the run's
  duration by the mechanism level under test.

No 640, no 768, no frequency ceiling changes, no Daily/Performance/Extreme
parameter changes, no perfd changes. `experiments/r3-real-app/` is a standalone
measurement harness; it does not import or modify anything under
`mitigation/`.

## App privacy

Real package names and any recognizable app/game name are never committed.
Every script and doc refers to `APP_A` / `APP_B` / `APP_C` / `APP_D`. The mapping from
those tokens to real packages lives only in
`experiments/r3-real-app/app-manifest.local.csv`, which is listed in
`.gitignore` and was never committed — not even once, since a later removal
does not remove it from git history (`docs/PRIVACY.md` has the history
rewrite this project already had to do once over a package name; the intent
here is to not repeat it). Raw per-package traces may be kept locally.
Anything committed — run logs, CSVs, this doc — is sanitized to `APP_A/B/C`
before it is staged.

## Pilot design

Per workload: control/512 paired runs, **≥4 paired repeats**, i.e. 8 runs per
workload. 4 workloads = 32 runs; +8 if camera (E) is included = 40 runs.

Order is balanced and alternating (ABBA / BAAB across repeats), generated by
`tools/make-r3-run-plan.py` — the same alternating-state approach as
`tools/make-burst-detector-holdout-plan.py`, with `arm` (`control`/`512`) in
place of `module_state`.

**Statistical unit is the RUN.** Not the frame, not the wake, not the
scheduler event — same convention as S2c/S2d (`analyze-s2d.py`).

## Event markers

Cold launch, switch and camera launch have an explicit event window recorded
by the runner as

```
EVENT|event_id=<run_id>|phase=start|t_ms=<ms>
EVENT|event_id=<run_id>|phase=end|t_ms=<ms>
```

sourced from `am start -W`'s own `TotalTime`/`WaitTime` fields (the standard,
already-instrumented Android cold-start metric — no app-side hook required).

Scroll records the `input swipe` gesture's issue time and a `framestats` reset
immediately before and a dump immediately after, so the interval is the fling
window, not the whole run.

Steady renderer has no latency event. It is reported only as steady-state
context: throughput / frame-pacing stability over the full window. Fabricating
a latency label for it would misrepresent a workload that has none.

## Measurements

Recorded per run (schema: `experiments/r3-real-app/run-schema.md`):

- `run_id, workload_class, arm, mechanism, repeat, block, app_slot`
- `initial_junction, peak_junction, end_junction` (milli-C, `cpu-1-1-1`)
- `uclamp_requested, uclamp_effective_readback`
- `foreground_thread_count, clamped_thread_count, clamp_ticks, total_ticks`
- CPU placement: `prime_first_run_share`, `prime_residency_pct` (from
  `/proc/stat` deltas restricted to prime CPUs, same method as
  `experiments/real-workloads/common.sh`), and — on the single dominant thread
  identified by the active-set ranking, for a sampled subset of runs, not
  every run, to keep tracer overhead off the critical path —
  `start_cpu`/`candidate_mask` evidence via `tools/scheduler-event-tracer.sh`
  (reused unmodified from S2a/S2d)
- DVFS: `policy0`/`policy6` `time_in_state` deltas via
  `tools/s2d-tis-delta.py` (reused unmodified), weighted frequency
- Latency proxy: `event_total_time_ms` (launch/switch/camera),
  `jank_frame_count` / `frame_time_p95_ms` from `framestats` (scroll, steady)
- Thermal: `soft_gate_hits` (≥92 °C, run aborted), `session_stop` (≥95 °C,
  whole session halted) — thresholds and two-tier behaviour identical to
  `experiments/s2d/run-one.sh` (`RUN_ABORT_THERMAL_92` /
  `SESSION_STOP_THERMAL_95`)
- `power_proxy` if the kernel exposes one cleanly with negligible observer
  overhead (opportunistic; `status=UNAVAILABLE` otherwise, not fabricated)

## Two effects, not one

`uclamp.min=512` can act on a real thread through:

- **Path A — DVFS floor.** Raises the minimum requested frequency regardless
  of whether placement changes (S2D_THRESHOLD_DVFS.md).
- **Path B — placement threshold.** Crosses WALT's admission threshold and
  changes which cluster the thread runs on at all (S2C_PLACEMENT_MECHANISM.md).

A real app's threads may get only A, only B, both, or neither — this is a
property of the demand each thread actually generates, which the synthetic
worker does not determine. Every workload's report separates the two: DVFS
`time_in_state` deltas are read whether or not `prime_first_run_share` moved.

## Success / failure interpretation

`prime_first_run_share` moving is not the outcome measure. The outcome measure
is whether the run-level interaction proxy (launch/switch `TotalTime`, scroll
jank/frame-time, steady pacing) improves, and at what thermal/DVFS cost.
Prime share up with latency unchanged and p95 wake latency worse is not a
product win. Prime share only mildly moved with launch completion 8 % faster
may still have engineering value. Both readings are reported explicitly rather
than collapsed into a single number.

## Steady negative control

Workload D exists specifically to catch the failure mode a future controller
must avoid: pushing steady rendering onto the prime cluster permanently for no
throughput gain. Reported explicitly: performance delta, frequency delta,
prime-residency delta, thermal delta. A large power/frequency increase on D
without a matching performance gain is a documented anti-goal for any future
bounded-burst controller, not a pass/fail gate on R3 itself.

## Thermal

Two-tier gate, identical values and semantics to S2d: **soft gate 92 °C**
(this run is aborted, session continues) and **hard/session-stop 95 °C**
(whole pilot session halts). Real interaction workloads are expected to stay
well under both. Android's own thermal framework is never disabled or
bypassed — this gate sits in front of it, purely as an experiment abort, and
is strictly more conservative than the framework's own trip points
([THERMALS.md](THERMALS.md)).

## Scope

<a name="what-r3-does-not-do"></a>
R3 answers one question: does `uclamp.min=512` have causal value for real
interaction workloads, under which mechanism level, at what cost. It does
**not**:

- wire C2/C4 into `perfd`
- run as a background daemon
- boot-time adaptive boost
- implement a production detector
- modify any shipped profile (Daily / Performance / Extreme)

## Output

- `experiments/r3-real-app/` — harness (`common.sh`, `run-one.sh`,
  `workloads.csv`, `run-schema.md`, `app-manifest.example.csv`)
- `tools/make-r3-run-plan.py` — balanced ABBA/BAAB run order generator
- `tools/analyze-r3-real-app.py` — per-run and per-workload/arm summary,
  reusing `tools/s2d-tis-delta.py` output unmodified
- this document

## After R3

If the verdict is `REAL_APP_SIGNAL_FOUND` or `MIXED_BY_WORKLOAD`: next is R4,
the frozen C2/C4 holdout. If `NO_REAL_APP_BENEFIT_DETECTED`: the next step is
re-checking target selection, event-window duration and real-workload
mechanism — not building a controller on a signal that was not there.
