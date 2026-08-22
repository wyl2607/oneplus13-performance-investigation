# S1 dominant-thread observer

Status: **V1–V6 validated on device 2026-08-22; S1 collection not started**  
Branch: `feature/dominant-thread-observer`  
Tool: `tools/dominant-thread-observer.sh`  
Evidence: `data/2026-08-22/s1-observer-validation.txt`

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
WINDOW|seq=N|t_cs=...|wall_ms=...|tgids=...
```

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
| V3 top-app correctness | **PARTIAL** | UID filter and transition path proven; a real app switch was not run |
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

### What V3 still owes

The device was locked (`deviceLocked=1`) for the whole session, so app launch and app switching
could not be driven. What is proven: TGIDs come from the kernel cpuset, `system_server` (uid 1000)
sat in `top-app/cgroup.procs` throughout and never entered the observer's TGID set, and
`top_app_changed` fires exactly once on entry and once on exit when cpuset membership really
changes. What is not proven: whether Android's own app-to-app transition produces one clean event or
a flapping sequence.

## 7. What S1 should tell us

After validation, collect short traces from at least these classes:

```text
app launch / cold-ish start
continuous scroll
UI animation / app switch
wake-heavy synthetic worker
continuous compute worker
one representative game
```

Questions:

1. Are real foreground workloads dominated by one or two threads in 250 ms windows?
2. Do the dominant TIDs remain stable, or rotate through worker pools?
3. How often do dominant threads end a window on CPUs 6–7 versus 0–5?
4. Are high `runq_wait` windows associated with mid-cluster placement or clamp state?
5. Do sleeping/waking workloads show the task-overload clamp pattern more clearly than continuous
   workers, as previous causal experiments predict?
6. Which thread-selection rule is robust enough for a controller: load, name/class, wake density,
   or a combination?

S1 is successful even if the answer is “thread identity is too unstable for targeted affinity.” A
negative result prevents us from building a fragile controller.

---

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
