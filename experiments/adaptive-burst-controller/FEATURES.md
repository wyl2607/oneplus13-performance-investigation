# Real-workload feature layer

The controller deliberately consumes a `burst_signal` instead of hard-coding a
synthetic-thread rule. This file defines the offline feature layer used to study
what such a detector could safely observe.

`tools/extract-observer-features.py` reads the dominant-thread-observer v2 format
used by S1 and emits one row per observer window. Historical S1 captures are
pinned by `s1-source-manifest.csv`; `tools/build-observer-manifest-report.py`
fetches the exact git source blobs in CI, verifies blob SHA and byte size, and
builds a reproducible workload report.

## Window features

The extractor currently emits:

- `busy_threads` — observer count of threads with non-zero runtime;
- `equiv_core_busy_pct` — total runtime / wall time, expressed as one-core
  equivalent utilisation;
- `runq_wait_per_runtime` — aggregate runqueue wait divided by aggregate runtime;
- `rank1_runtime_pct_wall` — dominant thread runtime as a share of window wall
  time;
- `rank1_share_of_runtime_pct` — dominant thread share of all measured runtime;
- `top2_share_of_runtime_pct` / `top4_share_of_runtime_pct` — concentration of
  runtime in the busiest threads;
- `captured_runtime_hhi` — Herfindahl-style concentration over the captured top
  threads;
- `leader_changed` — whether rank 1 changed TID from the previous window;
- `top4_tid_churn_pct` — Jaccard churn of the top-four active TIDs;
- `rank1_slices_per_ms` — scheduler-slice density for the dominant thread;
- `rank1_runq_wait_per_runtime` — dominant-thread wait/runtime ratio;
- `rank1_started_prime` / `rank1_ended_prime` — only the sampled window endpoint
  CPUs from the observer record.

The last two CPU flags are **not prime residency**. S1 samples only CPU start/end
for the interval, so the extractor does not promote those endpoints into a claim
about where the thread spent the window. Event-level prime residency belongs to
S2a/S2b traces.

## Current S1 result

The committed real interaction captures are structurally different from the
synthetic one-thread workers:

- scroll / launch / switch are usually several-thread windows;
- the leading thread commonly owns only about half of delivered runtime;
- the top-thread set rotates heavily across consecutive windows;
- compute / wake are dominated by one stable thread.

The exact descriptive numbers and detector-candidate screen are recorded in
`S1_REAL_WORKLOAD_FINDINGS.md`.

## Detector candidates remain hypotheses

`tools/evaluate-observer-detector-candidates.py` screens several fixed rules on
the pinned S1 traces and always reports `IN_SAMPLE_EXPLORATORY`. It does **not**
return a production winner.

Two families are carried forward:

- C2 `ROTATION_OR_LEADER`: temporal transition shape;
- C4 `INTERACTION_SHAPE`: static multi-thread interaction shape.

C4 is the strongest separator against the committed compute/wake controls, but
C2 has a temporal rotation guard that is more plausible against a steady
multi-thread renderer. The existing game title-screen raw rows were withheld for
privacy, so neither candidate can be fully validated against that workload from
PR #14 alone.

## Next validation

The frozen-rule protocol is in `../burst-detector-holdout/README.md`.
`tools/make-burst-detector-holdout-plan.py` creates paired module-on/module-off
collection order with balanced state order and deterministic workload
randomisation.

The holdout must add multi-thread steady/background negative controls and
explicit interaction event markers. If a threshold changes after seeing holdout
results, the revised candidate requires another unseen validation set.

## What this layer still does not do

There is intentionally no production rule in `perfd.sh`, no device scheduler
write, and no claim that detector activation should cause `uclamp.min` or any
other boost. S2b must first establish the causal scheduler action, and a cheaper
production signal source must replace the 250 ms shell observer.
