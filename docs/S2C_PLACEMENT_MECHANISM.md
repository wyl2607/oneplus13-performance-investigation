# S2c mechanism refinement: which placement-stage field first diverges?

**Question this doc answers:** PR #15 showed `uclamp.min=512` moves a thread
from 0% to ~90% prime first-run share, but the explicit enqueue `misfit` flag
only moves 0% -> ~2.24pp -- far too small to carry a ~90pp effect. Which field
actually diverges first, and can the misfit flag be ruled out as the main
pathway?

Status key: **MEASURED** (read directly from a trace field),
**DERIVED** (computed from measured values), **NOT ESTABLISHED**.

## Data source

No new device collection was needed for this phase. `schedwalt/sched_task_util`
and `schedwalt/sched_find_best_target` already emit every field this
investigation needed (`fastpath`, `best_energy_cpu`, `order_index`,
`end_index`, `skip`, `min_util`, `prev_cpu`, raw `util`; `schedwalt/sched_enq_deq_task`
emits raw `demand` alongside `pred_demand_scaled`) -- confirmed against the
kernel's own tracepoint `format` files, snapshotted to
`experiments/s2c/data-20260826/formats/*.format` before trusting any field
name. So PR #15's own 16 raw traces
(`experiments/s2b/data-20260826/*.trace.gz`, 8 runs arm A=0, 8 runs arm
B=512, 8494 complete wake cycles total) were re-parsed with a new, wider
parser, [`tools/s2c-trace-to-csv.py`](../tools/s2c-trace-to-csv.py), rather
than re-running the device. This matches the task's own instruction ("if the
data is already stable, don't repeat the 16-run collection -- the goal is
mechanism localization, not re-proving the placement effect") and avoids
unnecessary device/thermal exposure for a question the existing data can
already answer.

Parser tests: [`tools/test_s2c_parser.py`](../tools/test_s2c_parser.py),
8 assertions covering cycle boundaries, the `uclamp_se` bitfield decode
(`value:11 bucket_id:5 active:1`), and the no-forward-fill contract (a field
absent in one cycle must not leak in from a neighboring cycle). `python3
tools/test_s2c_parser.py` -> `OK: 8 assertions passed`.

Output: `experiments/s2c/data-20260826/s2c-mechanism-cycles.csv`, 8494 rows,
one per complete wake cycle, 30 columns (vs S2b's 15) -- see the file header
for the schema. Analysis: [`tools/analyze-s2c.py`](../tools/analyze-s2c.py).

## Event-order correlation

Every extra field is captured with `setdefault()` at first occurrence inside
the cycle's own `[wake_ts, close)` window -- same discipline as
`tools/s2b-trace-to-csv.py` -- so a value from a later cycle can never leak
backward, and a field that never fires in a given cycle is emitted as an
empty CSV cell, never forward-filled. `trace_clock=global` (PR #13's
requirement) makes cross-CPU event ordering meaningful; the tracer aborts if
it isn't set (see `scheduler-event-tracer.sh`).

Directly inspected event order for one real cycle (`s2b-r02`, arm B, a
cycle that selected prime cpu6):

```
sched_waking                                          [cpu6]
s2a_uclamp   eff_min=512 active=0   (already 512, NOT YET "active")
sched_find_best_target  start_cpu=6 candidates=0x40(cpu6 only) min_util=512
sched_task_util         prev_cpu=6 fastpath=2 best_energy_cpu=6
s2a_uclamp   eff_min=512 active=1   (now "active")
sched_enq_deq_task      enqueue cpu=6 misfit=0
sched_wakeup             target_cpu=006
sched_switch  next_pid=<tid>        <- first_run_cpu=6
```

This is close to the task's hypothesized pipeline
(`uclamp_eff -> find_best_target -> task_util -> enqueue -> wakeup -> switch`)
and confirms `find_best_target` runs, and decides `start_cpu`/`candidates`,
**before** the explicit `misfit` flag is ever set at enqueue.

## Q1 -- is `effective_min` already 512 before placement runs?

**MEASURED.** The first `s2a_uclamp` reading after `sched_waking`, i.e.
before `find_best_target` is even called, already reads 512 in **100.0%**
(4729/4729) of arm-B cycles. Arm A stays at 0 (mean 0.0, n=3764). So
`uclamp.min` is not something `find_best_target` or the enqueue path itself
raises mid-cycle -- it is already resident on the task_struct for the entire
cycle, and is available to be read by anything upstream of placement.

`min_util`, `sched_find_best_target`'s own capacity-requirement argument,
equals the effective clamp exactly: arm A mean 115.6 (matches S2b's
`pred_demand` reading almost exactly, since with no clamp the natural
predicted demand IS the requirement), arm B mean 512.0 (matches the clamp
exactly, decoupled from `pred_demand`, which independently stayed
~100-120 in both arms per PR #15). **This is the direct feed-through:**
`uclamp.min` reaches `find_best_target` as `min_util`, separately from
WALT's own predicted-demand estimate.

## Q2 -- first divergent field, in pipeline order

| field (in event order) | arm A | arm B | delta |
|---|---|---|---|
| `start_cpu` (find_best_target's search seed) | 0.00% | 91.86% | **+91.86pp** |
| `candidate_mask` includes prime | 0.00% | 89.64% | **+89.64pp** |
| `misfit` flag (enqueue, later) | 0.00% | 2.24% | +2.24pp |
| `selected_cpu` (sched_wakeup) | 0.00% | 89.92% | +89.92pp |
| `first_run_cpu` (actual switch-in) | 0.00% | 89.92% | +89.92pp |

**`start_cpu` and `candidate_mask` diverge together, both at the very first
`sched_find_best_target` call, and both already carry essentially the full
~90pp effect.** They arrive chronologically before `misfit` is set. The
`misfit` flag's own ~2.2pp shift is a small residual, not the channel that
carries the other ~88pp.

**Candidate-set size is always 1** (`mean popcount(candidate_mask)` = 1.00
whether `start_cpu` lands on prime or mid, n=4345 / n=4149) -- confirmed by
`fastpath` almost never being the "no fastpath" value (`fastpath` distribution
A={0: 1095, 2: 2669}, B={0: 451, 2: 4279}; the dominant value 2 is a
single-candidate fastpath on both arms, more common in B). So for this
workload's wake pattern, `find_best_target` is not doing a broad multi-cluster
energy search that a capacity/misfit filter narrows down after the fact --
by the time it's traced, the candidate set already contains exactly one CPU.
**The decision of "which one CPU" is what moves with the arm, and it moves
before `find_best_target` even returns.**

## Q3 -- arm B, misfit==0 subset: still prime?

**This is the decisive check the task asked for.** 97.8% of arm-B cycles
(4624/4730) have `misfit==0` -- i.e. the explicit enqueue flag that PR #15
measured at "only 2.24%" is in fact *usually off* even within the arm that
shows the placement effect. Restricting to exactly those `misfit==0` cycles:

| | prime rate |
|---|---|
| `start_cpu` on prime, misfit==0 subset | **91.7%** (n=4624) |
| `selected_cpu` on prime, misfit==0 subset | **92.0%** (n=4624) |
| `first_run_cpu` on prime, misfit==0 subset | **92.0%** (n=4624) |
| `first_run_cpu` on prime, misfit==1 subset (n=106) | **0.0%** |

The `misfit==0` subset's prime rate (92.0%) is statistically indistinguishable
from -- actually slightly *higher* than -- arm B's overall rate (89.9%). And
the small `misfit==1` subset (2.2% of B cycles) is **never** prime at
first-run (0/106). That is the opposite of what "misfit explains the
placement" would predict.

**CONCLUSION: the explicit `misfit` flag is confirmed NOT the main placement
pathway.** It is best read as a downstream signal that fires on the ~2% of
cycles where the raised `min_util` requirement did *not* get satisfied by
the single-candidate fastpath's choice (e.g. both prime cores briefly
unavailable) -- a consequence of contention, not the mechanism that produces
the other ~90pp.

## What IS established, and what is not

```
uclamp.min=512
  |  (MEASURED: present on task_struct for the whole cycle, well before
  |   find_best_target; feeds in directly as min_util)
  v
start_cpu / candidate_mask   <-- FIRST FIELD TO DIVERGE, ~90pp, at the
  |                               very first find_best_target call
  |  (MEASURED: candidate set is already a single CPU by the time it's
  |   traced -- "fastpath" -- not a multi-candidate search later filtered)
  v
selected_cpu -> first_run_cpu   (tracks start_cpu almost exactly)

misfit flag: a SEPARATE, much smaller (~2.2pp) signal that fires AFTER
start_cpu/candidate_mask are already decided, on the minority of B cycles
where the single-candidate fastpath's pick didn't hold up. NOT the carrying
mechanism for the ~90pp shift (Q3).
```

**EXACT BRANCH NOT ESTABLISHED:** which specific kernel function/branch turns
`min_util=512` into `start_cpu`=prime for a single-candidate fastpath. Two
observations bound the search without resolving it:

- `start_cpu == prev_cpu` (the CPU the thread last ran on) in only 21.0%
  of cycles overall (1786/8494) -- weaker than the "sticky affinity" reading
  of the earlier hand-inspected sample suggested. Not the dominant seed.
- `start_cpu` equals the CPU that observed/emitted the trace event (a proxy
  for the waker's CPU) in 40.0% (s2b-r02) and 31.3% (s2b-r10) of cycles --
  also only partial.

Neither prev_cpu nor waker-cpu alone explains the seed in the majority of
cycles; some other input (possibly `min_util` itself feeding a fastpath that
picks the nearest CPU meeting the capacity requirement, or an internal WALT
heuristic not exposed by any traced field) is doing the rest. This would need
kernel source access (not available in this repo/session) to resolve further,
and is left as **NOT ESTABLISHED** rather than guessed at.

## Sanity: cycle-count / throughput difference between arms

PR #15 flagged arm A running ~467-475 cycles/run vs arm B ~590-592 -- about
25% more wake cycles in B -- as unexplained. From this same re-parsed data:

- Both arms traced for the same 15 s window (`--duration 15` in every run,
  unchanged by uclamp.min).
- Arm A mean cycles/run (8 runs): (467+469+470+474+475+467+470+472)/8 = 470.5
- Arm B mean cycles/run (8 runs): (590+591+592+590+592+592+592+591)/8 = 591.25
- Ratio: 591.25 / 470.5 = **1.257x**, matching the ~25% PR #15 reported.

**Revised 2026-08-26 after S2c Phase 2's clamp ladder --
this section's original attribution to prime placement/clocking was wrong.**
`docs/S2C_MINIMUM_CLAMP.md`'s five-point ladder (uclamp.min in
{0, 256, 384, 448, 512}) measured `cycles_per_second` directly and found it
rises **before** the placement threshold is ever crossed: 28.63 (sd 0.25) at
0 -> 35.50 at 256 -> 37.34 at 384 -> 38.35 at 448 -- all four of these arms
sit at ~0% prime first-run share (max 0.22%, i.e. still entirely on mid) --
and only reaches 38.77 at 512, the one arm where placement actually jumps to
~91%. So roughly (38.35 - 28.63) / (38.77 - 28.63) = **96%** of the total
cycle-rate gain between the 0 and 512 endpoints is already present at 448,
*before* any placement change.

- **ESTABLISHED:** cycle rate rises substantially below the prime-placement
  threshold (MEASURED directly via `cycles_per_second` in the Phase 2 ladder,
  not derived). Therefore most of the observed cycle-rate gain cannot be
  attributed to prime placement itself, contradicting this section's
  original wording ("consistent with prime cores clocking the fixed-length
  burst faster").
- **LEADING HYPOTHESIS:** `uclamp.min` raises the utilization/frequency floor
  (`min_util`) on the mid cluster even when it isn't enough to move
  placement, improving DVFS response and shortening the fixed-length burst,
  which is what produces more completed wake cycles per fixed trace window.
- **NOT ESTABLISHED:** actual frequency residency (`cpu_frequency` /
  `time_in_state`) was not directly measured anywhere in S2c -- the ladder
  measured wall-clock cycle throughput, not clock frequency itself. The DVFS
  attribution above remains a hypothesis pending direct frequency evidence,
  which is what S2d (`docs/S2D_THRESHOLD_DVFS.md`) exists to collect.

## Files

- `experiments/s2c/data-20260826/formats/*.format` -- raw tracepoint format
  snapshots for every event this tracer enables (pulled before any field
  extraction, per methodology)
- `experiments/s2c/data-20260826/s2c-mechanism-cycles.csv` -- 8494-row
  extended cycle CSV, reparsed from PR #15's own 16 traces
- `tools/s2c-trace-to-csv.py`, `tools/analyze-s2c.py`, `tools/test_s2c_parser.py`
