# S2a — event-level scheduler tracer

S1 ended with a question its instrument could not answer. A wake-heavy foreground thread never
reached the prime cluster, and a 250 ms sampler could only show that it had not: the wake, the
enqueue, the CPU selection, the switch-in and any migration all happen between two samples.

S2a adds instrumentation and nothing else. It sets no uclamp, no affinity, no cpuset, no frequency,
and it does not touch the Daily / Performance / Extreme parameters.

- `tools/scheduler-event-tracer.sh` — the tracer
- `tools/wake-pair-worker.sh` — the S1 controlled pair, now reproducible
- `tools/analyze-wake-cycles.py` — turns a trace back into wake cycles
- `tools/btf-offsets.py` — derives kprobe offsets from the device's own BTF
- `tools/redact-trace.py` — strips third-party thread names before anything is committed

Evidence: `data/2026-08-22/s2a-tracing-capability.txt` (what the kernel exposes),
`s2a-tracer-validation.txt` (T1–T6), `s2a-wake-path.txt` (results), raw traces in
`data/2026-08-22/s2a-traces/`.

## 1. What the kernel exposes

`/sys/kernel/tracing` is mounted; `/sys/kernel/debug/tracing` does not exist on this ROM.
`available_tracers` is `nop` only and `available_filter_functions` is absent, so there is no
function tracer — but all 1932 static tracepoints are there, and **this device runs Qualcomm WALT,
which traces its own placement decisions**:

| event | what it gives |
|---|---|
| `sched:sched_waking` / `sched_wakeup` | wake start, and the CPU finally selected |
| `sched:sched_switch` | the CPU it actually ran on, and why it stopped |
| `sched:sched_migrate_task` | orig → dest |
| `sched:sched_stat_wait` | the runqueue wait the kernel itself attributes |
| `schedwalt:sched_task_util` | the decision: util, candidates, prev_cpu, best_energy_cpu, fastpath, start_cpu |
| `schedwalt:sched_find_best_target` | the cluster search: start_cpu, order_index, end_index, skip |
| `schedwalt:sched_enq_deq_task` | enqueue CPU, demand, pred_demand_scaled, **misfit** |
| `sched_assist:set_ux_task_to_prefer_cpu` | the OPLUS ux placement hint |
| `frame_boost:find_frame_boost_cpu` | the frame-boost placement hint |

Every one of them accepts a kernel-side `pid==` filter, verified by writing and reading it back.

What is **not** there, and this bounds S2a: no `task_overload` tracepoint, no `uclamp` tracepoint,
no `select_task_rq` tracepoint. The oplus clamp S1 could not attribute has no event at all.

## 2. How the tracer stays out of the way

- its own tracefs **instance**, so the global buffer (7 KB, `tracing_on=0`), the ROM's 16 globally
  enabled events and its three instances are never written; teardown is `rmdir`
- kernel-side filters on the target pid, one per event — nothing is grepped in userspace
- no per-event userspace path at all: enable, sleep, disable, copy the buffer once
- loss accounting read before the buffer is, and a hard `exit 5` if the kernel dropped anything
- global single-instance lock, and signal handlers that really exit with 130

**`trace_clock` is forced to `global`.** A fresh instance defaults to `local`, which is per-CPU.
Under `local` the same capture reconstructs cleanly, reports zero timestamp inversions, and gets
every causal pairing wrong — see T6.

## 3. The answer

A wake-heavy thread's cycle, at event resolution:

```text
sched_waking -> sched_find_best_target -> sched_task_util -> enqueue -> sched_wakeup -> switch-in
```

| | pair-wake | T1 | T6 |
|---|---|---|---|
| wake → first run, p50 | 76 µs | 55 µs | 66 µs |
| wake → first run, p95 | 143 µs | 108 µs | 165 µs |
| selected CPU == first-run CPU | **99.3 %** | 97.6 % | 97.9 % |
| prime share | 0 % | 0 % | 0 % |

**CPU 0–5 is chosen at wake selection.** It is not chosen and then corrected, and nothing migrates
the thread up afterwards.

The prime cluster is not evaluated and rejected — it is never a candidate. Over 283 placements
`start_cpu = 0`, `order_index = 0` and `end_index = 0` every time, the candidate mask is always a
single CPU inside `0x3f`, and `misfit` is 0 in all 686 enqueue records. The ux and frame-boost
hints were enabled and filtered on this thread and fired zero times.

The continuous worker, traced from birth, takes the other path: its util ramps 538 → 633 → 655,
the enqueue at 655 records `misfit=1`, the load balancer moves it 0 → 7, and it stays on CPU 7 with
`pred_demand_scaled` ≈ 779 against a 792-capacity silver cluster.

So the two arms of the S1 pair diverge at WALT's task demand, which drives both the cluster the
search starts at and the misfit flag. Not at a frequency ceiling, and not at a clamp.

## 4. Where the threshold is — and why the planned uclamp.min values are too low

Same worker, same 20 ms sleep, burst swept so only demand changes:

| burst | duty | pred_demand p50 | prime first-run share |
|---|---|---|---|
| 2000 | 38 % | 158 | 0.0 % |
| 4000 | 50 % | 215 | 0.7 % |
| 6000 | 59 % | 256 | 1.8 % |
| 8000 | 59 % | 401 | 7.8 % |
| 11000 | 63 % | 424 | 15.2 % |
| 15000 | 65 % | 499 | 43.3 % |
| 20000 | 65 % | 616 | 82.5 % |

The crossover is around 500 and decisive by 616. **A bounded uclamp.min matrix of 128 / 256 / 384
sits entirely below it** — at 401–424 this thread still only reaches the prime cluster on 8–15 % of
wakes. Running that matrix would return "uclamp.min changes nothing", and that would be a property
of the chosen values, not of the lever.

Landing on prime also costs wake latency: p50 rises from ~30 µs to ~51 µs across the sweep.

## 5. uclamp at the enqueue instant

No tracepoint carries a numeric uclamp value. A kprobe on `uclamp_eff_value` does, reading
`uclamp_req[]` and `uclamp[]` out of the task_struct — but this kernel rejects BTF-typed kprobe
arguments (`$arg1->pid`), so it needs literal byte offsets, and a guessed offset is a magic number
that reads the wrong field silently. `tools/btf-offsets.py` derives them from the device's own
`/sys/kernel/btf/vmlinux`; `--uclamp-offsets` refuses to guess.

Validated over 2470 probe rows: 0 carried a pid other than the target, and the decoded values match
`/proc/<tid>/sched` exactly. 102 of 103 placements had a uclamp read within 200 µs, median |Δt|
4 µs. So requested and effective **can** be aligned to enqueue.

The difference that shows up is not the value — both were 1024 — but `active`: set in 50 of the 102
placement instants and clear in 52. S1 inferred from a 250 ms poll that the effective copy latches
at enqueue; that inference now has a 4 µs measurement under it.

The probe fires 24 times per placement for one thread, which is why it is off by default.

## 6. Validated, with the failures that made it necessary

| gate | verdict |
|---|---|
| T1 correctness | **PASS** — duty 40.58 % (trace) vs 40.00 % (`/proc/<tid>/stat`) vs 39.91 % (`schedstat`), and matching CPU histograms |
| T2 filtering | **PASS** — 0 foreign rows; a filter aimed at init returns init, not the target and not nothing |
| T3 lock / signals / cleanup | **PASS** — 3 / 130 / 130 / 0, instance and lock gone every time |
| T4 dropped-event detection | **PASS** — 8 KB buffer: overrun 977, `loss=YES`, exit 5 |
| T5 tracer overhead | **no effect detected**, −1.66 %, t = −0.93, n = 22; the experiment can only exclude effects above ~4 % |
| T6 timestamp ordering | **PASS**, and it caught the `local` clock trap |

Four defects were found and each was verified by reverting the one line: a `/proc/self/comm` write
whose trailing newline turned `/proc/<tid>/stat` into a two-line file; a worker loop whose own
deadline test forked `cut` once per iteration and held "continuous" at 57 % duty; an analyzer that
read `target_cpu=002` as octal and so reported "the scheduler always selects CPU 0"; and a harness
that deleted a run directory before the process that was about to write into it. Details in
`data/2026-08-22/s2a-tracer-validation.txt`.

## 7. Raw traces are redacted

The tracer filters events by pid, but an ftrace line is stamped with whoever was running when it
fired, and `sched_switch` names the task on the other side. The first S2a capture carried the
owner's installed applications in the context column. `tools/redact-trace.py` replaces every
userspace comm that is not a kernel thread or a worker under study with `app-<pid>`; pid identity
and wake relationships survive, the names do not. Re-running the analyzer before and after
redaction produces byte-identical results.

## 8. What S2a does not establish

- nothing about the oplus `task_overload` clamp — it has no tracepoint on this kernel, so S1's
  withdrawn clamp/placement conclusion stays withdrawn
- the sweep moves demand by changing the workload. Whether WALT's `start_cpu` and misfit tests use
  the **clamped** util is a different measurement, and it is the first thing S2b has to check
- these are synthetic single threads. S1 already measured that real foreground windows are 3–4
  thread workloads with a rotating leader
- the device was screen-off (Dozing) with ~9 % of eight cores busy throughout; wake latency on a
  loaded, screen-on device was not measured
