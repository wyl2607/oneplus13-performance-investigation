# S1 real-workload feature findings

Status: **offline descriptive evidence only; no production detector selected**.

This note records what PR #14 can now re-derive from the historical S1 observer
captures on PR #12. The raw traces remain pinned by
`s1-source-manifest.csv`; CI fetches the source branch, verifies every blob SHA
and byte size, runs the feature extractor, and uploads the resulting reports.

## Provenance and definitions

The current pinned set contains nine observer-v2 captures:

- compute: module on / off;
- scroll: module on / off;
- launch: module on;
- switch: module on;
- wake-heavy synthetic worker: module on / off;
- uclamp-attribution diagnostic: module off-style diagnostic capture.

`active_windows` in the PR #14 report means only `total_runtime_ms > 0`. This is
intentionally simple and is **not the same active-window definition** used by the
older S1 narrative tables, which applied workload-specific analysis. Do not
compare those counts as if they were identical metrics.

## Median active-window shape

| workload | busy threads p50 | equiv-core busy p50 | rank1 runtime share p50 | top4 share p50 | top4 TID churn p50 | runq/runtime p50 |
|---|---:|---:|---:|---:|---:|---:|
| compute ON | 1 | 99.40% | 100.00% | 100.00% | 0.00% | 0.000 |
| compute OFF | 1 | 98.70% | 100.00% | 100.00% | 0.00% | 0.000 |
| scroll ON | 5 | 2.26% | 51.91% | 98.81% | 66.67% | 0.060 |
| scroll OFF | 6 | 1.54% | 44.59% | 94.35% | 85.71% | 0.050 |
| launch ON | 5 | 2.70% | 67.04% | 99.66% | 75.00% | 0.040 |
| switch ON | 4 | 0.42% | 50.88% | 99.36% | 100.00% | 0.080 |
| wake ON | 1 | 40.41% | 100.00% | 100.00% | 0.00% | 0.005 |
| wake OFF | 1 | 43.32% | 100.00% | 100.00% | 0.00% | 0.004 |
| uclamp attribution | 1 | 99.38% | 100.00% | 100.00% | 0.00% | ~0.000 |

The useful result is structural: the real UI captures are not miniature versions
of the synthetic wake worker. They are usually several-thread windows with a
rotating top set and a much smaller rank1 share.

## Candidate screen

`tools/evaluate-observer-detector-candidates.py` is an in-sample screen. It uses
scroll / launch / switch as `interaction_shape`, compute / wake as
`synthetic_control`, and leaves uclamp-attribution as diagnostic. Capture names
are **not per-window latency ground truth**.

| candidate | interaction macro activation | synthetic macro activation | in-sample separation | minimum interaction activation | maximum synthetic activation |
|---|---:|---:|---:|---:|---:|
| C1_ROTATION | 48.1% | 2.2% | 45.9 pp | 31.5% | 4.3% |
| C2_ROTATION_OR_LEADER | 55.4% | 1.1% | 54.3 pp | 42.5% | 2.6% |
| C3_RUNQ_ROTATION | 45.9% | 1.1% | 44.9 pp | 35.6% | 2.6% |
| C4_INTERACTION_SHAPE | 56.7% | 0.0% | 56.7 pp | 46.8% | 0.0% |
| C5_STRICT_COMPOSITE | 35.7% | 0.0% | 35.7 pp | 23.3% | 0.0% |

C4 has the strongest numerical separation against the **committed synthetic
controls**, but that is not enough to call it the best detector. Most of those
controls are one-thread workloads, so `busy_threads >= 3` already removes a large
class of easy negatives.

## Aggregate-only game cross-check

The older S1 analysis also contains two game title-screen runs whose raw traces
were intentionally not committed because a thread name identifies the title.
Only aggregate results are available:

- median ~21 busy threads per window;
- rank1 share ~23%;
- top2 share ~39%;
- dominant-TID consecutive-window persistence ~94% with the module on and ~96%
  with it off.

Because the raw rows are unavailable, PR #14 **cannot calculate an exact C1-C5
activation rate for the game**. The aggregate evidence is still useful as a
negative-control warning: a steady multi-thread renderer can look much more like
C4's static `interaction_shape` than compute/wake do, while its dominant thread
is dramatically more stable than launch/scroll/switch.

## Detector families to carry forward

Do **not** select one production rule from S1. Carry two hypotheses into a new
holdout collection:

### Temporal-transition family — C2

```text
busy_threads >= 3
and equiv_core_busy_pct <= 75
and (top4_tid_churn_pct >= 50 or leader_changed)
```

Why keep it:

- directly encodes the leader/top-set rotation seen during UI transitions;
- rejects the committed synthetic controls almost completely;
- has an explicit temporal guard that should help distinguish a steady renderer.

Risk:

- may miss real interaction windows whose leader happens to remain stable;
- current 250 ms observer cadence is too coarse to be a production detector.

### Static-shape family — C4

```text
busy_threads >= 3
and 20 <= rank1_share_of_runtime_pct <= 85
and top4_share_of_runtime_pct >= 70
and equiv_core_busy_pct <= 75
```

Why keep it:

- best in-sample separation on the committed traces;
- captures the distributed CPU shape of launch/scroll/switch without requiring a
  previous window.

Risk:

- may false-trigger on steady multi-thread rendering or other distributed
  background work because it has no temporal-transition requirement.

## What is not established

This data does not establish that:

- either C2 or C4 identifies latency-critical windows;
- either rule can be sampled cheaply enough on-device;
- detector activation should cause `uclamp.min` or any other scheduler write;
- detector activation improves frame time, launch time, GB7, power or thermals;
- the 250 ms research observer is suitable for a production controller.

The next valid step is a **frozen-rule holdout collection** with multi-thread
negative controls and explicit interaction time markers. Thresholds must remain
frozen during that holdout; changing them turns the holdout into training data.
