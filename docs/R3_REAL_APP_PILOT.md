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

## Results (2026-08-27)

### Device

CPH2653 (CPH2653EEA / OP5D55L1), kernel `6.6.118-android15-8-g2e6b9c3812c5`.
Screen on and unlocked throughout. Battery 52-53%, USB-charging. `perfd` (the
`op13perf` mitigation daemon) was **not running** for the whole session
(isolation from a live uclamp-rewriting process, same check as prior
S2b/S2c sessions). The device's ambient tune was the residual state of the
`op13perf` "高性能档" profile (URCC inversion released, `debug_enabled=1` on
the task-overload guard) rather than stock Daily -- R3 never writes
`scaling_max_freq`/`cpu_max_freq`/any perfd parameter, but the ambient
ceiling was observed to drift from `2918400/3283200` (pre-run baseline) to
`3072000/3801600` (post-run) over the session, consistent with URCC's own
dynamic ramp responding to the screen-wake/input traffic every run
generates, not to anything R3 wrote. Full baseline:
[`data-2026-08-27/baseline.txt`](../experiments/r3-real-app/data-2026-08-27/baseline.txt).

### Design

32 runs: 4 workloads (`cold_launch`, `app_switch`, `scroll_fling`,
`steady_renderer`) x 8 runs each (4 paired repeats, balanced ABBA/BAAB),
generated by `tools/make-r3-run-plan.py` at seed `20260826`. `camera_launch`
was excluded this round per plan. Every run used the **active-set**
mechanism -- the primary (first-listed) mechanism for all four workloads in
`workloads.csv` -- so this round has **no process-vs-active-set comparison**;
that is a supplementary run, not part of this 32-run plan. App slots: `APP_A`
(cold launch target), `APP_B` (app-switch target, distinct resident app from
`APP_A`), `APP_C` (scroll/fling target), `APP_D` (steady-renderer target).
Real package names exist only in the gitignored
`experiments/r3-real-app/app-manifest.local.csv`, never committed. Fixed
plan: [`data-2026-08-27/run-plan.csv`](../experiments/r3-real-app/data-2026-08-27/run-plan.csv).

### Run integrity

32/32 runs completed `status=OK`. Zero `RUN_ABORT_THERMAL_92`, zero
`SESSION_STOP_THERMAL_95`, zero `NO_TOTALTIME_PARSED`, zero replacement runs
needed. A Phase-4 smoke test caught a real cleanup-contamination bug before
the official plan ran (see [Limitations](#limitations-and-open-questions));
the fix was verified clean (0 residual threads) on all four workloads before
the 32-run plan started, and a post-hoc residue check on all four apps'
final process state after the full session also found 0 threads at
`uclamp.min=512`. Full per-run table and per-workload/arm summary:
[`data-2026-08-27/analysis-output.txt`](../experiments/r3-real-app/data-2026-08-27/analysis-output.txt).

### Results by workload

All values are run-level means (n=4 per arm) unless noted; SD in
parentheses next to each mean where reported below.

**A -- cold_launch.** PRIMARY (`am start -W` TotalTime): control
285.0 ms (SD 32.7), 512 294.5 ms (SD 47.8), delta **+9.5 ms**. The SD on both
arms exceeds the delta several times over -- **no detectable effect**, and
the nominal "slower" direction should not be read as a real regression, just
as not distinguishable from noise at n=4. Path A: mid-cluster weighted
frequency 1,452,218 Hz -> 1,905,226 Hz (+31%), a clear DVFS floor lift. Path
B: prime first-run/residency 7.3% -> 9.4%, high variance (one 512 run hit
16.5%, the other three 6.5-7.8%), not clearly separated from control's own
4.3-11.4% spread.

**B -- app_switch.** PRIMARY: control 36.8 ms (SD 6.1), 512 36.0 ms
(SD 1.4), delta **-0.75 ms** -- negligible, within noise. A resident-app
switch is already ~35 ms; whatever it is bottlenecked on, it is not CPU
frequency in this window. Path A: mid frequency +185,025 Hz (+15%), smaller
than cold_launch's lift. Path B: prime residency roughly flat (2.7% ->
2.0%).

**C -- scroll_fling.** No `event_ms` by design (steady_negative role has
none; scroll's proxy is jank/frame-time). PRIMARY (`dumpsys gfxinfo`
framestats around the swipe window): p90 9.5 ms -> 5.0 ms, p95 9.8 ms ->
5.2 ms, p99 11.8 ms -> 10.0 ms. This is a **real, credible improvement** --
512's p90 was exactly 5.0 ms in all 4 runs (SD 0.0), against control's
5-14 ms spread (SD 4.7). Janky-frame percentage: 0.4% -> 0.2% (both already
near-zero). Path A: mid frequency +372,391 Hz (+28%). Path B: prime
residency stayed low in both arms (1.2% -> 3.2%) -- the improvement is not
explained by a placement shift.

**D -- steady_renderer (negative control).** PRIMARY (frame pacing over the
full window, no latency event): p90 11.8 ms -> 8.8 ms, p95 14.0 ms ->
9.2 ms, p99 18.2 ms -> 10.5 ms, janky-frame percentage 2.5% -> **0.0%**
(zero jank in all 4 512 runs; control had visible jank in 3 of 4). This is
also a **real, credible improvement** -- and critically, **not the
anti-pattern the negative control exists to catch**: prime residency did
not rise to explain it (3.3% -> 2.3%, actually slightly down), while mid
frequency rose the most of any workload (1,704,505 Hz -> 2,180,822 Hz,
+28%). The gain comes entirely through the DVFS floor (Path A), with no
placement cost.

### Path A (DVFS) vs Path B (placement)

Path A moved on **every** workload: mid-cluster weighted frequency rose
15-31% under the 512 clamp in all four cases, the most consistent finding
in this pilot. Path B stayed muted across the board: prime residency never
exceeded ~10% in either arm, on any workload -- a sharp contrast with the
synthetic single-thread S2C study, where `uclamp.min=512` crossed a
placement threshold and moved first-run share from ~0% to ~90%. For real,
multi-threaded interaction work, `uclamp.min=512` manifests almost entirely
as a DVFS-floor lift, not a cluster-placement change -- consistent with S1's
finding that real foreground windows are rotating-leader, multi-thread
workloads rather than the single continuous worker S2a-S2d studied.

### Thermal

Peak junction across the whole session: 75.7 °C (one `cold_launch`/512 run,
R029); every other run stayed in the 38-68 °C range. Never within 16 °C of
the 92 °C soft gate. Zero soft-gate or hard-gate triggers, zero cooldown
pauses needed.

### Mechanism comparison (process vs active-set)

**Not tested this round.** The frozen 32-run plan uses only the primary
mechanism (active-set) per `workloads.csv`, uniformly across all four
workloads -- there is no process-mechanism data in this dataset to compare
against. A supplementary `--all-mechanisms` run is future work, not part of
this pilot's verdict.

<a name="limitations-and-open-questions"></a>
### Limitations

- **n=4 paired repeats.** This is a mechanism pilot, not a production
  statistical certification (per [Scope](#scope)) -- no significance testing
  was run; means/SDs and raw per-run values are reported so the reader can
  judge each delta against its own noise, and cold_launch's own delta is
  explicitly flagged as not distinguishable from zero.
- **Active-set only.** No process-mechanism comparison this round (see
  above).
- **Ambient tune state, not stock Daily.** The device's ceiling/URCC state
  drifted during the session (see [Device](#device)) as an observed
  side-effect of normal screen-wake/input traffic, not of anything R3
  wrote. Absolute `event_ms`/frequency numbers are specific to this tune
  state, battery level and date -- not necessarily representative of a
  stock Daily-profile device.
- **A real contamination bug was found and fixed during Phase 4 smoke
  testing.** The active-set mechanism's cleanup originally reset only the
  tids in its own final tracked snapshot; a smoke test found dozens of
  *other* threads still at `uclamp.min=512` after cleanup ran -- not
  present on a plain (non-R3) launch checked immediately after launch, so
  not an OS/app self-boost. The exact kernel mechanism was not confirmed
  with tracing; a plausible cause is kernel-side boost propagation (e.g.
  binder/sync priority inheritance) reaching threads the active-set loop
  never explicitly tracked. Fixed defensively by making cleanup
  unconditionally sweep every thread in the target process's task group on
  any 512 run, verified clean before the official plan started and
  spot-checked clean after it finished. **This remains an open mechanism
  question**: a future controller that assumes it clamps exactly the
  threads it names may in practice be affecting more.
- **`steady_renderer`'s app was substituted mid-session.** The first
  candidate (a video player) was rejected after discovering its
  `SurfaceView`-based video decode bypasses `dumpsys gfxinfo`'s frame
  counter entirely (6-7 UI-chrome frames counted over 7 s of continuous
  playback) -- it would have silently produced a fake "no signal" negative
  control. Replaced with a Canvas/HWUI-driven continuous meter display
  (confirmed ~58 fps via `gfxinfo` before trusting it). **Any future
  steady-render workload must render through the normal View/Canvas/HWUI
  pipeline, not a bare `SurfaceView`/codec surface**, or `gfxinfo`-based
  metrics will read as a false negative.
- **Single session, single device, single day.** No repeated-day or
  repeated-device replication.

### Verdict

**`MIXED_BY_WORKLOAD`.** The two launch/transition workloads with an
explicit `TotalTime` event (`cold_launch`, `app_switch`) showed no
detectable benefit despite a clear DVFS floor lift on both. The two
continuous-rendering workloads (`scroll_fling`, and the `steady_renderer`
negative control) showed a real, credible frame-pacing improvement,
delivered through the DVFS floor rather than cluster placement -- and the
negative control did *not* show the anti-pattern it was built to catch
(prime residency did not rise to produce the gain).

Is `uclamp.min=512` credible for a **bounded** real-app boost? **Yes, for
continuous-rendering / frame-paced work** (scroll, steady render) -- the
gain is real, delivered efficiently via the DVFS floor, and not accompanied
by wasted prime-cluster placement. **Not for launch/transition-latency
work** (cold launch, app switch) on this device/session -- the same DVFS
floor lift produced no `TotalTime` benefit, meaning launch latency here is
bottlenecked by something `uclamp.min` does not touch (I/O, first-frame
compositing, cold-start warm-up costs).

Which workloads should **never** trigger a future controller, on this
evidence: `cold_launch` and `app_switch` -- boosting them spends the DVFS
floor lift for no measured `TotalTime` benefit. This is a *wasted-frequency*
anti-pattern distinct from the *wasted-placement* anti-pattern the design
doc anticipated (prime residency barely moved for these two workloads
either, so it is not prime-cluster waste specifically -- it is that the
frequency lift itself bought nothing measurable in this window).

### Remaining unknowns

The exact kernel mechanism behind the untracked-thread boost propagation
found during smoke testing (not confirmed with tracing); whether the
launch/transition null replicates on a different day/thermal/battery/tune
state; whether the process mechanism would show a different pattern for
launch workloads than active-set did; all of the above is a single-device,
single-session result.

### Cleanup

`DEVICE_CLEAN` confirmed post-session: 0 threads at `uclamp.min=512` across
all four target apps, no lingering R3 processes/samplers/tracers, on-device
`/data/local/tmp/op13-r3` working directory removed, `perfd` still not
running, CFB `debug_enabled=1` unchanged, no shipped profile
(Daily/Performance/Extreme) touched by R3 at any point.

### Next step

Per [After R3](#after-r3), a `MIXED_BY_WORKLOAD` verdict means R4 (the
frozen C2/C4 holdout) is in scope next -- but as a separate, reviewed task,
not a continuation of this one.
