# Burst-detector holdout protocol

Status: **prepared only; no new device measurements in PR #14**. Protocol
corrected (not re-tuned) after R3 -- see "R3 correction" below -- before this
holdout is executed.

This experiment is the next validation step after the S1 real-workload feature
report. Its purpose is to test whether the two frozen detector families carried
forward from S1 generalise beyond the traces that shaped them.

## R3 correction: `role` is a detector-shape label, not a utility label

R3 (docs/R3_REAL_APP_PILOT.md, PR #20) measured real controller response on a
small set of real-app workloads and found `steady_renderer` -- the same
semantic class as this plan's `steady_negative` role -- **improved** under
`uclamp.min=512` (p95 frame time 14.0ms -> 9.2ms, jank 2.5% -> 0.0%), without
a placement shift. Meanwhile `cold_launch` and `app_switch`
(`interaction_transition` role) showed **no detected benefit**.

So this holdout's `role` column (`interaction_transition` /
`steady_negative` / `background_negative` / `synthetic_control`) describes
**what shape of thread activity a workload has**, for the purpose of judging
whether C2/C4 correctly identify that shape. It must **not** be read as, and
this doc previously risked being read as, a claim about whether triggering
the module is *useful* on that workload. `interaction_transition` != useful,
`steady_negative`/`background_negative` != useless. Those are two different
questions -- see "Two separate R4 questions" below.

**R3's workload set does not exactly match this plan's `workloads.csv`.** R3
ran `cold_launch`, `app_switch`, `scroll_fling`, `steady_renderer`,
`camera_launch` on 4 real apps (docs/R3_REAL_APP_PILOT.md); this plan lists
11 differently-scoped workloads (e.g. `app_launch_cold`/`app_launch_warm`
split, `browser_scroll` vs. R3's `scroll_fling`, `steady_game_title` vs.
R3's generic `steady_renderer`). Any utility evidence carried over from R3
below is by **inferred shape similarity, not identical instrumentation** --
treat it as the weakest form of prior evidence, not a measured result for
this plan's specific workloads.

## Frozen candidates

The first holdout must evaluate these expressions **without changing their
thresholds during collection or analysis**.

### C2 — temporal transition

```text
busy_threads >= 3
and equiv_core_busy_pct <= 75
and (top4_tid_churn_pct >= 50 or leader_changed)
```

### C4 — static interaction shape

```text
busy_threads >= 3
and 20 <= rank1_share_of_runtime_pct <= 85
and top4_share_of_runtime_pct >= 70
and equiv_core_busy_pct <= 75
```

If either expression is changed after looking at holdout results, the changed
rule is a **new candidate** and needs another unseen holdout before any production
claim.

## Why a holdout is required

The current S1 screen is in-sample:

- scroll / launch / switch were used to understand real interaction shape;
- compute / wake were used as easy synthetic controls;
- the only known multi-thread steady-renderer control exists only as aggregate
  game statistics because its raw trace was withheld for privacy.

A 0% trigger rate on compute/wake therefore does not establish a low production
false-positive rate.

## Workload roles

`workloads.csv` defines the intended collection set. It deliberately includes:

- interaction transitions: cold/warm launch, switch, scroll/fling, camera launch;
- steady multi-thread negatives: game/title rendering and gameplay when
  available;
- media/background negatives: video playback, download/sync;
- synthetic mechanism controls: uninterrupted compute and wake-heavy worker.

The goal is not to make the positive set huge. It is to include the important
negative regimes that the S1 committed raw traces do not cover.

## Pairing and order

For each repeat of each workload, collect both module states:

- `module_off` — stock level / no op13perf lift;
- `module_on` — the existing measured module state used by S1.

Use paired order, alternating `OFF -> ON` and `ON -> OFF` by repeat. Randomise the
order of workload pairs within each repeat. `tools/make-burst-detector-holdout-plan.py`
creates this schedule deterministically from a seed.

This is not an efficacy A/B test of the module. The paired states are present to
measure whether the **feature distribution / detector activation itself** is
stable when scheduler state changes.

The default plan uses four repeats. With the 11 workloads currently listed that
produces 88 runs: 11 workloads x 2 module states x 4 repeats.

## Required capture fields

Keep the observer-v2 raw trace plus a sidecar run manifest containing at least:

```text
run_id
workload_id
role
module_state
repeat
start_wall_time
start_junction_c
end_junction_c
screen_on
foreground_package_hash
notes
```

Do not put package names or identifying thread names into committed public data.
Use stable hashes or redacted labels where needed.

For interaction workloads, also record explicit event markers with monotonic
clock timestamps:

```text
EVENT|event_id=<id>|phase=start|t_ms=<monotonic-ms>
EVENT|event_id=<id>|phase=end|t_ms=<monotonic-ms>
```

The marker stream is required if later analysis wants per-window latency labels.
Without it, capture-level workload names remain only weak labels.

## Two separate R4 questions

The holdout report must answer two **different** questions and must not
collapse them into one.

### A. Legacy detector analysis

Can the frozen C2/C4 expressions (unchanged, see "Frozen candidates" above)
distinguish the originally-defined interaction-transition workload shape
from non-interaction regimes? This is the direct continuation of S1/PR #14
and uses the `role` column as originally intended: a shape label.

- activation percentage by workload and module state;
- activation percentage inside vs outside explicitly marked interaction events;
- module-on minus module-off activation delta for each workload;
- negative-control activation for each steady/background workload;
- number of active windows and event count;
- distribution of the same underlying features used by each candidate.

Do **not** collapse the result to one accuracy number. Different false-positive
regimes matter differently: a detector that is quiet on compute but constantly
fires during steady gameplay is not acceptable merely because the aggregate
number looks good.

### B. Controller-utility analysis

Would triggering `uclamp.min=512` on this workload/window appear useful,
wasteful, or unknown, based on measured response -- **independent of**
whether C2/C4 fire on it. Use three labels:

- `BENEFIT_POSITIVE` -- real paired evidence of improvement (e.g. reduced
  jank/p95, faster completion) exists for this workload or a
  shape-equivalent one.
- `BENEFIT_NEGATIVE` -- real paired evidence of no detected benefit or a
  cost exists.
- `UNKNOWN` -- no measured evidence yet. **Default for anything not
  explicitly measured.** Do not infer a label from workload name or `role`.

Carried over from R3 (shape-similarity inference, not this plan's own
workloads -- see caveat above), phrased conservatively:

| this plan's workload (closest R3 shape) | R3 evidence | utility label |
|---|---|---|
| `browser_scroll` (~`scroll_fling`) | p95 9.8ms -> 5.2ms, jank 0.4%->0.2% | `BENEFIT_POSITIVE` |
| `steady_game_title` / `steady_gameplay` (~`steady_renderer`) | p95 14.0ms -> 9.2ms, jank 2.5%->0.0%, no placement shift | `BENEFIT_POSITIVE` |
| `app_launch_cold`/`app_launch_warm` (~`cold_launch`) | +9.5ms delta, SD 33-48ms -- not distinguishable from noise (n=4 pairs) | `BENEFIT_NEGATIVE` (no detected benefit; stated conservatively, small n) |
| `app_switch` (exact match) | -0.75ms delta, negligible | `BENEFIT_NEGATIVE` (no detected benefit) |
| `camera_launch` | excluded from R3's executed 32 runs | `UNKNOWN` |
| `steady_gameplay`, `video_playback`, `background_download`, `synthetic_compute`, `synthetic_wake` | never measured with a real controller response | `UNKNOWN` -- do not invent a label |

`steady_gameplay` appears in both rows above only because it is *shape*-similar
to `steady_renderer` for the A-side detector question; for the B-side utility
question it stays `UNKNOWN` until it is itself measured -- shape similarity is
not evidence of response for a workload that hasn't been run.

### Utility matrix (fill in after collection, not before)

| workload | C2 activation | C4 activation | known 512 response | utility interpretation |
|---|---|---|---|---|
| *(one row per workload_id in workloads.csv, filled from A + B above)* | | | | |

## Frozen means frozen

**Do not retune C2/C4 thresholds using R3 or using this holdout's own
results.** If a rule is changed after looking at holdout data, the changed
rule is a new candidate and needs its own unseen validation set -- this
holdout's 88 runs are then spent and cannot be reused to validate it.

## Final R4 verdict must answer

1. C2 activation by workload
2. C4 activation by workload
3. event vs non-event discrimination
4. steady-rendering behavior
5. gameplay/video/download behavior
6. false-positive regimes
7. detector overhead
8. whether either frozen detector is credible
9. whether neither detector survives holdout
10. whether controller utility aligns with interaction classification
11. whether rendering pressure appears more important than transition semantics
12. `DEVICE_CLEAN`
13. commit SHA
14. PR URL

Allowed verdicts: `C2_SURVIVES`, `C4_SURVIVES`, `BOTH_SURVIVE`,
`NEITHER_SURVIVES`, `INCONCLUSIVE`. Do not force a winner.

## No production gate yet

This protocol intentionally does not define an arbitrary PASS threshold. The
first holdout is for generalisation evidence and failure-mode discovery. A
production gate should be written only after:

1. holdout distributions are visible;
2. a practical low-overhead signal source is identified;
3. S2b establishes what scheduler action, if any, is causally justified;
4. a second unseen validation set is possible if thresholds are revised.

## Relation to controller timing

The S1 observer runs at roughly 250 ms and is a research instrument. A short
interactive burst can begin and end inside one observer interval, and the shell
observer is too expensive for production use.

Therefore this holdout validates **feature meaning**, not final control latency.
A later production detector will need a cheaper event source or a substantially
lighter sampling path before it can drive the adaptive controller.
