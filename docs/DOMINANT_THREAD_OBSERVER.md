# S1 dominant-thread observer

Status: **scaffold / device validation required**  
Branch: `feature/dominant-thread-observer`  
Tool: `tools/dominant-thread-observer.sh`

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
/dev/cpuset/top-app/tasks
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
/dev/cpuset/top-app/tasks
```

For each entry the observer reads `Tgid` and `Uid` from `/proc/<tid>/status`, keeps application
UIDs (`uid >= 10000`), then enumerates `/proc/<tgid>/task/*`.

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
FIELDS|THREAD|seq|rank|tgid|tid|uid|comm|runtime_ms|runtime_pct|runq_wait_ms|slices|cpu_start|cpu_end|allowed|uclamp_min|uclamp_max|migrations_total|vol_ctx_total|nonvol_ctx_total
```

Each `THREAD` row is one dominant thread in that window.

Important interpretation:

- `runtime_ms` / `runtime_pct`: CPU execution delivered inside the observed window;
- `runq_wait_ms`: time runnable but waiting according to `schedstat`;
- `slices`: interval delta of scheduler run periods / timeslices;
- `cpu_start`, `cpu_end`: CPUs reported at the two snapshots; **not** a migration count;
- `migrations_total`: cumulative scheduler migration counter at enrichment time;
- context-switch fields are cumulative totals at enrichment time;
- `uclamp_*` and `allowed` are current state at enrichment time.

The totals are intentionally not converted to deltas inside the hot path. A later analyzer can
calculate deltas for TIDs that persist across windows without making the observer read expensive
files for every thread twice per interval.

---

## 6. S1 validation checklist

Before this tool is allowed to support a scheduling conclusion, validate all of the following on the
OnePlus 13.

### V1 — zero performance writes

Run a before/after snapshot of the nodes already tracked by the repository and confirm the observer
changes none of them.

At minimum:

```text
/sys/kernel/msm_performance/parameters/cpu_max_freq
/sys/module/cpufreq_bouncing/parameters/enable
/dev/cpuctl/top-app/cpu.uclamp.min (if present)
/dev/cpuctl/top-app/cpu.uclamp.max (if present)
```

The observer itself must not attempt to “restore” these. It never owned them.

### V2 — lock and signal behaviour

Verify:

1. second observer refuses to start;
2. `TERM` ends the first observer rather than merely running cleanup and continuing;
3. lock/work directory disappears;
4. no child process survives.

### V3 — top-app correctness

Open several ordinary apps and switch between them. Confirm:

- reported TGIDs correspond to the kernel top-app group;
- transitions produce `top_app_changed` events;
- system processes are filtered by UID rather than names.

Do not publish raw app/thread names from private daily-use traces without redaction.

### V4 — stat field correctness

Cross-check `cpu_start/cpu_end` for one known pinned test thread against an independent read of
`/proc/<tid>/stat` / `taskset` behaviour. A field-offset error here would silently poison every later
placement conclusion.

### V5 — uclamp correctness

Create a controlled app-UID worker using the repository's existing trigger methodology and confirm
the observer reports the same `uclamp.max` value as a direct `/proc/<tid>/sched` read.

### V6 — overhead

Measure the observer against an otherwise identical workload:

```text
A: workload only
B: workload + observer @ 250 ms / top 5
```

If the performance difference is material, increase the interval or reduce enrichment. The observer
must be cheaper than the effects it is intended to measure.

---

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
