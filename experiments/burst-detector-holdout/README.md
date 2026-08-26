# Burst-detector holdout protocol

Status: **prepared only; no new device measurements in PR #14**.

This experiment is the next validation step after the S1 real-workload feature
report. Its purpose is to test whether the two frozen detector families carried
forward from S1 generalise beyond the traces that shaped them.

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

## Analysis rules

The first holdout report should show, separately for C2 and C4:

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
