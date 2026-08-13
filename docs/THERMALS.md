# Thermals

A consolidation of the thermal record, currently spread across
[DATA.md](DATA.md) sections 2, 6, 7, 13, 17, 18 and 26. Numbers are copied
from those sections, not re-derived.

Read the correction first. It changes how every earlier thermal table can be
used.

---

## Correction (DATA.md section 27)

The load proxy used in sections 2, 6 and 7 was

```
taskset 80 sh -c 'i=0; while [ $i -lt N ]; do i=$((i+1)); done'
```

run from a root shell. Section 27 showed that uid 0 and uid 1000 are written
into `abnormal_task` with `limit_flag = 1024` and are never actually clamped.
The exemption is the uid gate inside `oplus_bsp_task_overload`.

Those runs are valid as **thermal characterisation of the silicon**: a
pinned ALU loop at a known ceiling, with junction and shell recorded. They
are **not** a valid model of what an app experiences. An app thread on the
same core, at the same clock, is clamped off the prime cluster within
seconds and then runs on a mid core at a reduced `uclamp.max`. Its heat and
its performance are both different.

Anything in this repository that treats a root-shell busy loop as a proxy
for Geekbench, video export, or any other app workload is wrong on that
point. The tables below keep the numbers because the silicon characterisation
still stands.

---

## What the framework actually governs on

Android's thermal framework escalates on **skin** temperature, not
junction. That is the load-bearing result of section 18, and it is why
every "it cannot be thermal, the phone is cool" reading in this project was
simultaneously true and incomplete.

Evidence is the 15-minute all-core pair (sections 17 and 18). Same tune,
same 8-thread ALU load, same 900 s, zones resolved by name. The only
difference is a 40 W Peltier back-clip.

```
sec    passive                        cooled
       p6cur  j7  shell  tstat        p6cur  j7  shell  tstat
  0     3283  49    35     0           3283  37    27     0
120     2438  90    37     0           2649  90    28     0
240     1689  78    40     1           2649  90    30     0
360     1689  74    43     2           2438  91    31     0
600     1689  69    44     2           2438  91    33     0
900     1689  69    43     2           2438  90    35     0
```

| | Passive | Cooled | Delta |
|---|---|---|---|
| Prime | 1 689 600 | **2 438 400** | **+44%** |
| Mid | 1 785 600 | **2 400 000** | **+34%** |
| `Thermal Status` | 2 | **0**, never escalated | |
| Shell | 43 °C | 35 °C | −8 °C |
| Junction | 69 °C | 90 °C | **+21 °C** |

Both runs reach the same peak junction, 90–91 °C. The difference is entirely
in skin. Passive climbs to 43 °C and trips the framework to status 1 at
~180 s and status 2 at ~300 s, which clamps the clocks. Cooled holds skin at
35 °C, the framework never escalates, and the clocks hold.

The cooler does not make the chip cooler. Cooled junction is 90 °C for 15
minutes against 69 °C passive. Passive is cooler because it is throttled.
What the cooler buys is a cool shell plus sustained clocks, at the cost of
hot silicon for longer.

Even cooled, sustained all-core never reaches the 3 283 200 ceiling. It
lands at 2 438 400. The ceiling matters for bursts and single-thread work,
not for sustained all-core.

The cooled landing point equals CFB's stock `limit_freq` of 2 438 400.
Almost certainly coincidence — both are OPP table entries — but the stock
15-minute control is still `TODO: unmeasured`. Where stock lands over the
same 15 minutes is unknown.

`Thermal Status` 2 is `MODERATE`. It governs more than CPU clocks: charging
rate and display brightness are also under it.

---

## The 15-minute walk-down (section 17)

A 40 s all-core snapshot (section 7) lands at p6 = 2 841 600 and j7 = 89 °C
with `Thermal Status` still 0, and looks like a plateau. It is not. Over
900 s, passive, the prime cluster walks

```
3283 → 2649 → 2438 → 1689
```

and settles at **1 689 600**, mid cluster at **1 785 600**. True steady
state is around 7 minutes. 1 689 600 is below CFB's stock `limit_freq` of
2 438 400. Under a sustained all-core load the tune's frequency advantage
is gone after about 3 minutes, and the endpoint is *below* where stock
would have been clamping.

The stock 15-minute control is missing, so "the tune is worse for
sustained load" is a plausible reading, not a demonstrated one. Stock
generates less heat from the first second and may never escalate the
framework at all.

Junction at 900 s is 69 °C — *lower* than the 89 °C / 40 s transient.
Earlier text in this repository described the tune as costing "+20 °C
junction under sustained load". That figure is the 40 s window and is
wrong for genuinely sustained work: the thermal loop trades clock for
temperature and converges cooler. The +20 °C figure remains accurate for
short bursts.

After the load stopped, the clamp did not release promptly:

```
t+30s   j7=45C  shell=42C  p6max=1689600  status=2
t+150s  j7=42C  shell=40C  p6max=1689600  status=2
```

Still clamped 2.5 minutes later with the junction down to 42 °C. The
framework's release threshold has hysteresis.

Shell rose 35 → 44 °C and tracked the battery sensor exactly, which is the
signature of a real skin measurement rather than the misattributed sensor
in METHODOLOGY trap 3.

These 15-minute runs used the same root-shell ALU workers as sections 2, 6
and 7. They characterise the thermal loop and the framework. They do not
characterise an app under `task_overload`.

---

## Burst characterisation (sections 2, 6, 7)

Hardware trip point for the CPU sensors is 105 °C / 125 °C. Junction
sensor used throughout: `cpu-1-1-1` (cpu7), resolved by name after trap 3.
Shell: `shell_front` / `shell_back`. `Thermal Status` 0 and all 20 CPU
cooling devices at `cur_state=0` unless noted.

**Section 2 — stock CFB, single thread pinned to cpu7, screen on.** Clamp
to 2 438 400 within 1 s. Junction 50–52 °C. Shell is not in that log. The
README single-thread equilibrium table lists shell 31 °C at this ceiling.

**Section 6 — CFB off, single thread, 25 s, average over t ≥ 10 s.**

| Ceiling | Steady avg | Peak | Shell |
|---|---|---|---|
| 2 841 600 | 62 °C | 64 °C | 33 °C |
| 3 283 200 | 73 °C | 74 °C | 33 °C |
| 3 513 600 | 80 °C | 82 °C | 33 °C |
| unlimited | ~88 °C oscillating | 101 °C | 32 °C |

Unlimited: `scaling_max_freq` oscillates between 3 283 200 and 4 320 000.
That is the Qualcomm LMH/DCVS loop regulating, not runaway. Disabling CFB
does not leave the SoC unprotected. The 100 °C abort fired at t+29 s with
4 °C of margin.

**Section 7 — all-core, 40 s, CFB off, two ceiling pairs.**

Both 2 918 400 / 3 283 200 and 2 745 600 / 3 072 000 converge on
p6 = 2 841 600 and j7 = 89 °C, shell 34–35 °C, `Thermal Status` 0. Under
all-core load the 40 s landing frequency is set by the thermal/power loop,
not by the configured ceiling. These are transients. Section 17 is the
steady state.

Again: root-shell workers, uid-gate exempt. Silicon characterisation, not
an app model.

---

## Active cooling, GPU (section 13)

Same Geekbench 7 OpenCL workload, same CPU tune, screen on. Only difference:
40 W back-clip on versus off.

| | Cooled | Passive |
|---|---|---|
| Peak GPU junction | 93 °C | **104 °C** |
| Peak shell | 26 °C | **39 °C** |
| Throttle events | 0 | 1 |
| Score | 15537 | 15432 (−0.68%) |

The single throttle is `kgsl`'s own `thermal_pwrlevel` stepping 1100 →
1050 MHz at 104 °C GPU junction. The Linux `gpu` cooling device stayed at
`cur_state=0` for the whole passive run. Monitoring only cooling devices
misses this path.

For a ~7 minute GPU benchmark the cooler buys headroom (12 °C vs 1 °C of
margin to the 105 °C trip), not throughput. A sustained game is a
different regime and is `TODO: unmeasured`.

The cooler was worth **+44%** sustained CPU clock over 15 minutes
(section 18) because that workload *does* escalate the skin-driven
framework. The two results are consistent: the framework is the thing the
back-clip changes.

---

## Cost of lifting the uclamp (section 26)

The only intervention in arm B was `uclampset -a -M 1024 -p <pid>` every
250 ms. Geekbench 7, app uid, so the uid gate applies.

| | Arm A (clamped) | Arm B (uclamp lifted) |
|---|---|---|
| Junction, median | 40.5 °C | 54.0 °C |
| Junction, p95 | 52.1 °C | **87.2 °C** |
| Junction, max | 78.4 °C | **95.0 °C** |
| Shell, max | 35.0 °C | 36.1 °C |

The project's own abort fired at the end of arm B:

```
!! THERMAL ABORT - reverting to stock clamp: ABORT|98400|35500
```

98.4 °C junction, 35.5 °C shell, 6.6 °C of margin to the 105 °C trip.
Arm B's score of 2126 includes the portion of the run after the abort,
when stock behaviour had resumed.

**The shell barely moved — 35.0 to 36.1 °C — while the junction rose 35 °C
at p95.** Combined with section 18, nothing in Android's thermal framework
would intervene: the user cannot feel it, `Thermal Status` stays 0, and
the remaining backstop is Qualcomm's LMH loop at the trip point.

This is the honest argument *for* `oplus_bsp_task_overload`. It is also
why mitigation cannot be a one-click global unclamp. See
[../mitigation/README.md](../mitigation/README.md).

---

## How to read a temperature in this repository

- Resolve zones **by name**. Indices are reassigned across reboots
  (METHODOLOGY trap 3). `cpu-1-1-1` is the cpu7 junction on this device;
  `shell_front` / `shell_frame` / `shell_back` are the skin sensors.
  `pmih010x_lite_tz` idles around 63 °C and is a PMIC, not skin.
- `dumpsys thermalservice` serves a stale "Cached temperatures" block
  (trap 1). Cross-check against sysfs.
- Screen must be on (trap 2). A Dozing phone is a different power profile.
- 40 s is a burst. 15 minutes is sustained. Do not quote one as the other.
- A root-shell `taskset` loop is not an app.
