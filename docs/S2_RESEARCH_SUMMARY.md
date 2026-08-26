# S1-S2d scheduler research: summary

This is the integration point for the S1-S2d line of investigation into
`oplus_bsp_task_overload`, `uclamp.min`, and scheduler placement on the
OnePlus 13. It links the individual stage docs rather than repeating them;
read those for MEASURED/DERIVED/NOT ESTABLISHED detail and raw data.

## S1: real UI thread structure / observer limits

Read-only dominant-thread observer scaffolding on real (non-synthetic) app
workloads (compute/scroll/launch/switch/wake), pinned in
`experiments/adaptive-burst-controller/s1-source-manifest.csv`. Showed real
foreground work is often several-thread with a rotating leader, unlike the
synthetic wake-heavy pair used for mechanism testing -- and that the 250 ms
shell observer is too high-latency/overhead for a production controller.
Docs: `docs/DOMINANT_THREAD_OBSERVER.md`,
`experiments/adaptive-burst-controller/S1_REAL_WORKLOAD_FINDINGS.md`.

## S2a: placement is made at wake selection

Event-level scheduler tracer (`tools/scheduler-event-tracer.sh`) showed the
placement decision happens at `select_task_rq`/`find_best_target`, not
somewhere later -- the mechanism question is about wake-time CPU selection,
not post-hoc migration. Docs: `docs/SCHEDULER_EVENT_TRACER.md`.

## S2b: uclamp is a causal placement lever; pred_demand identity is FALSE

16-run balanced block A/B (`uclamp.min` 0 vs 512) on a reproducible
wake-pair worker: **PLACEMENT_EFFECT**, first-run prime share 0% -> 89.9%
(95% CI [86.4, 93.5]), reproduced on the integration tree byte-for-byte via
`tools/analyze-s2b.py`. Critically, `pred_demand` stayed ~100-120 in both
arms and moved in the wrong direction under the clamp -- **falsifying** the
hypothesis that `uclamp.min` acts by inflating WALT's demand estimate. The
real mechanism is in the placement-stage capacity/candidate check, not
demand inflation. `tools/simulate-burst-policy.py` (built on the false
identity, from the independent `#14` offline-lab line) is retained only as
a `HISTORICAL_COUNTERFACTUAL` / negative-control artifact. Doc:
`docs/S2B_DEVICE_RESULTS.md`.

## S2c: misfit ruled out; min_util feed-through; hard threshold in (448, 512]

Re-parsed S2b's own 16 traces with a wider field set (no new device
collection): the explicit `misfit` flag only moves 0% -> 2.24pp, far too
small to carry the ~90pp effect, and is ruled out directly (within arm B,
the `misfit==0` subgroup is *still* ~92% prime). `start_cpu`/`candidate_mask`
diverge the full ~90pp at the very first `find_best_target` call. A 20-run
ladder (`uclamp.min` in {0,256,384,448,512}, 4 blocks) then showed placement
is a **sharp step, not a dose-response curve** -- 0/256/384/448 all ~0%,
512 alone ~91%, consistent across every block -- narrowing the threshold to
`(448, 512]`. Docs: `docs/S2C_PLACEMENT_MECHANISM.md`, `docs/S2C_MINIMUM_CLAMP.md`.

## S2d: threshold narrowed to (504, 512]; DVFS effect now MEASURED

28-run block design (7 arms x 4 blocks: {0,448,464,480,496,504,512}) bisects
the threshold to **`(504, 512]`** -- 512 remains the only value reaching the
~80-90% target. New capability this stage: `time_in_state` cluster-level
frequency residency (zero overhead) and an opt-in `--freq` flag on the
tracer for `power:cpu_frequency` (validated with an overhead A/B showing
0.0% perturbation). Result: mid-cluster frequency residency rises 81%
(946->1709 kHz) between `uclamp.min`=0 and 448 while placement stays at 0% --
**directly measuring**, not just deriving, that 93.5-96.4% of the total
cycles/s gain across the full 0->512 span happens via a DVFS/frequency-floor
effect *below* the placement threshold. Doc: `docs/S2D_THRESHOLD_DVFS.md`.

## What changed across the four stages, in one table

| stage | question | answer |
|---|---|---|
| S2a | where is placement decided? | at wake-time `find_best_target`, not later |
| S2b | does `uclamp.min` cause placement, and how? | yes, causally; NOT via `pred_demand` inflation |
| S2c | which field carries it, and what's the threshold? | `start_cpu`/`candidate_mask`, step at `(448,512]` |
| S2d | how tight is the threshold, and is there a DVFS effect? | `(504,512]`; yes, MEASURED, ~94-96% of gain below threshold |

## NEXT

This is the last synthetic-mechanism round in this line -- no S2e/S2f. The
next stage moves to real applications:

- **Real-app mechanism pilot** -- replay the S2b/S2c/S2d mechanism findings
  against a real foreground workload instead of the synthetic wake-pair
  worker, using the recommended `uclamp.min=512`.
- **C2/C4 holdout** -- the 88-run frozen-rule holdout for the two detector
  hypotheses (`experiments/burst-detector-holdout/`), explicitly not run
  during S2b-S2d per the task's own scoping.
- **Adaptive burst controller prototype** -- only once a validated detector
  and the real-app pilot exist, per
  `experiments/adaptive-burst-controller/README.md`'s own sequencing.
