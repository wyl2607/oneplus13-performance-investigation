[English](README.md) · [简体中文](README.zh-CN.md)

# OnePlus 13 — performance investigation

An evidence-based investigation into unexpectedly low sustained CPU performance on the
OnePlus 13 / Snapdragon 8 Elite (SM8750): OPLUS `task_overload`, `uclamp.max`, scheduler
placement, `cpufreq_bouncing`, and thermal behaviour.

Everything here is measured on-device over ADB. No inferred numbers. Wrong turns are kept.

---

## Is my OnePlus 13 broken?

**Almost certainly not.** The hardware is fine. The scheduler is being told your work does not
need the fast cores.

Your phone has two prime cores (CPU6/CPU7, 4.32 GHz) and six mid cores (CPU0–5, 3.53 GHz). An
OPLUS kernel module, **`oplus_bsp_task_overload`**, watches for app threads that stay busy on
the prime cores, decides they are "abnormal", and caps `uclamp.max` — the value the scheduler
uses to judge how much CPU a task needs. The cap is low enough that the task fits on a mid
core, so Linux moves it there and, working exactly as designed, never brings it back.

On the reference device, lifting **only that cap** and changing nothing else:

| | Stock | uclamp lifted |
|---|---|---|
| Geekbench 7 single-core | 934 | **2126** |
| Geekbench 7 multi-core | 6017 | **8386** |
| Time the benchmark spent on prime cores | 8.0% | **59.5%** |

Scaled to its rated clock the device measured *slightly faster* than a healthy comparison
unit. Nothing is defective, nothing needs reflashing.

**It is not thermal.** CPU temperature during the clamped run was 40–50 °C against a 105 °C
trip point, `Thermal Status` stayed `0`, and all 20 cooling devices read `cur_state=0`.

**What it does and does not affect** — measured where stated, flagged where not:

| Workload | Affected? |
|---|---|
| App launches, UI, scrolling, short bursts | **No** — a cold start finishes before the guard engages (measured) |
| Benchmarks, thread pools, event loops | **Yes** — up to 2.3x; the easiest reproducer, which is why this was found there |
| A single long-running compute loop (`gzip`, a compile job's inner process) | **No** — clamped, but *not displaced*; 1.4% and not statistically distinguishable (measured, [section 31](docs/DATA.md)) |
| Video export, emulators, on-device inference | **Unknown** — depends on whether their hot thread sleeps; see below |
| Games | **Unknown** — OPLUS routes games through a separate `game_opt` path; untested |

**What decides it is whether the task sleeps.** Displacement happens at wakeup: the scheduler
picks a CPU when a task wakes, and that is where the clamped utilisation is weighed against
cluster capacity. A task that never sleeps keeps the prime core it was already on and loses
only frequency; a task that wakes repeatedly is re-placed onto a mid core and never returns.
Measured directly — identical work, differing only in sleeping, gave 100% prime residency after
clamping versus 0% ([section 32](docs/DATA.md)). So the cost falls hardest on interactive and
frame-driven work, and lightest on batch compute.

Geekbench is not the problem and not the target. It is simply the cleanest way to trigger a
vendor scheduler policy that also applies to real sustained work.

## Can I check my own phone?

Yes, read-only, root required (reading another process's scheduler state is privileged):

```sh
adb push tools/diagnose.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/diagnose.sh <package>'
```

Run it **while the app is under sustained CPU load**. It writes nothing — it reads `/proc`
and `/sys` and prints what it found, including whether the module exists on your device at
all. See [docs/FOR-USERS.md](docs/FOR-USERS.md) for how to read the output.

**Please contribute a result**, especially from a non-OnePlus-13 OPLUS device — the single
biggest gap in this project is that it is one device.

## How do I fix it?

Read [`mitigation/`](mitigation/) — and read the thermal warning first.

Diagnosis is read-only and safe. Mitigation is not. When the clamp was lifted, CPU junction
temperature ran at **87 °C p95, peaking at 95 °C**, while the phone's outside surface moved
from 35.0 to 36.1 °C. Android's thermal framework escalates on *skin* temperature, so nothing
in the OS would have intervened. **You cannot feel this with your hand.**

That is also the honest argument *for* the module: a genuinely runaway thread can sit at 87 °C
inside this SoC indefinitely without the phone ever feeling warm. What the guard cannot do is
tell a runaway bug apart from a user who deliberately asked for sustained compute.

So this project does not ship a one-click "unlock full power" toggle, and you should be wary
of anything that does.

---

# For researchers

The rest of this document is the technical record.

## TL;DR — the original CFB finding, which still stands

An OPLUS kernel module called **`cpufreq_bouncing`** (CFB) clamps the CPU via `freq_qos`
after **50 ms** of sustained load:

| Cluster | CPUs | Hardware max | CFB `limit_freq` | Ratio |
|---|---|---|---|---|
| `policy0` (mid) | 0–5 | 3 532 800 | **2 400 000** | 68% |
| `policy6` (prime) | 6–7 | 4 320 000 | **2 438 400** | **56.4%** |

This is *not* thermal throttling. It engages at ~50 °C junction with the Android thermal
framework reporting `Thermal Status: 0` and every CPU cooling device at `cur_state=0`.

Because CFB enforces through `freq_qos`, and cpufreq takes the **minimum** of all QoS
requests, writing `scaling_max_freq` as root has no effect — a very common source of
confusion when diagnosing this.

> **The tune's measured +30% may work through a mechanism this repository never knew about.**
> The clamp value is `floor(0.6 × 1024 × prime_cur_freq / 4 320 000)`. Stock, CFB holds the
> prime cluster at 2 438 400, which yields a clamp of 346. Tuned, the ceiling holds it at
> 3 283 200, which yields 466. That ratio is **+34.7%**, against a measured tune gain of
> **+30.3%** — a closer fit than the mid-cluster ceiling change (+21.6%) that was assumed to be
> responsible. The workload never runs on the prime cluster, but the prime cluster's clock
> decides how much of the mid cluster it is allowed to use. Not proven; consistent with every
> number so far.

---

## Read this before the rest: what removing the clamp is actually worth

Lifting the clamp is worth **+30% single-core in Geekbench 7**, reproducible to within 2.4%.
Every other scenario measured so far shows **no benefit at all**.

| Scenario | Benefit | Basis |
|---|---|---|
| Geekbench 7 single-core | **+30%** (947 → 1234) | three runs, 2.4% spread |
| Geekbench 7 multi-core | +19% (5222 → 6218) | three runs, 11.5% spread |
| *(neither figure is a healthy baseline — see the correction below)* | | |
| **App cold start** | **none** | Settings 265 vs 276 ms, Maps 200 vs 203 ms — inside noise |
| **Sustained all-core** | **none** | landing frequency is set by the thermal loop, not the ceiling |
| **GPU-bound work** | **none** | prime idles at 1 017 600 during GPU load; the ceiling is never approached |
| Geekbench 7 OpenCL | −0.68% | noise |

The reasoning that app launches *should* benefit is sound and was wrong. CFB's threshold is
50 ms and a cold start is 500–2000 ms of dense CPU work, so the limiter certainly engages —
it simply is not the bottleneck. Cold start is dominated by I/O, zygote fork, class loading
and binder, and much of it runs on the mid cluster rather than the heavily clamped prime.

**The honest description of this tune is: it removes a vendor clamp on sustained
single-threaded compute *that sleeps often enough to be re-placed*.** That covers benchmarks,
thread pools and event-driven work. It does **not** cover a single long-running compute loop:
`gzip -9` under an app uid was clamped exactly as predicted and still finished within 1.4% of
its unclamped time, because the clamp never moved it off the prime cores. The earlier version
of this section listed compilation as "plausibly" affected; that prediction was measured and
did not hold ([section 31](docs/DATA.md)). It is not a general "performance mode", and the
everyday responsiveness of the phone does not change.

The single largest measured lever in this entire investigation was not the CPU tune at all —
it was **active cooling**, worth +44% sustained clock under a 15-minute all-core load, because
Android's thermal framework governs on skin temperature rather than junction. See
[DATA.md section 18](docs/DATA.md).

---

## Device under test

| | |
|---|---|
| Model | CPH2653 (OnePlus 13), device `OP5D55L1` |
| Build | `CPH2653_16.0.9.401` · Android 16 (API 36) |
| Fingerprint | `OnePlus/CPH2653EEA/OP5D55L1:16/BP2A.250605.015/V.R4T3...` |
| Kernel | `6.6.118-android15-8` |
| SoC | Qualcomm SM8750 (`sun`), Snapdragon 8 Elite |
| Root | Magisk 30.7 |
| CFB module scmversion | `g708cd7576750` |

---

## Root cause

Stock `/sys/module/cpufreq_bouncing/parameters/config`:

```
clus 0 first_cpu 0 ctl 1        clus 1 first_cpu 6 ctl 1
limit_freq: 2400000             limit_freq: 2438400
limit_level: 10                 limit_level: 6
limit_thres: 50 ms              limit_thres: 50 ms
max_freq: 3532800 15            max_freq: 4320000 15
cur_level: 15                   cur_level: 15

global: enable=1  freq_qos_check=Y  decay=80  sleep_range_ms=20,30
```

`limit_level` is an index into the cluster's OPP table. For `policy6`:

```
idx    0       1       2       3       4       5       6  <-- limit_level
kHz  1017600 1209600 1401600 1689600 1958400 2246400 2438400 ...  4320000 (idx 15)
```

Under sustained load the measured clamp matches `limit_freq` **exactly, to the kHz**:

```
Screen ON, single thread pinned to cpu7, stock config
 t+0s  cur=1017600  max=4320000
 t+1s  cur=2438400  max=2438400   <-- clamped within 1 s
 ...
 t+16s cur=2438400  max=2438400
```

### Kernel stack-trace proof

`/proc/oplus_freqreq_monitor/fqm_dump` logs every `freq_qos` request with its call stack:

```
req, idx, ts, cluster, pid, ..., max, ..., comm, utc, stack
41848, 18, 1858888, 1, 136, 0, 2438400, 0, 2438400, 1, kworker/5:1H, ...,
   freq_qos_update_request<-cb_do_boundary_change_work [cpufreq_bouncing]<-process_scheduled_works
```

Setting `enable=0` correctly releases the request (`max` → `2147483647`) via
`enable_store [cpufreq_bouncing]`.

### CFB is one of at least five `freq_qos` requesters

An idle 5-second capture of `fqm_dump` already shows five distinct sources contending for the
same `min()`. Disabling CFB removes exactly one of them:

| `comm` | Kernel module | Role |
|---|---|---|
| `UrccWorker` | `msm_performance` | screen-state power policy (normal, see METHODOLOGY trap 2) |
| `gameSceneLooper` | `oplus_bsp_game_opt` | OPLUS game optimiser — **not previously characterised** |
| `thermal-engine-` | `qti_cpufreq_cdev` | Android/QTI thermal cooling device |
| `kworker/N:1H` | `cpufreq_bouncing` | the clamp this repository documents |
| — | `sched_walt` | WALT governor |

`/proc/game_opt` exposes the game optimiser's controls, including `cpu_max_freq` (reads
`2147483647` = not capping, when idle), `dsu_freq`, `disable_cpufreq_limit`,
`skip_gameself_setaffinity`, and a node named **`fake_cpu7_cpuinfo_max_freq`** whose function
is to falsify CPU7's advertised ceiling. It reads `0` on this unit, which is how we know the
`4 320 000` figure quoted throughout this repository is genuine rather than synthesised.

Separately, the cpuset `oiface_fg` has `cpus=3-6` — **CPU7 is excluded from it**, while
`oiface_fg+` has `cpus=3-7`. Whether any benchmark thread is ever placed in `oiface_fg` is
untested and is one of the candidate explanations for the residual above.

---

## Ruled out

| Hypothesis | Verdict | Evidence |
|---|---|---|
| Thermal throttling | **No** | `Thermal Status: 0`; all 20 CPU cooling devices `cur_state=0`; clamp active at 50 °C vs 105 °C trip point |
| Permanently damaged OPP table | **No** | `time_in_state` shows 4 320 000 residency accumulating since boot |
| Magisk / LSPosed modules | **No** | Both limiters are stock OPLUS kernel/vendor components |
| `UrccWorker` / `msm_performance` cap | **No — normal** | The 1 996 800 / 2 649 600 cap is the **screen-off** power policy. Returns to full hardware max on screen-on. See METHODOLOGY.md |
| Botched CN→OOS conversion | **No** | `boot`, `vendor`, `odm` fingerprints all identical incremental; `my_product` (2.6 GB) correctly populated with EEA content; no CFB reference in device tree or any vendor config |

The last row matters: **reflashing the same OOS build cannot change this.** The CFB defaults
are compiled into the kernel module, which ships inside a `boot` image whose fingerprint is
already identical to `vendor` and `odm`.

---

## Thermal characterization

Worst case: a pure-ALU shell busy loop (hotter than Geekbench). Junction sensor is
`thermal_zone28` (`cpu-1-1-1` = cpu7). Hardware trip point is 105 °C.

### Single thread pinned to cpu7

| `scaling_max_freq` ceiling | Steady junction | Peak | Shell | Margin to 105 °C |
|---|---|---|---|---|
| 2 438 400 (stock CFB) | 51 °C | — | 31 °C | 54 °C |
| 2 841 600 | 62 °C | 64 °C | 33 °C | 43 °C |
| **3 283 200** | **73 °C** | 74 °C | 33 °C | **32 °C** |
| 3 513 600 | 80 °C | 82 °C | 33 °C | 25 °C |
| unlimited (CFB off) | ~88 °C avg, oscillating | 101 °C | 32 °C | 4 °C |

With CFB off and no ceiling, `scaling_max_freq` self-modulates between 3 283 200 and
4 320 000 — the Qualcomm LMH/DCVS loop remains active and holds the core below the trip
point. Disabling CFB does **not** leave the SoC unprotected.

### All-core (8 threads), 40 s

| Ceilings (p0 / p6) | Landing freq | Junction at 40 s | Shell | Result |
|---|---|---|---|---|
| 2 918 400 / 3 283 200 | p6 → 2 841 600 | 89 °C | 34 °C | no abort, `Thermal Status: 0` |
| 2 745 600 / 3 072 000 | p6 → 2 841 600 | 89 °C | 35 °C | no abort, `Thermal Status: 0` |

**Both configurations converge to the same point at 40 s.** Under all-core load the landing
frequency is set by the thermal/power loop, not by the ceiling — so lowering the ceiling
below 3 283 200 buys nothing thermally and only costs single-thread performance.

> **These 40 s figures are transients, not steady state.** A 15-minute run
> ([DATA.md section 17](docs/DATA.md)) shows the prime cluster continuing down to
> **1 689 600** — below CFB's own 2 438 400 clamp — with Android's thermal framework
> escalating to status 2 and the junction settling *lower*, at 69 °C. Anything in this
> repository derived from a 40 s window describes burst behaviour only.

---

## Mitigation

Two facts shape the fix:

1. Once CFB is disabled, a userspace `scaling_max_freq` write **does** bind (it becomes the
   minimum QoS request). This gives a precise, predictable ceiling without needing to
   reverse-engineer CFB's `config` write format.
2. **CFB is re-enabled by the system on every screen-on/wake event.** Verified: it stays at
   `0` for 60 s with the screen on, survives screen-off, and flips back to `1` on wake. A
   one-shot boot script is therefore not sufficient — a watchdog is required.

`mitigation/oneplus13_cfb_tune.sh` implements this. See [mitigation/README.md](mitigation/README.md) for the
tradeoffs — it does permanently disable a vendor limiter, which is a real decision, not a
free win.

Screen-off power saving is preserved: URCC's screen-off cap (1 996 800 / 2 649 600) is a
separate, lower QoS request that still wins via `min()`.

### Validated against Geekbench 7

Applied for one boot (`cfb_enable=0`, `p0max=2918400`, `p6max=3283200`, screen on), then
Geekbench 7 run on the device:

| | Stock (4 runs) | Tuned | Change |
|---|---|---|---|
| Single-core | 891 / 1052 / 911 / 935 (~950) | **1253** | **+32%** |
| Multi-core | 5279 / 5344 / 5178 / 5086 (~5220) | **5945** | **+14%** |

The single-core result was predicted before the run from the clock ratio alone:

```
950 × (3 283 200 / 2 438 400) = 950 × 1.347 = 1280   predicted
                                              1253   measured    (2.1% error)
```

Matching the predicted *magnitude*, not merely getting faster, is what closes the causal
chain: root cause → mechanism → intervention → quantitative prediction → measurement.

Multi-core gaining only +14% is consistent with the all-core measurements above: LMH pulls
the prime cluster to 2 841 600 regardless of ceiling, mid cores run 2 745 600–2 918 400
against a stock 2 400 000, so pure clock scaling predicts ~+17%. The shortfall to +14% is
expected — multi-core is more memory- and DSU-bound than the single-threaded ALU loop used
for the thermal characterisation.

Both figures are Geekbench 7 and are compared only against Geekbench 7 results from the same
device. See the correction below.

---

## Open questions — help wanted

**1. Who writes `uclamp.max = 466` onto the benchmark's worker threads?** — *answers the
residual; see [DATA.md section 22](docs/DATA.md)*

The residual is resolved and it is not IPC. A 437 s trace shows Geekbench's single-core
workload running on the **mid** cluster in 95.8% of true single-threaded samples, with both
prime cores idling at 1 017 600 for 97.8% of them — while `policy6 scaling_max_freq` sat
unmoved at 3 283 200, the cpuset was `/top-app` with `cpus_allowed=0-7`, `Thermal Status` was
`NONE`, and every cooling device read 0. The prime cores were available and simply never used.

The worker thread carried `uclamp.max = effective uclamp.max = 466` for the whole run,
reverting to 1024 the moment it ended. With `cpu_capacity` at **792** for mid and **1024** for
prime, a task clamped to 466 fits inside one mid core, so the scheduler never has cause to
promote it — and the same clamp holds the mid cores below their own ceiling (2 555 MHz average
against 2 918 400 available).

**The source is identified: `oplus_bsp_task_overload`.** The module exports `set_uclamp_max`,
knows the cluster topology (`golden_cpu`, `goplus_cpu`, `max_cluster_id`), exposes
`/proc/task_overload/skip_goplus_enabled` — *skip gold-plus*, i.e. the prime cluster — and
keeps its own table at `/proc/task_overload/abnormal_task` whose columns are
`pid uid limit_flag comm date temp freq`. That table contains:

```
30423  10xxx  466  pool-5-thread-1  2026-08-13 17:33:55  0  3283200
18846  10xxx  466  pool-7-thread-1  2026-08-13 17:48:50  0  3283200
```

TID 30423 is the exact thread the trace recorded at `uclamp.max = 466`. Other rows show
clamps of 346 / 376 / 436 on ordinary app threads, so this is a general runaway-thread guard
rather than benchmark detection. `/proc/oplus_qos_sched/qos_task_uclamp` reads empty
throughout and is **not** implicated — the earlier suspicion of it was wrong.

Still unknown: the trigger condition and what selects the specific limit value. See
[DATA.md section 23](docs/DATA.md) for the confidence grading and the kprobe setup for the
confirming run.

This finding also demotes the prime-cluster ceiling in `mitigation/`: the +30% it measured is most
plausibly the *mid* cluster going from 2 400 000 to 2 918 400, not anything the prime pair did.

**2. Is `limit_level 6` stock for CPH2653, or specific to this unit's build?**

Nothing on this device can answer that. It needs one data point from another OnePlus 13.
If you have one, please run [`tools/collect-report.sh`](tools/collect-report.sh)
(read-only, no root changes, no PII) and open an issue with the output.

**3. A same-version GB7 reference that is verifiable.**

The 2 681 / 8 846 figure underpinning question 1 is user-supplied and could not be fetched
programmatically. A GB7 result from another OnePlus 13, captured alongside
`tools/collect-report.sh` output, would put question 1 on firmer ground.

### Correction, twice — the "second factor" is back, and is the main open question

This section has now been wrong in both directions. The current position:

**A second, non-frequency bottleneck almost certainly exists.**

The first revision argued for one by comparing this device's Geekbench **7** scores against
Geekbench **6** reference figures. That comparison was invalid and the argument was withdrawn.

The withdrawal then over-corrected. It cited [Signal65's GB7 analysis](https://signal65.com/research/geekbench-7-analysis-and-early-results/)
for the fact that GB7 single-core scores come in lower than GB6 on identical hardware — and
took the *direction* of that effect while never checking its *magnitude*. Signal65's paired
measurements are:

| CPU | GB7 vs GB6 single-core |
|---|---|
| Snapdragon X2 Elite | −15% |
| Apple M5 | −14% |
| Intel Core Ultra X9 388H | −10% |
| AMD Ryzen AI 9 465 | −9% |

A 9–15% recalibration was used to explain away a **2.2× discrepancy**. It cannot. Applying
the largest observed drop to the OnePlus 13's ~3 000 GB6 single-core gives an expected GB7
figure of roughly **2 550–2 730**. Note also that GB7 kept GB6's baseline *score* of 2 500 and
only moved the baseline *machine* (Dell Precision 3460 / i7-12700 → Lenovo Legion /
Ryzen 7 7700), which bounds the rescale to about that size by construction.

A Geekbench 7.0.0 result for a OnePlus 13 CPH2655 at **2 681 / 8 846** sits squarely in that
predicted range. (Reported at `browser.geekbench.com/v7/cpu/116261`; the Geekbench Browser
returns HTTP 403 to automated fetches, so it is cited here as user-supplied and is not
independently verified in this repository.)

#### The residual is near-constant across two different ceilings

Against a 2 681 reference at 4 320 000:

| State | Prime ceiling | Ratio to rated | Clock-ratio prediction | Measured | Residual |
|---|---|---|---|---|---|
| Stock CFB | 2 438 400 | 0.564 | 1 513 | 947 | **62.6%** |
| Tuned | 3 283 200 | 0.760 | 2 038 | 1 234 | **60.6%** |

Two different clamp levels, essentially the same residual factor of ~0.61. A residual that
does not move with clock is a **per-cycle** loss, not a duty-cycle one — which points at
DSU/LLC clock, DDR, or the benchmark thread not actually being resident on a prime core, and
away from anything that would show up as a low `scaling_cur_freq`.

This also explains why [DATA.md section 10](docs/DATA.md)'s within-device prediction
validated to 2.1%: a constant multiplicative factor cancels in a ratio. **Ratio agreement was
mistaken for absolute-level agreement.** Both facts are true simultaneously — clock scaling
within this device is clean, and the absolute level is depressed by something else.

#### Consequence for the numbers quoted above

`3 283 200` is **not** "full speed" and must never be described as such. `cpuinfo_max_freq` is
`4 320 000` for the prime pair and `3 532 800` for the mid cores, so the tune's ceilings are
deliberately conservative at **76%** and **83%** of rated. The tuned score of 1 234 is
therefore not a healthy baseline for this SoC — it is the score at a 76% clock ceiling, with
the unexplained ~0.61 factor still applied on top.

Investigation of the residual is tracked with the read-only tracing toolchain described in
[DATA.md section 21](docs/DATA.md).

---

## Reproducing

All scripts are read-only unless named `*-test`/`*-sweep`/`*-validate`. Every script that
modifies kernel state has an unconditional `restore` and a `trap`, and aborts on
junction > 95 °C or shell > 42 °C.

```bash
adb push experiments /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/experiments/collect-baseline.sh'
```

See [docs/METHODOLOGY.md](docs/METHODOLOGY.md) — including two measurement traps that
produced false conclusions before being caught.

## License

MIT. Findings are observations about a specific device; no warranty. Disabling a vendor
thermal/power limiter is at your own risk.
