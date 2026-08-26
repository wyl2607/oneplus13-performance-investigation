# R2 — Scene / helloklf/scheduler architecture research notes

Repo: https://github.com/helloklf/scheduler  
Reviewed branch: `main`  
Review scope: framework 130 README, Scene config model, affinity/cpuset, booster, sensors, uclamp, presets, perf-gui layout  
Status: **ADOPT ABSTRACTIONS / REJECT MAGIC MULTI-KNOB WRITES / DO NOT COPY TUNING VALUES**

---

## 0. Baseline correction from current `main`

This review is written after `main` advanced through sections 42–43 in `docs/DATA.md`.

That evidence changes the research question:

- under an eight-core saturating load, raising the CPU ceilings above the shipped daily level does not produce a resolvable throughput gain;
- the apparent `P6=2438400 / P0=2400000` win from a single run disappeared under alternating replication;
- the shipped daily configuration itself showed ~7.5% run-to-run spread in the 150 s eight-core harness;
- the harness therefore cannot resolve the 2–5% differences that motivated the earlier P6 sweet-spot hypothesis;
- the remaining high-value regime is **one or two busy cores, burst/wake-heavy work, responsiveness and thread placement**, not sustained eight-core throughput.

Therefore R2 is not being used to find another all-core frequency recipe. It is being used to design the next experiment and controller abstraction for the regime the current harness did not measure.

---

## 1. What this repository actually contributes

`helloklf/scheduler` is most useful here as a **configuration and control-abstraction reference** around Scene, not as an SM8750 parameter source.

The documented framework exposes concepts for:

- CPU/GPU frequency ranges;
- top-app / foreground / background priority presets;
- uclamp group configuration;
- cpuset and per-thread CPU affinity;
- identifying `UnityMain` and a selected heavy thread;
- per-app scenes;
- touch/button bounded boosters;
- sensor-driven rules;
- reusable presets;
- mode-specific overrides.

The public repository also contains a configuration GUI/editor structure, but the core native Scene scheduler/controller implementation is not presented here as a straightforward auditable daemon source tree. We should therefore treat the documented behavior as a design reference, not claim source-level verification of the runtime implementation.

---

## 2. High-value idea #1: separate policy intent from low-level knobs

Scene exposes higher-level concepts such as:

```text
scheme / mode
scene / app
booster
sensor rule
affinity
uclamp
preset
```

This is the right direction for the future `op13perf` controller and App.

The user-facing product should eventually say things like:

```text
Adaptive
Burst
Sustained
Cooled Extreme
```

while the device profile resolves that intent into explicit supported operations.

Proposed internal shape:

```text
PolicyIntent
  workload_class
  latency_priority
  sustained_budget
  placement_policy
  thermal_policy
  gpu_policy

        ↓ capability resolver

DeviceActions
  p6_cap
  p0_cap
  task_uclamp
  cpuset/affinity
  cfb state
  vendor limiter handling
```

Important difference from Scene: our resolver must be **auditable**. Every high-level intent should expand to a logged list of exact writes and read-backs.

---

## 3. High-value idea #2: heavy-thread selection is more relevant than all-core tuning

Scene's affinity model has explicit support for:

- `unity_main`;
- `heavy_thread` + `heavy_mask`;
- thread-name classes;
- selecting the highest-load instance when multiple threads share a name;
- combining affinity with cpuset (`cpuset_mode=coexist`).

That maps directly onto our newly identified research gap.

The next OP13 question is not:

```text
What ceiling maximizes eight-core throughput?
```

It is:

```text
When one or two latency-critical threads wake repeatedly,
which combination of uclamp + allowed CPUs + bounded burst ceiling
keeps them on the right cores with the least thermal cost?
```

### What to adopt

Build a **read-only heavy-thread observer first**:

```text
for current top-app:
  list tids
  sample per-thread CPU time over a short window
  identify top 1–2 busy/wake-heavy threads
  record comm, current CPU, allowed CPUs, uclamp, migrations
```

Do not immediately pin anything.

The observer should answer whether real workloads naturally have a small number of dominant threads and whether those threads suffer the same wake-time displacement already demonstrated in the repository.

---

## 4. High-value idea #3: cpuset and affinity are different tools

Scene distinguishes hard-ish per-thread affinity from cpuset and even offers a coexist mode.

For our controller this should become an explicit experiment matrix rather than a single combined feature.

Candidate arms for a one/two-thread burst workload:

```text
A stock placement
B uclamp.max repair only
C uclamp repair + broader cpuset eligibility
D uclamp repair + targeted affinity
```

Potential measurements:

```text
completion latency
p50 / p95 wake-to-complete latency
prime residency
migration count
junction peak
thermal_area_80
energy delta if measurable
```

### Important caution

Hard affinity is not automatically better. It can prevent the scheduler from moving work away from a hot or contended prime core. The product should prefer **eligibility/hints** over permanent hard pinning unless a specific workload proves otherwise.

---

## 5. High-value idea #4: bounded boosters, not permanent boost

Scene's booster model is event-driven and has a finite duration, with touch/buttons/presets as triggers.

That fits the two-loop model already extracted from Uperf:

```text
FAST LOOP
interaction / wake / launch / frame critical
-> bounded boost, tens to hundreds of ms

SLOW LOOP
sustained load / temperature / power budget
-> ceiling + thermal policy
```

For OP13, initial burst experiments should be intentionally short.

Candidate durations to test:

```text
100 ms
250 ms
500 ms
```

Do not start with multi-second permanent minimum-frequency boosts. The goal is to accelerate the critical path and then get out.

---

## 6. Critical lesson: snapshot backup/restore is unsafe in a multi-controller phone

Scene documents an automatic backup/restore mechanism for booster writes, but also warns that the system's own boost logic can cause it to capture the wrong value.

This is especially important on this OnePlus 13 because we already have multiple independent actors:

```text
URCC / msm_performance
cpufreq_bouncing
oplus_bsp_task_overload
Android/OPlus power management
op13perf
```

Therefore the future controller must **not** implement:

```text
on boost enter:
    old = read(node)
    write(boost)
on boost exit:
    write(old)
```

because `old` may be a transient value owned by another controller.

Instead use explicit desired-state ownership:

```text
base policy state
+ transient overlay
+ thermal overlay
= resolved desired state
```

When the transient overlay expires, recompute the correct current desired state from policy, not from a snapshot.

This also generalizes the lesson from the repository's previous `module.prop` and thermal step-down drift bugs: **state must have one source of truth and one writer path.**

---

## 7. Reject for our controller: opaque `@set_priority`-style macros

Scene's `@set_priority` may modify different combinations of:

```text
cpu.uclamp.min
schedtune.boost
cpuset
sched_boost
sched_upmigrate
up_rate_limit_us
schedtune.util.max
...
```

depending on what the kernel supports.

That is convenient for generic configs, but wrong for a measurement-driven OP13 controller because:

1. multiple knobs change at once, so causality is lost;
2. behavior differs by kernel capability;
3. one OTA can silently change which knob is active;
4. read-back becomes ambiguous;
5. a performance improvement cannot be attributed to one mechanism.

Our equivalent must expand a preset into explicit operations and log them individually.

Example:

```text
burst_ui_v1:
  task_uclamp_min = X
  task_uclamp_max = 1024
  allowed_cpus = 0-7
  p6_cap = Y
  duration_ms = 250
```

No hidden side effects.

---

## 8. Reject for production: silent frequency rounding

Scene intentionally accepts human-friendly frequency expressions and may choose the nearest supported lower frequency if the requested value is not present.

That is good UX for a generic tuning framework, but it conflicts with what this project has already learned: silent OPP absorption makes verification harder and previously produced documentation/runtime drift.

Production rule for our App/daemon:

```text
if requested OPP is not in scaling_available_frequencies:
    reject profile OR normalize explicitly during profile validation
    log requested -> resolved value
    require read-back confirmation
```

Never silently pretend the requested value was applied.

---

## 9. Group uclamp is not enough for the OPLUS guard problem

Scene documents `@uclamp` mainly at cgroup level for background / foreground / top-app.

Our known OPLUS issue is different: `oplus_bsp_task_overload` clamps specific busy tasks and the important effect occurs when those tasks wake and are placed again.

So our controller must preserve the ability to apply uclamp at task/process scope (current `uclampset` approach) where required.

Future abstraction should distinguish:

```text
GroupPolicy
  top-app cgroup defaults

TaskRepair
  selected task uclamp.max repair

TaskBurst
  selected latency-critical task uclamp.min overlay
```

Do not collapse all three into one top-app group number.

---

## 10. Scene's own warning supports our current direction

The Scene documentation explicitly warns that its most aggressive priority mode can unconditionally prefer big cores and that, in high-frame-rate/heavy games, moving too many tasks onto big cores can overload an already busy big cluster.

That is conceptually consistent with our own findings:

- more prime frequency/usage is not automatically more total work;
- shared budgets matter;
- task placement must be selective;
- the highest-capacity cores should be reserved for threads whose latency actually benefits from them.

This is a strong reason to design **selective burst placement**, not a global "prefer prime" switch.

---

## 11. Sensors/presets: useful schema ideas, but thermal logic stays ours

Scene's sensor rules and reusable presets are useful configuration ideas.

We should adopt:

```text
named presets
conditional overlays
enter-once semantics
per-device feature gates
```

But thermal policy should remain a dedicated controller with explicit hysteresis/dwell, not a generic threshold script.

Reason: our junction sensor is spiky and the existing project already measured oscillation when decisions used raw values. The thermal controller has stronger requirements than a generic sensor rule engine.

---

## 12. Per-app configuration should be an exception layer

Scene is strong at package-specific scenes. That is useful later for games, especially if OPLUS `game_opt` causes behavior that generic top-app rules cannot model.

But the future product should not begin with a giant app database.

Preferred hierarchy:

```text
generic workload classifier
        ↓
device policy
        ↓
optional per-app exception
```

not:

```text
package name -> hardcoded tuning recipe
```

This preserves portability and makes the controller explainable.

---

## 13. Proposed OP13 experiments derived from R2

### S1 — read-only dominant-thread observer

Target: real top-app workloads.

Log every 50–100 ms for a short bounded window:

```text
pid/tid
comm
CPU time delta
current CPU
allowed CPU mask
uclamp min/max if observable
context switches / migrations if cheaply observable
```

Goal: determine whether one/two dominant threads explain interactive work and identify candidates for targeted repair.

No writes.

### S2 — wake-heavy synthetic burst harness

Build a task that repeatedly:

```text
sleep -> wake -> bounded compute -> sleep
```

This directly targets the mechanism already shown in earlier sections: scheduler placement happens at wake.

Compare:

```text
A stock
B limiter repair only
C repair + short uclamp.min
D repair + placement eligibility/affinity experiment
```

Do not use eight saturated workers.

### S3 — one-thread and two-thread burst ceiling ladder

Use bounded bursts rather than 150 s saturation.

Question:

```text
Does DAILY_P6=2841600 leave real burst latency on the table
when only 1–2 threads are active and the device is thermally cool?
```

This is where a higher P6 ceiling may still have value even though section 42 closed the eight-core throughput question.

### S4 — real app launch / scroll proxy

Only after S1–S3 establish a controlled effect:

- app cold/warm launch timing;
- repeated scroll/frame workload;
- frame-time/jank metric if a reliable Android 16 source is found;
- compare bounded hints against no hint.

### S5 — controller overlay prototype

No UI yet.

Implement state resolution only:

```text
BASE
+ BURST overlay
+ THERMAL overlay
= desired state
```

Log the resolved state without writing first.

This validates that overlays compose correctly and that thermal state always has final authority.

---

## 14. Architecture decisions after R1 + R2

R1 Uperf contributed the **event/state-machine and energy-budget architecture**.

R2 Scene contributes the **policy/config abstraction and selective thread-placement model**.

Combined future controller shape:

```text
                  event sources
       touch / top-app / workload / thermal
                       │
                       ▼
                workload classifier
                       │
        ┌──────────────┴──────────────┐
        ▼                             ▼
 fast transient loop             slow policy loop
 burst/uclamp/placement          sustained/thermal
        │                             │
        └──────────────┬──────────────┘
                       ▼
                 state resolver
                       │
        capability + device profile
                       │
                       ▼
                  single writer
                       │
                    read-back
```

This is a better fit for the current evidence than continuing to optimize a static all-core ceiling table.

---

## 15. Decision

### ADOPT

- explicit mode/scene/preset abstraction;
- selective heavy-thread concept;
- cpuset and affinity as separate placement tools;
- bounded event-driven booster concept;
- reusable policy overlays;
- per-app overrides as an exception layer;
- configuration generation/UI ideas for the future App.

### TEST

- read-only dominant-thread detection on Android 16;
- one/two-thread wake-heavy burst harness;
- uclamp repair vs uclamp.min burst vs placement changes;
- short burst ceiling ladder;
- cpuset eligibility before hard affinity;
- real app launch/scroll latency after synthetic results.

### REJECT / DO NOT COPY

- Scene frequency values;
- global aggressive "prefer big" behavior;
- opaque multi-knob `@set_priority` semantics;
- silent OPP rounding in production;
- snapshot-based automatic boost restore;
- generic group uclamp as a replacement for task-level repair;
- treating generic sensor threshold rules as our thermal controller;
- running Scene and op13perf simultaneously for benchmark comparisons.

---

## 16. Updated immediate priority

The previous research roadmap proposed an eight-core P6 sweet-spot sweep as the next CPU phase. Sections 42–43 of current `main` supersede that priority.

New order:

```text
1. R2 Scene/scheduler architecture review                DONE (this file)
2. Build S1 read-only dominant-thread observer           NEXT
3. Build S2 wake-heavy 1–2 thread burst harness
4. Establish burst baseline: stock vs limiter repair
5. Test bounded uclamp/placement overlays
6. Test P6 ceiling only inside the burst regime
7. Return to thermal-retreat redesign with regime-specific evidence
8. Continue R3 SM8750/HMBIRD kernel research
```

The daily values stay unchanged until the burst/response regime produces repeatable evidence.

---

## 17. Next external repository

R3: `cctv18/oppo_oplus_realme_sm8750`

Focus:

- how its SM8750 OKI build preserves/replaces OPLUS scheduler pieces;
- exactly what FengChi/HMBIRD/SCX patches it applies;
- whether those patches touch the same placement/uclamp paths we are measuring;
- which parts can be studied without flashing a custom kernel;
- build/recovery strategy for a future isolated kernel A/B.

Do **not** flash or merge scheduler patches merely because the build supports them. R3 begins as source/patch-diff research only.
