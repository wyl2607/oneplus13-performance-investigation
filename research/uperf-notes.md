# R1 — Uperf architecture research notes

Repo: https://github.com/yc9559/uperf  
Reviewed branch: `master`  
Review scope: README + v3 configuration documentation + repository/package layout  
Status: **TEST / ADOPT IDEAS, DO NOT RUN CONCURRENTLY**

---

## 1. What Uperf is useful for in this project

Uperf is valuable to us mainly as an **architecture reference for a userspace performance controller**, not as a source of SM8750 tuning values.

Its public documentation describes a controller that recognizes user-visible contexts (touch, swipe, heavy load, app/window switching, rendering/jank, screen state), then maps those contexts to dynamic CPU/sysfs/scheduling policies. This is much closer to the long-term direction of `op13perf` than a static “performance mode” module.

Important: the current OnePlus 13 has vendor-specific control paths (`URCC/msm_performance`, `oplus_bsp_task_overload`, `cpufreq_bouncing`) that Uperf's older platform profiles do not model. Therefore copying its frequency/uclamp values would be wrong even if the conceptual framework is useful.

---

## 2. High-value idea #1: hint state machine instead of fixed modes

Uperf v3 documents a state machine around:

```text
idle
 touch
 trigger
 gesture
 switch
 junk
```

Transitions are driven by touch press/release, scroll/gesture detection, wake/window animation, rendering state and jank signals, with a maximum duration for each hint.

### Why this matters to op13perf

Our current levels (`DAILY`, `PERF`, `EXTREME`) describe **static ceilings**, but the workloads we care about are time-dependent:

- app launch needs a short burst;
- scrolling needs frame-critical latency for hundreds of ms, not an unlimited sustained boost;
- a sustained CPU task needs a perf/W optimum, not burst frequencies;
- thermal retreat needs its own slower control loop.

Proposed future split:

```text
fast loop (interaction)
    touch / launch / frame hint
    -> short uclamp / affinity / burst policy

slow loop (power + thermal)
    sustained load / temperature / thermal_area
    -> P6/P0 budget policy
```

Do **not** merge these loops into one `if temperature then frequency` state machine.

---

## 3. High-value idea #2: per-app and screen-off rules

Uperf's switcher requires both a default rule and an offscreen rule and can select a power profile per package.

Useful direction for us:

- preserve the existing rule that `op13perf` should not keep performance levers active while screen-off;
- later allow an explicit per-app override only when the generic classifier is insufficient (e.g. games using OPLUS `game_opt`);
- do not start with a huge package-name database; kernel `top-app` remains the source of truth for foreground ownership.

Potential future config shape:

```text
DEFAULT = adaptive
SCREEN_OFF = stock
GAME_PACKAGE = game-adaptive
BENCH_PACKAGE = test-only (optional, never default)
```

---

## 4. High-value idea #3: energy-model-based CPU controller

The Uperf v3 configuration documentation is especially relevant because it explicitly models each cluster with:

```text
efficiency
nr                # core count
typicalPower
typicalFreq
sweetFreq
plainFreq
freeFreq
```

It then describes a CPU controller that:

1. periodically samples per-core load;
2. calculates cluster performance demand;
3. chooses working frequencies using an energy model;
4. applies a system-wide power limit with short/long-term behavior analogous to PL2/PL1.

### Direct mapping to our current discovery

This matches what our full-core tests are already showing:

```text
P6 has only 2 cores
P0 has 6 cores
shared thermal/power budget
raising P6 can reduce aggregate work
```

So our next CPU work should explicitly estimate **marginal work per budget** for P6 vs P0 instead of treating `max_freq` as the optimization variable.

We should not copy Uperf's power model coefficients. We can, however, borrow the model structure and calibrate it from this exact OnePlus 13.

Candidate OP13 model fields:

```text
cluster
core_count
opp
single_worker_work
all_cluster_work
mixed_8core_work
thermal_area_80
energy_delta (if measurable)
```

The first practical version can be empirical (lookup table) rather than fitting watts immediately.

---

## 5. High-value idea #4: context-aware scheduler rules

Uperf's v3 `sched` module has contexts:

```text
bg
fg
idle
 touch
boost
```

and maps process/thread regex rules to:

- CPU affinity classes;
- scheduling-priority classes;
- different rules for each context.

### What to adopt

We should eventually distinguish at least:

```text
main/UI thread
RenderThread / frame-critical
wake/sleep-heavy worker
continuous compute
background
```

This is more promising than lifting `uclamp.max=1024` on every foreground thread forever.

### What NOT to copy blindly

Uperf documentation includes support for aggressive scheduling classes including real-time `SCHED_FIFO` priorities. That is **not** a starting point for op13perf. Misuse can starve system threads and create UI/audio/watchdog failures.

Our first scheduler experiments should stay with:

- CPU affinity/cpuset;
- uclamp min/max;
- normal scheduler class;
- short bounded hints.

No RT scheduling in the daily controller unless a separate, very strong justification is established.

---

## 6. High-value idea #5: SurfaceFlinger / rendering feedback

Uperf documents an `sfanalysis` path that can react to rendering start/end and jank, ending a boost early when rendering has stopped.

For Android 16 / ColorOS this cannot be assumed compatible, but the design principle is excellent:

> boost should be demand-driven and should terminate when the frame-critical work is over.

Possible OP13 paths to investigate later:

- `atrace`/ftrace-visible SurfaceFlinger scheduling events;
- FrameTimeline / SurfaceFlinger dumps that can be sampled without framework injection;
- top-app `RenderThread` discovery;
- game-specific frame signals if exposed by OPLUS.

The preferred approach is read-only observation first. Do not inject/hook SurfaceFlinger just to reproduce Uperf's old implementation.

---

## 7. Controller conflict risk

Uperf states that it can write arbitrary sysfs knobs and that it disables/replaces portions of other performance-boost frameworks.

That makes concurrent testing with `op13perf` invalid because both may alter:

```text
CPU frequency requests
cpuset
uclamp / scheduling behavior
GPU/devfreq knobs
boost behavior
```

Therefore:

```text
Uperf + op13perf simultaneous performance test = REJECT
```

If we ever install Uperf on the device for observation, the first task is to enumerate exactly which nodes it writes and run it only in an isolated test state with `op13perf` OFF.

---

## 8. Repository/audit limitation

The currently reviewed repository surface is primarily documentation, configuration templates and Magisk packaging. The native controller implementation is not exposed in an obvious top-level `src/` tree in the reviewed branch.

Therefore we can treat documented algorithms as design references, but should not claim to have source-audited implementation details that are not present in the visible tree.

Before reusing any binary component, verify provenance and exact node writes. For this project, reimplementing the small subset of useful ideas inside our auditable shell/native controller is preferable to adding an opaque second daemon.

---

## 9. Proposed OP13 experiments derived from Uperf

### U1 — two-loop controller prototype

Separate:

```text
interaction loop: 20–100 ms scale
thermal/power loop: 0.25–2 s scale
```

No behavior change first; only log inferred states.

### U2 — touch/interaction observation only

Detect input events and log:

```text
TOUCH_DOWN
SWIPE
TOUCH_UP
```

without applying boost. Verify false positives and CPU overhead.

### U3 — bounded UI uclamp hint

Only after U2 is reliable:

- short `uclamp.min` or affinity hint on frame-critical threads;
- hard max duration;
- compare frame-time/jank vs no hint;
- ensure sustained thermal metrics are unchanged.

### U4 — empirical cluster perf/W table

Use current full-core harness to build the empirical equivalent of Uperf's `sweetFreq` concept for P6 and P0.

This experiment has priority over interaction tuning because it directly continues our current data.

---

## 10. Decision

### ADOPT

- state-machine/hint architecture;
- separate transient and sustained control loops;
- empirical cluster sweet-spot model;
- context-aware affinity/uclamp abstraction;
- default + screen-off policy concept;
- bounded boost duration.

### TEST

- touch/gesture signal acquisition on Android 16;
- frame/render feedback sources available without risky injection;
- per-thread rules for UI/RenderThread;
- cluster power-model approximation from our own data.

### WATCH

- per-app rules for games / `game_opt` exceptions.

### REJECT FOR NOW

- copying Uperf platform tuning values;
- running Uperf and op13perf simultaneously;
- real-time scheduler priority changes;
- disabling thermal protection;
- SurfaceFlinger injection as a first implementation choice.

---

## 11. Next repository

R2: `helloklf/scheduler` — focus on configuration abstraction (`uclamp`, cpuset, affinity, OPP rounding, per-mode presets), then compare that abstraction with the Uperf state-machine model before changing `op13perf` code.
