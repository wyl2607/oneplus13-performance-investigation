# S1 dominant-thread observer

Status: **V1–V6 validated and S1 collected on device, 2026-08-22**  
Branch: `feature/dominant-thread-observer`  
Tool: `tools/dominant-thread-observer.sh`, analyzer `tools/analyze-dominant-thread.py`  
Evidence: `data/2026-08-22/s1-observer-validation.txt`,
`data/2026-08-22/s1-dominant-thread-traces.txt`, raw traces in
`data/2026-08-22/s1-traces/`

This is the first implementation step after the eight-core ceiling work closed as a null result in
`DATA.md` sections 42–43.

The next question is no longer “which P6 ceiling maximizes eight-core throughput?” It is:

> When one or two foreground threads repeatedly wake and become latency-critical, which threads
> dominate the window, where does the scheduler place them, and what uclamp / CPU-eligibility state
> do they actually have?

This tool answers that question **without changing performance state**.

---

## 1. Safety / ownership contract

The observer may read:

```text
/dev/cpuset/top-app/cgroup.procs
/proc/<pid>/task/<tid>/stat
/proc/<pid>/task/<tid>/schedstat
/proc/<pid>/task/<tid>/status
/proc/<pid>/task/<tid>/sched
/proc/<pid>/task/<tid>/comm
/proc/uptime
```

It must not write:

```text
/sys/**
/proc/sys/**
/proc/task_overload/**
/dev/cpuset/**
/dev/cpuctl/**
msm_performance
cpufreq_bouncing
uclamp
sched affinity
```

The only writes are its own temporary files below:

```text
/data/local/tmp/op13-dominant-thread-observer.lock/
```

and those are removed on every normal/INT/TERM exit.

A global single-instance lock is intentional. The repository already lost one measurement to two
harnesses running concurrently. Even a read-only observer changes the workload if two copies scan
hundreds of `/proc` files at once.

---

## 2. Why the observer has two sampling stages

Reading every scheduling file for every top-app thread at 10–20 Hz would create enough observer
work to contaminate the thing being measured.

The scaffold therefore uses two stages.

### Fast stage — every sample window

For all threads belonging to application TGIDs represented in `top-app`:

```text
schedstat:
  runtime_ns
  runqueue_wait_ns
  timeslices

stat:
  current/last CPU
```

The window is ranked by `delta runtime_ns`.

### Enrichment stage — only top N threads

Only the dominant threads get the more expensive reads:

```text
Uid
Cpus_allowed_list
uclamp.min
uclamp.max
nr_migrations total
voluntary context switches total
non-voluntary context switches total
```

This is not yet a wakeup tracer. `schedstat` timeslices and context-switch totals are proxies that
help decide which exact tracing instrument is worth adding in S2.

---

## 3. Foreground identity

Foreground ownership comes from the kernel's own:

```text
/dev/cpuset/top-app/cgroup.procs
```

For each entry the observer reads `Tgid` and `Uid` from `/proc/<pid>/status`, keeps application
UIDs (`uid >= 10000`), then enumerates `/proc/<tgid>/task/*`.

`cgroup.procs` rather than `tasks`: both were measured against each other on-device and return the
identical TGID set, but `tasks` lists every thread, which meant 163 `status` reads instead of 3.

This deliberately avoids process-name matching. This repository has already had repeated bugs from
`comm` truncation and name-based identification.

If the top-app TGID set changes inside a sample interval, that interval is discarded and emitted as:

```text
EVENT|...|type=top_app_changed|...
```

Joining snapshots from two different apps would measure thread disappearance/creation rather than
scheduler behaviour.

---

## 4. Usage

Exit codes: `0` completed, `2` bad arguments or environment, `3` another instance holds the lock,
`130` ended by INT/TERM.

Run explicitly through `sh`; executable mode is not required:

```sh
su -c 'sh /path/to/dominant-thread-observer.sh 30 250 5'
```

Arguments:

```text
1: duration_s    default 30, minimum 1
2: interval_ms   default 250, allowed 50..2000
3: top_n         default 5, allowed 1..20
```

Recommended first device-validation run:

```text
30 s
250 ms
5 threads
```

Do not start at 50 ms. First measure observer overhead and confirm that the output is trustworthy.

---

## 5. Output contract

The format is line-oriented and intentionally easy to parse from shell, Python, or a future App.

### META

```text
META|version=1|duration_s=30|interval_ms=250|top_n=5|kernel=...|read_only=yes
```

### WINDOW

```text
WINDOW|seq=N|t_cs=...|wall_ms=...|threads=...|busy_threads=...|total_runtime_ms=...|total_runq_wait_ms=...|tgids=...
```

`threads` and the two totals cover **every** thread compared in the window, not
only the `top_n` that are reported. Without that denominator the concentration
question cannot be answered at all: `top_n` truncation hides how much of the
window the tail is holding.

### THREAD

Header:

```text
FIELDS|THREAD|seq|rank|tgid|tid|uid|comm|runtime_ms|runtime_pct|runq_wait_ms|slices|cpu_start|cpu_end|allowed|uclamp_min|uclamp_max|uclamp_max_eff|migrations_total|vol_ctx_total|nonvol_ctx_total
```

Each `THREAD` row is one dominant thread in that window.

Important interpretation:

- `runtime_ms` / `runtime_pct`: CPU execution delivered inside the observed window;
- `runq_wait_ms`: time runnable but waiting according to `schedstat`;
- `slices`: interval delta of scheduler run periods / timeslices;
- `cpu_start`, `cpu_end`: CPUs reported at the two snapshots; **not** a migration count;
- `migrations_total`: cumulative scheduler migration counter at enrichment time;
- context-switch fields are cumulative totals at enrichment time;
- `uclamp_*` and `allowed` are current state at enrichment time;
- `uclamp_max` is what the task requested, `uclamp_max_eff` is what the scheduler last latched.
  **They diverge.** A continuously running thread the oplus guard had clamped to 500 still read
  `effective=1024` in 17 of 30 samples and only picked up 500 once it was dequeued, because the
  effective value is latched at enqueue. Reading only `uclamp_max` would claim a clamp that is not
  being applied; reading only `uclamp_max_eff` would miss one that is about to be. Carry both.

The totals are intentionally not converted to deltas inside the hot path. A later analyzer can
calculate deltas for TIDs that persist across windows without making the observer read expensive
files for every thread twice per interval.

---

## 6. S1 validation — results

Run on the OnePlus 13 on 2026-08-22. Full numbers in
`data/2026-08-22/s1-observer-validation.txt`; the summary is here.

| gate | verdict | what it rests on |
|---|---|---|
| V1 zero performance writes | **PASS** | A/B/A and B/A/B, 165 s of 1 Hz sampling over ~60 nodes, perfd live |
| V2 lock and signals | **PASS after a fix** | exit 130 was being swallowed; see below |
| V3 top-app correctness | **PASS** | driven against two independent ground truths through five real app switches |
| V4 stat field offset | **PASS after a fix** | wrong CPU on ") " thread names; see below |
| V5 uclamp | **PASS** | observer matches a direct read on a guard-imposed 500 and on set 700 / 640 |
| V6 overhead | **PASS in the S1 regime** | clean at one busy core, contaminating at eight |

### The shell was the biggest finding

`/system/bin/sh` is mksh R59 and **`printf` is not a builtin** — it is `/system/bin/printf`, and a
fork costs 6.4 ms on this device. The scaffold called it once per scanned thread, so one snapshot of
a 135-thread app cost 960 ms and the nominal 250 ms cadence actually ran at 1.4 s. Nothing in a
per-thread path may fork. `echo` is a builtin and the same snapshot costs 20 ms.

### Six defects, all reverse-verified

1. per-thread `printf` in the snapshot loop — 48× the necessary cost. Restoring that one line takes
   median `wall_ms` from 260 back to 760.
2. enrichment forked a subshell, two awks and a `tr` per ranked thread, 19 ms each.
3. the window timestamp was taken before the snapshot, so `wall_ms` excluded the scan and inflated
   every `runtime_pct`.
4. a fixed `sleep` made the real cadence *interval + scan*, never the interval.
5. `trap cleanup EXIT` replaced the signal handler's `exit 130` with `0`, because mksh takes the
   status of the EXIT trap's last command. A caller could not tell an aborted trace from a finished
   one.
6. `${line#*) }` — shortest match — returned a wrong, plausible-looking CPU for threads whose name
   contains `") "`. Two such threads (`AdWorker(NG) #1`) were live during the session. It reported
   `processor = -1` for them, and a deliberately re-broken build reported CPU **17** on an
   eight-core device, in 20 of 20 windows.

### Measured limits — read before trusting a trace

The observer costs **45 % of one core** at 250 ms / top 5 while scanning ~516 top-app threads
(62 % before the enrichment was batched into one awk). Counted as `utime+stime+cutime+cstime`, since
two thirds of it is forked children and `schedstat` does not see them.

| regime | A vs B | verdict |
|---|---|---|
| one busy core, n=6 | 6400 vs 6390 ms, −0.16 %, t = −0.63 | no detectable contamination |
| eight busy cores, n=10 | 18300 vs 19987 ms, **+9.22 %, t = 2.86** | real contamination |

0.45–0.62 core against eight cores predicts 5.6–7.8 %, and +9.2 % was measured. The self-cost and
the contamination agree, which is what makes both numbers believable.

**This tool may not support any throughput conclusion under a saturating load.** It is valid for the
one-to-two busy core regime S1 is about.

### V3, completed against real app switches

Five launches (Chrome, Clock, Calculator, Settings, Chrome) inside one 46 s trace, with the kernel
cpuset sampled independently at 250 ms alongside.

- ground truth saw **7** distinct app-UID TGID sets; the observer reported **6** of them and emitted
  6 `top_app_changed` events. The one it missed existed for less than a single window. Transitions
  shorter than the interval are collapsed, which is sampling, not a defect — but a consumer counting
  transitions must know it.
- no window was ever joined across a transition.
- `system_server` (uid 1000) sat in `top-app/cgroup.procs` for the entire session and never entered
  the observer's TGID set.

Two facts about `top-app` on this ROM came out of the same trace, and both constrain what the tool
means:

1. **It is not one app.** Up to seven application processes were in it simultaneously. "The dominant
   thread of the foreground app" is really "the dominant thread of the top-app cpuset".
2. **A system-UID foreground app is invisible.** Launching Settings (uid 1000) leaves the observer
   with only the residual app-UID processes.

## 7. S1 — what the traces say

Ten traces, 250 ms / top 10, each in both module states where the comparison is meaningful. Numbers
and method in `data/2026-08-22/s1-dominant-thread-traces.txt`.

### 1. Are real windows dominated by one or two threads? Mostly no.

| trace | rank1 share of window CPU | top-2 share | windows where top-2 ≥ 80 % |
|---|---|---|---|
| app launch | 50 % | 85 % | 52 % |
| app switch | 44 % | 68 % | 30 % |
| scroll | 30–34 % | 54–57 % | 24–27 % |
| game (title screen) | 23 % | 39 % | **0 of 462** |

App launch is the only real workload that matches the premise. The game runs a median of **21 busy
threads per window** and never once put 80 % of a window into two threads.

### 2. Is the dominant TID stable? Only in steady state.

Game: 94–96 % consecutive-window persistence, the same render thread leading 224 of 231 windows.
Launch and switch: 20–31 % persistence and 11–16 distinct leaders. **A controller that picks the
busiest thread would be chasing a different thread four windows out of five, during exactly the
transitions where responsiveness matters.**

### 3. Do dominant threads run on CPU 6–7? Almost never.

Prime share of the rank1 thread: scroll 0 %, wake 0 %, game 1–2 %, launch 9 %, switch 10 %. The
game's dominant render thread ended on CPU 2–5 in 216 of 231 windows.

### 4. The controlled pair — changing the sleep/wake pattern was enough to flip the cluster

Same uid, same cgroup, same module state, back to back; the only difference is whether the thread
ever sleeps. Changing only the sleep/wake pattern was sufficient to flip placement in this
controlled pair. That names the input, not the mechanism: wake, enqueue, util history, placement
decision and scheduler state all move together downstream of it, and a 250 ms sampler cannot say
which of them carries the effect.

| worker | duty | prime share | runq_wait median | p90 | max |
|---|---|---|---|---|---|
| continuous | 100 % | **100 %** | 0.000 ms | 0.093 | 0.457 |
| wake-heavy, module on | ~38 % @ 40 Hz | **0 %** | 0.480 ms | 2.371 | 9.038 |
| wake-heavy, module off | ~38 % @ 40 Hz | **0 %** | 0.369 ms | 2.225 | 6.391 |

**This is the S1 result.** The regime sections 42–43 left open is not limited by a frequency
ceiling, because in it the dominant thread is not on the cores the ceiling governs at all. And the
shipped module does not change that: the wake-heavy worker is identical with it on and off.

### 5. Does the oplus clamp explain the placement? Not established.

With the module on, `uclamp_max != 1024` appears in **0 of 705** reported rank1 rows — the 4 Hz
`uclampset -a -M 1024` erases the clamp, so no module-on trace can say anything about it.

With the module off the clamp appears on the 100 %-duty worker, and the two runs disagree:

```text
compute-off, within-run   uclamp 1024 (n=47): prime 98 %, runq 0.047 ms
                          uclamp  346 (n=69): prime  3 %, runq 0.414 ms
attribution run           uclamp 1024 (n=69): prime 100 %, runq 0.030 ms
                          uclamp  346 (n=15): prime 100 %, runq 0.063 ms
```

Near-perfect association in one run, none in the other. The visible difference is that the second
run's thread never migrated at all — consistent with V5's finding that the effective clamp is
latched at enqueue, so a thread that is never re-placed keeps its core. The A/B/A probe meant to
settle it had no headroom, because its phase A was already at 100 % prime.

**One observation, not reproduced. No S2 arm may be justified on it.** Settling it needs
wake/placement events, not 250 ms sampling.

The wake-heavy worker was **never clamped in either module state**, 0 of 230 windows. Whatever keeps
it off the prime cluster, it is not the guard.

### 6. Which thread-selection rule is robust enough for a controller?

None of load, name, or identity on its own. Load picks a thread that changes four windows out of
five during launch and switch. Name matching is already banned in this repository for good reason.
The only stable target found is a steady-state renderer, which is also the case that needs the least
help. **S1's honest answer is closer to "thread identity is too unstable for targeted affinity"
during transitions** — which, per the section this document opened with, is a successful S1.

### What the traces do not cover

The game trace is a title screen, not gameplay: entering resumed a 48.5 GB asset download over
mobile data and was stopped. `top-app` is a seven-process set, not one app. System-UID foreground
apps are invisible. One session, one device, one trace per cell except the synthetic pair.

## 8. S2 handoff — what Claude or the next implementation should build

Do **not** add boost logic to this observer.

Once S1 is validated, make a separate bounded experiment harness with explicit arms:

```text
A  stock / module-off baseline
B  limiter repair only
C  B + bounded task uclamp.min
D  B + broader CPU eligibility (cpuset)
E  B + targeted affinity
```

Suggested initial burst durations:

```text
100 ms
250 ms
500 ms
```

Primary metrics should change from 150 s aggregate work to latency-oriented measurements:

```text
p50 completion latency
p95 completion latency
wake-to-complete latency
runqueue wait
prime residency / placement
migration behaviour
junction peak / thermal burden
```

Only after those arms establish that placement/boost matters should P6 ceiling be reintroduced as a
variable in the one/two-busy-core regime.

### What S1 changed about this list

- **C (bounded task uclamp.min) is the arm the evidence points at.** The wake-heavy worker is never
  clamped and never reaches the prime cluster; raising the floor is the only one of these levers
  that acts on that. B (limiter repair) demonstrably does nothing for it — measured, module on
  versus off, identical.
- **E (targeted affinity) is the weakest arm.** The dominant TID rotates every one to two windows
  during launch and app switch, so there is often no stable target to aim at.
- **Whatever the arms are, the metric cannot come from this observer under load.** V6 puts it at
  45 % of one core and a measured +9.2 % contamination at eight busy cores.
- **Instrumentation gap first.** Both open questions — why the clamp moved placement in one run and
  not another, and what a boost would do at a wakeup — are about events between samples. A 250 ms
  sampler cannot see them. S2 should start by adding a wake/placement tracer, not by adding a lever.

---

## 9. Product architecture implication

This observer is deliberately designed as the future read-only half of the App's controller core:

```text
capability_probe
      ↓
workload_observer   <- this S1 work
      ↓
classifier
      ↓
policy resolver
      ↓
single writer       <- not part of S1
      ↓
read-back verifier
```

Keeping observation and mutation separate now makes it possible for the future Android App to offer
a diagnostic-only mode on unknown firmware/device combinations without granting the controller
permission to tune them.
