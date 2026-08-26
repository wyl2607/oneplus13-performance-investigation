# S2b device validation: does `uclamp.min` causally alter WALT placement?

**Answer: yes, but not by the mechanism the S1/S2a descriptive model implied.**
`uclamp.min=512` moves a wake-heavy thread from 0% prime first-run share to
~90%, with `effective_min` (read at the scheduling instant, not just requested)
cleanly separated between arms. But the WALT `pred_demand` signal did **not**
rise to meet the 512 mark — it stayed at ~100-120 in both arms, far below the
S2a demand curve's ~519 crossover for 50% prime share. The effect runs through
the **misfit/capacity check** in CPU selection (`start_cpu`, `candidate_mask`),
not through inflating WALT's own predicted-demand estimate. The naive identity
`uclamp.min=512 == WALT pred_demand=512` that this experiment set out to test
is **false** on this device.

Status key: **MEASURED** (read directly from a kprobe/tracepoint),
**DERIVED** (computed from measured values), **HYPOTHESIS** (plausible,
not established here), **NOT ESTABLISHED**.

## Device / kernel / ROM baseline (MEASURED, 2026-08-26 ~18:20-18:35 UTC)

| | |
|---|---|
| Model | CPH2653 |
| Fingerprint | `OnePlus/CPH2653EEA/OP5D55L1:16/BP2A.250605.015/V.R4T3.52da06f-2e397f6-2e81775:user/release-keys` |
| Kernel | `6.6.118-android15-8-g2e6b9c3812c5-ab15114928-4k` aarch64 |
| Root | `su -c id` -> `uid=0(root) context=u:r:magisk:s0` |
| tracefs | `/sys/kernel/tracing`, group `readtracefs`, present and writable |
| trace_clock | forced `global` by `scheduler-event-tracer.sh`; verified per-run (script aborts otherwise) |
| op13perf module | `v1.2.0` installed, `module.prop` last set to "高性能档" but **no `perfd` process was running** during the experiment (`ps -A \| grep perfd` empty) — confirmed isolated from the mitigation daemon |
| cpufreq_bouncing | `enable=0` throughout |
| policy0/policy6 ceiling | `2918400` / `3283200` (op13perf's own ceiling, unchanged before/after) |
| Screen / charging | screen on, USB-powered (not AC), battery 85%, 35.9°C |
| Junction zone | resolved **by name** `cpu-1-1-1` (index reassigns across reboots per `docs/THERMALS.md` trap 3) |
| Junction at start | 41.7-44.8°C across runs |

## Branches / PRs (as fetched, `git fetch origin --prune`)

| PR | branch | head SHA |
|---|---|---|
| #12 | `feature/dominant-thread-observer` | `643b25b68a694ab372c0e7a756cff6eacd41f716` |
| #13 | `feature/scheduler-event-tracer` | `525515750eeb8a7c889d73cccc2e9b7060cef35c` |
| #14 | `feature/offline-performance-lab` | `514fc1077fe6844dbffdd33a89c0e1246a851897` |
| — | `main` | `1107d7808c5605d82b3350666a09449a222086f1` |

`experiment/s2b-device-validation` was branched from PR #13's head (it needs
the tracer). `tools/analyze-s2b.py` was copied (not merged) from PR #14's head
— it is a pure offline analyzer with no device dependency, and already
implements exactly the run-level, block-aware CSV schema and mechanism-gate
verdict this protocol calls for. No PR was merged. No production file
(`mitigation/op13perf/perfd.sh`, any Daily/Performance/Extreme tune value) was
touched.

## What was actually run

**Phase 0 (baseline/safety):** device/root/tracefs checks above, thermal zone
resolved by name, `tools/btf-offsets.py` re-derived the `uclamp_eff_value`
kprobe offsets fresh from this device's own `/sys/kernel/btf/vmlinux`
(`pid=1560 uclamp_req=848 uclamp=856 se_size=4`) rather than reusing offsets
from another kernel build.

**Pipeline build (new code, this session):**
- [`experiments/s2b/run-one.sh`](../experiments/s2b/run-one.sh) — on-device
  orchestrator: starts `wake-pair-worker.sh --mode wake` (PR #13), applies
  `uclampset -m <arm> -p <tid>`, runs `scheduler-event-tracer.sh` with the
  `--uclamp-offsets` kprobe, and gates on a background 4 Hz junction-temperature
  watchdog (kills the run at >=92°C, kills the whole session at >=95°C).
- [`tools/s2b-trace-to-csv.py`](../tools/s2b-trace-to-csv.py) — converts one
  raw trace into per-cycle CSV rows matching `tools/analyze-s2b.py`'s schema,
  decoding the packed `uclamp_se` bitfield (`value = raw & 0x7ff`) for
  `effective_min`/`requested_min` at the cycle closest to placement.
- [`experiments/s2b/run-block.sh`](../experiments/s2b/run-block.sh) — host-side
  driver for the balanced ABBA/BAAB block, calling the above over `adb`.

**One real bug caught and fixed before any data was trusted:** the first two
pilot runs passed the *traced TID* as the first field of `--uclamp-offsets`
instead of the fixed `task_struct.pid` byte offset the tracer's docstring
actually specifies (`PID,UCLAMP_REQ,UCLAMP,SE_SIZE` — "PID" there means the
offset of the `pid` *field*, not a task ID). The kprobe silently accepted the
malformed offset string and simply never fired (0 `s2a_uclamp` events across
3630 lines). Caught by comparing against PR #13's own historical
`uclamp-wake.txt.gz`, which showed the correct format and non-zero hits. This
is the "positive control" trap from prior sessions' methodology notes, applied
here: an instrument that reports nothing must be proven live before its
silence means anything. Fixed in `run-one.sh`; both pilot re-runs after the
fix showed `effective_min` decoding to exactly the requested value.

**Collection: 0 vs 512, 16 runs, 4 balanced ABBA/BAAB blocks — complete, all
OK.** 15 s trace window per run (worker ran 21 s to bracket it), ~470-590
complete wake cycles per run, **7896 total wake cycles** across 16 runs
(8 arm A + 8 arm B). No `--buffer-kb` overrun/dropped/commit_overrun events on
any run (tracer would have hard-failed with exit 5 otherwise). No run hit the
92°C soft gate or the 95°C session-stop gate; peak junction across all 16 runs
was 57.5°C.

## Results (run-level, `tools/analyze-s2b.py`, MEASURED/DERIVED)

| metric | Arm A (min=0) | Arm B (min=512) | B-A mean | 95% CI (n=4 blocks) |
|---|---|---|---|---|
| requested_min | 0.00 | 512.00 | 512.00 | [512.00, 512.00] |
| **effective_min** (kprobe, at placement) | 0.00 | 512.00 | 512.00 | [512.00, 512.00] |
| pred_demand (p50) | 115.56 | 102.00 | **-13.56** | [-18.96, -8.16] |
| start_cpu on prime (%) | 0.00 | 91.86 | 91.86 | [88.60, 95.12] |
| candidate mask includes prime (%) | 0.00 | 89.64 | 89.64 | [86.16, 93.11] |
| misfit flagged (%) | 0.00 | 2.24 | 2.24 | [1.90, 2.58] |
| selected_cpu on prime (%) | 0.00 | 89.91 | 89.91 | [86.37, 93.46] |
| **first_run_cpu on prime (%)** | 0.00 | 89.91 | 89.91 | [86.37, 93.46] |
| wake-to-run latency p50 (us) | 56.50 | 58.06 | 1.56 | [-0.23, 3.35] |
| wake-to-run latency p95 (us) | 178.33 | 213.98 | 35.65 | [-7.06, 78.36] |

## Direct answers to the mechanism checklist

1. **Does requested `uclamp.min=512` actually take effect?** Yes —
   `uclampset -p` readback was 512 on every B run (16/16).
2. **Is effective uclamp separated at enqueue/placement, not just requested?**
   Yes — the `uclamp_eff_value` kprobe, decoded independently of the
   `uclampset` readback, shows `effective_min` = 512 exactly on every B cycle
   with a CI that does not touch A's value. **Not `CLAMP_NOT_SEPARATED`.**
3. **Does `uclamp.min=512` change WALT `pred_demand`?** No — it went slightly
   *down* (102 vs 115.6, CI excludes 0 but the direction is wrong for a
   "clamp inflates demand" story). **This falsifies mechanism (A).**
4. **Does it change `candidate_mask` / `start_cpu` / `misfit`?** Yes, sharply
   — `start_cpu` moves to a prime core in 91.9% of B cycles vs 0% of A cycles,
   and 2.2% of B cycles are explicitly flagged misfit (0% in A). This is
   consistent with mechanism **(B)**: `uclamp.min` raises the capacity
   requirement compared against cluster capacity in the misfit/fits-capacity
   check inside `find_best_target`, independent of the task's own measured or
   predicted utilization. Mechanism **(C)** (candidate selection moving
   independent of any capacity signal) is not distinguishable from (B) with
   this trace set — the candidate/start_cpu shift and the misfit shift move
   together, and misfit is exactly the field that would carry (B)'s effect.
5. **Does it change prime-selected %?** Yes, 0% -> 89.9% (first-run), tight CI.
6. **Does it change prime first-run %?** Same as (5) — `selected_cpu` and
   `first_run_cpu` track each other almost exactly in both arms (no meaningful
   selected-vs-actually-ran divergence).
7. **Does it change wake-to-run latency?** p50 no (CI includes 0). p95 shows a
   35.6 us mean increase but the CI still includes 0 at n=4 blocks — **directionally
   consistent with the task's own prediction that prime admission carries a
   latency cost, but not statistically confirmed at this sample size.**

## S2b verdict

**`PLACEMENT_EFFECT`** (per `tools/analyze-s2b.py`'s gate: >=4 complete
blocks, `effective_min` delta >= 128, prime first-run-share CI lower bound
> 10pp, and a causal placement field — here both `start_cpu` and
`candidate_mask` — also moved with a CI lower bound > 0).

`uclamp.min` on this OnePlus 13 / WALT build causally moves task placement
toward the prime cluster, mediated by the misfit/capacity-fit check at CPU
selection time, **not** by inflating WALT's predicted-demand signal. The S2a
descriptive demand-to-prime-share curve (158->0%, ..., 616->82.5%) describes a
*different* causal pathway (naturally accumulated demand) and does not
transfer to `uclamp.min`-driven placement — the two produce similar-looking
prime-share outcomes through different scheduler code paths, at demand values
an order of magnitude apart (S2a's curve would predict ~0% prime at
pred_demand~102; this experiment measured ~90%).

## Is 640/768 worth testing?

**Not run, and not recommended next.** The stated reason for reserving 640/768
was to stay inside the S2a demand curve's validated domain (max measured
616) under the now-disproven assumption that `uclamp.min` tracks that curve.
Since this experiment shows placement saturates near ~90-95% already at 512
via a capacity/misfit mechanism unrelated to that curve, 640/768 would mostly
test where the misfit-driven ceiling sits (already close to 95% at some B
runs), not fill in a demand-curve gap. If pursued, it answers a *different*
question ("what's the practical ceiling of the misfit pathway") and should be
scoped and named as such rather than treated as a continuation of this run.

## Phase 2 (real-workload holdout, C2/C4)

**Not executed this session.** Phase 1 (S2b) consumed the full session under
the "mildest operating point, cleanest data over broad coverage" principle
this repo's own methodology notes establish, and it produced a clean,
publishable answer. The holdout matrix (11 workloads x 2 module states x 4
repeats = 88 runs) requires physically operating the device (app launches,
scrolling, camera, gameplay) and per-workload negative controls including the
steady-multi-thread-renderer false-positive check the task flagged as the
biggest known risk to C4 — that is a substantial, separate piece of work with
its own privacy-sanitization pass (`tools/redact-trace.py` exists in `main`
for this) and is better run as its own session/pilot rather than compressed
into this one after a full day's device time already spent on S2b.

## New commits (local, on `experiment/s2b-device-validation`, based on PR #13 head `5255157`)

Not yet pushed — see note below.

- `.gitignore`: exclude the transient `vmlinux.btf` BTF dump
- `tools/analyze-s2b.py`: copied verbatim from PR #14 head `514fc10`
- `tools/s2b-trace-to-csv.py`: new — raw trace -> S2b CSV schema converter
- `experiments/s2b/run-one.sh`: new — single-run on-device orchestrator with thermal gating
- `experiments/s2b/run-block.sh`: new — host-side ABBA/BAAB block driver
- `experiments/s2b/data-2026-08-26/`: 16 run traces (`.gz`), master CSV, JSON analysis, run log
- `docs/S2B_DEVICE_RESULTS.md`: this file

## What is still not established

- Whether misfit/capacity-driven placement (this result) and the S2a
  naturally-accumulated-demand pathway ever compound or interact when both
  are in play on the same thread (not tested — this experiment held demand
  low and constant by design).
- Whether the p95 wake-latency cost is real (directionally present, CI still
  crosses 0 at n=4 blocks; more blocks would resolve it).
- Whether this misfit-driven pathway generalizes to real app threads under
  the production `oplus_bsp_task_overload` guard interacting simultaneously
  (this experiment ran with no `perfd` daemon active and a synthetic worker,
  by design, to isolate the mechanism — Phase 2 is where that interaction
  would be visible).
- Whether 640/768 saturates the effect further or plateaus (not run; see above).
- C2/C4 holdout activation rates on real workloads — Phase 2 not run.
