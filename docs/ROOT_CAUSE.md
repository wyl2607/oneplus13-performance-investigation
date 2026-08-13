# Root cause

A standalone account of the causal chain. The chronological record, including
wrong turns, is in [DATA.md](DATA.md) sections 21–27. This page does not replace
that record and does not upgrade any confidence grade written there.

Confidence grades are carried verbatim:

- **PROVEN** — `oplus_bsp_task_overload` records TID 30423 / `pool-5-thread-1`
  with `limit_flag = 466`, matching the trace exactly in thread identity and
  value. (DATA.md section 23)
- **HIGHLY LIKELY** — that module applies it to the task's `uclamp.max`. It
  exports `set_uclamp_max`, the observed `uclamp.max` equals its recorded
  `limit_flag`, and no other candidate wrote a matching value. The write itself
  has not yet been caught with a timestamp. (section 23)
- **HIGHLY LIKELY** — `limit_flag = floor(0.6 × 1024 × prime_cur_freq / 4320000)`.
  Four observations fit a two-parameter line to within 1 unit; the 0.6 factor
  is inferred, not read out of source. (section 25)
- **HIGHLY LIKELY** — one flagged thread is enough to poison later workers,
  because Linux copies `uclamp_req` in `uclamp_fork()` unless `reset_on_fork`
  is set. The alternative (the module silently clamping each new thread of an
  already-flagged process) fits the same data. (section 24)
- **UNKNOWN** — the trigger condition, whether any userspace daemon requests
  it, and what selects 346 / 376 / 436 / 466, as graded in section 23.
  `/proc/oplus_qos_sched/qos_task_uclamp` reads empty throughout and is *not*
  implicated. Section 27 later *measured* a uid gate and a prime-cluster gate
  with a controlled busy loop; those measurements are below. They do not
  upgrade the section 23 grade: a userspace requester is still unshown, and
  cluster-versus-temperature is not separated.

---

## What the module is

`oplus_bsp_task_overload` is a loaded OPLUS kernel module. `/proc/kallsyms`
exports, among others:

```
t set_uclamp_max        [oplus_bsp_task_overload]
b golden_cpu            b golden_cpu_first      b goplus_cpu
b max_cluster_id        b min_cluster_id        b atd_count      b task_info
```

`golden` / `goplus` is Qualcomm's gold / gold-plus naming — mid and prime
clusters on this SoC. The module knows the topology and has a function whose
job is to set a uclamp maximum.

Its procfs interface:

```
/proc/task_overload/abnormal_task        -rw-rw----  system system
/proc/task_overload/skip_goplus_enabled  -rw-rw-rw-  root   root
                                         -> "debug_enabled=1"
```

`skip_goplus_enabled` is *skip gold-plus*, i.e. the prime cluster, by name.

It is a general runaway-thread guard, not benchmark detection. On a clean
table, before Geekbench was launched, an unrelated third-party app was already
logged at `limit_flag = 376` while idle at the launcher (section 24).

`cpufreq_bouncing` is a real but separate limiter. It compounds with this
module (below). It is not the placement collapse.

---

## The `abnormal_task` table

The module keeps a kernel-maintained table. The header names the columns:

```
pid    uid    limit_flag  comm             date           temp  freq
30423  10xxx  466         pool-5-thread-1  1786635235185  0     3283200
18846  10xxx  466         pool-7-thread-1  1786636130741  0     3283200
```

`limit_flag` is the cap written onto the thread. **1024 means untouched.
Anything lower is a clamp.** `freq` is the prime-cluster clock at the moment
the row was written. `date` is milliseconds since epoch.

TID 30423 / `pool-5-thread-1` is the exact thread the section 22 placement
trace observed carrying `uclamp.max = 466`. That match is the PROVEN grade.

The table also holds ordinary app threads (`DefaultDispatch`,
`SessionManager`, `HeapTaskDaemon`, `UnityMain`) at 346 / 376 / 436 / 466 /
1024. 1024 rows are evaluations that did not clamp.

One logged row is enough to affect a whole process. Section 24 caught a
single Geekbench row and then watched 169 distinct threads carry
`uclamp.max = 466`. Every later thread was already at 466 the first time it
was sampled, and none of them produced their own row. Graded HIGHLY LIKELY
as `uclamp_fork()` inheritance.

The clamp also outlives the workload that triggered it. TID 30423 was flagged
during one benchmark run and was still clamped when the next run started on
the same pooled thread. Force-stopping the app before a measurement is
therefore a precondition, not politeness.

---

## The `limit_flag` formula

The cap is not a constant. Across every clamped `abnormal_task` row in this
repository:

| prime `scaling_cur_freq` | `limit_flag` | `0.6 × 1024 × freq / 4 320 000` |
|---|---|---|
| 3 283 200 | 466 | 466.94 |
| 3 072 000 | 436 | 436.91 |
| 2 649 600 | 376 | 376.83 |
| 2 438 400 | 346 | 346.79 |

```
limit_flag = floor(0.6 × 1024 × prime_cur_freq / 4320000)
```

Four points, all within 1 unit, consistent with truncation. The module leaves
an "abnormal" task with 60% of the utilisation its current prime frequency
represents.

**Graded HIGHLY LIKELY.** Four observations fitting a two-parameter line is a
good fit but not a derivation. The 0.6 factor is inferred, not read out of
source. A fifth point at a substantially different clock is
`TODO: unmeasured`.

Because the prime clock varies, the cap varies, and so does the score. On
this device: 934, 1145, 1229 across three runs, tracking caps of 346, 466 and
466. Clamp ratio 346/466 = 0.742; score ratio 934/1187 = 0.787. Within 6%.
Score is very nearly proportional to `uclamp.max`. A single Geekbench figure
from this device is one sample from a distribution whose width is set by
where the prime clock sat when the guard fired.

### The two limiters compound

`cpufreq_bouncing` pulls the prime cluster from 4 320 000 toward 2 438 400.
`task_overload` samples that clock and computes 346 instead of 466. The
harder uclamp then pins the worker further onto the mid cluster *and* holds
the mid cluster below its own ceiling. Arm A of the A/B (stock uclamp, CFB
already off but still observed at 2 438 400 at fire time) scored 934 rather
than ~1200 for that reason.

CFB does not merely cost clock on prime cores the workload never reaches. It
feeds the uclamp guard a lower number.

---

## The uid gate

Identical busy loop, identical `comm` (`sh`), identical prime clock. Only
the uid differs (section 27, `tools/trigger-probe.sh`):

| uid | Result | `uclamp.max` | Time |
|---|---|---|---|
| 10999 (synthetic app) | CLAMPED | 466 | 5.84 s, 26.79 s |
| 0 (root) | logged only | 1024 | 14.06 s |
| 1000 (system) | logged only | 1024 | 41.75 s |

Root and system tasks *are* evaluated and *are* written into `abnormal_task`,
with `limit_flag = 1024`. The exemption is applied at the clamp decision, not
by skipping the check. Every historical uid 0 and uid 1000 row in the table
also carried 1024, even at full prime clock.

A benchmark, or a busy loop, run from a root shell will not reproduce what an
app sees. The thermal characterisation in DATA.md sections 2, 6 and 7 used
exactly that proxy. Those numbers remain valid as thermal numbers. They are
not a valid model of app behaviour. See [THERMALS.md](THERMALS.md).

---

## Prime-cluster-only trigger, and the one-way ratchet

Same uid, same load, only the affinity mask differs (section 27). Toybox
`taskset` wants a bare hex mask; `0x3f` is rejected.

| Affinity | Result | Time | Junction |
|---|---|---|---|
| `taskset 3f` — mid, CPU0–5 | never clamped | 45 s timeout | 45.1 °C |
| `taskset c0` — prime, CPU6–7 | CLAMPED at 466 | 5.12 s | 64.8 °C |
| unpinned | CLAMPED at 466 | 5.1–26.8 s | 61–73 °C |

Time from load start to clamp, app uid, unpinned or prime-pinned: 5.91,
5.13, 5.84, 26.79, 5.14, 5.12 s. Five of six inside six seconds, one outlier
at 27 s. There is no long grace period.

The consequence is a one-way ratchet:

```
task starts, utilisation ramps
  -> the scheduler correctly promotes it to the prime cluster
  -> the guard sees sustained load ON PRIME and clamps uclamp.max
  -> the clamped task falls back to the mid cluster
  -> on mid it can never satisfy the trigger again, so it never returns
```

It punishes precisely the tasks the scheduler got right, and there is no
path back. That is why `abnormal_task`'s `freq` column always holds a prime
frequency, and why the limit is computed from the prime clock: the task was
on prime at the moment it was judged.

**Confound, stated:** cluster and temperature are not separated by this pair.
The mid-pinned run only reached 45.1 °C against 64.8 °C for prime, so a
temperature threshold would fit the same two data points. The cluster reading
is favoured by the rest of the evidence — the module's `goplus_cpu` symbol,
its `skip_goplus_enabled` node, and the prime-clock-based formula — but a
mid-cluster load driven to 65 °C is `TODO: unmeasured`.

---

## `cpu_capacity` and why 466 < 792 means no promotion

```
/sys/devices/system/cpu/cpu*/cpu_capacity
cpu0-cpu5 = 792        cpu6-cpu7 = 1024
```

Linux EAS / WALT places a task where its clamped utilisation fits.
**466 < 792.** A task whose utilisation is clamped to 466 fits entirely
inside one mid core's capacity, so the scheduler never has a reason to
migrate it to a prime core. The prime cores are not blocked, not
frequency-clamped, and not hot. They are never asked for.

Section 22, 437 s, 961 genuinely single-threaded samples:

- busiest core is a mid core in 95.8% of samples
- a prime core ≥70% busy in 2.0%
- prime `scaling_cur_freq` at idle 1 017 600 in 97.8%

`policy6 scaling_max_freq` sat unmoved at 3 283 200. cpuset was `/top-app`
with `cpus_allowed=0-7`. `Thermal Status` was `NONE`. Every relevant cooling
device read 0. The same clamp also held the mid cores below their own
ceiling: 2 555 MHz average against 2 918 400 available.

346 is the same mechanism, harder. Arm A prime residency of running
Geekbench threads was 8.0%.

---

## The A/B

Both arms used the identical sampler, kprobes and logcat capture. Both
started from a force-stopped thread pool so no clamp could ride in. Both
started from a cool device with ceilings verified at 2 918 400 / 3 283 200
and `cfb=0`.

The only difference in arm B was a loop running
`uclampset -a -M 1024 -p <pid>` every 250 ms. Toybox's first-party
`uclampset`, via the ordinary `sched_setattr` path. Nothing else was
touched — no cpufreq, no cpuset, no thermal, no governor, no module
parameter.

| | Arm A (control) | Arm B (uclamp lifted) | Change |
|---|---|---|---|
| `uclamp.max` on workers | **346** | **1024** | |
| Prime residency of running threads | **8.0%** | **59.5%** | |
| CPU7 alone | 6.3% | **46.4%** | |
| **Single-core** | **934** | **2126** | **+128%** |
| **Multi-core** | **6017** | **8386** | **+39%** |

The prediction recorded before the run, given the prime ceiling of
3 283 200, was 1900–2100. Measured 2126, 4.3% above the top of the range.

Against a same-version reference of 2681 / 8846 (GB7 7.0.0, CPH2655,
user-supplied, not independently verified in this repository):

```
Arm B  single-core 2126 = 79.3% of reference
prime ceiling 3 283 200 / 4 320 000 = 76.0% of rated
2126 × (4 320 000 / 3 283 200) = 2797 at rated clock, against 2681
```

Scaled to its rated clock this device measured slightly above that
reference, within sample-to-sample variation. The remaining single-core
shortfall at the tune's ceiling is the ceiling, not a third mechanism.

The intervention was caught live. The module still fired in arm B
(`limit_flag=466` at t=3205.98); the loop reverted it within one 250 ms
poll. Across the whole run: 34121 thread-samples at 1024, **1** sample at
466. That single 466 is the window between the guard writing and the loop
undoing it.

### What it costs

| | Arm A | Arm B |
|---|---|---|
| Junction, median | 40.5 °C | 54.0 °C |
| Junction, p95 | 52.1 °C | **87.2 °C** |
| Junction, max | 78.4 °C | **95.0 °C** |
| Shell, max | 35.0 °C | 36.1 °C |

The safety guard aborted at 98.4 °C junction, shell 35.5 °C. 6.6 °C of
margin to the 105 °C hardware trip point. The phone's outside surface
barely moved. Section 18 established that Android's thermal framework
escalates on skin, not junction, so nothing in the framework would have
intervened.

That is the argument for the module existing. What it cannot do is tell a
runaway bug apart from a user who asked for sustained compute.

### Scope of the claim

One A/B pair, one device, one benchmark. The effect size is far outside the
observed run-to-run spread (934–1229 stock). The mechanism is independently
supported by the dose-response in section 25 and the per-thread traces in
sections 22 and 24. The arms were not repeated or order-reversed, so the
ordering effect is `TODO: unmeasured`.

App launches are not in this chain. A cold start is 0.5–2 s and ends before
the guard engages (section 20; confirmed by the 5–27 s trigger window).
Video export, compilation, emulators and on-device inference have the same
*shape* as the reproducer and are expected to be affected.
`TODO: unmeasured` — see [../experiments/real-workloads/](../experiments/real-workloads/).
Games go through a separate `game_opt` path and are untested.

---

## Confounds, left standing

1. **Cluster versus temperature is not separated.** The prime-only trigger
   pair also differs by ~20 °C. A mid-cluster load at 65 °C is
   `TODO: unmeasured`.
2. **The formula is fitted, not derived.** Four points, two parameters, no
   source. A fifth distinct clock is `TODO: unmeasured`.
3. **One A/B pair, not reversed.** Ordering effect `TODO: unmeasured`.
4. **The thermal numbers in sections 2, 6 and 7 are not an app model.**
   Those loads ran as root and are exempt from the uid gate.
