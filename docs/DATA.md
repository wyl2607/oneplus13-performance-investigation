# Raw measurements

Reference unit: CPH2653 / OP5D55L1, build `CPH2653_16.0.9.401`, Android 16, kernel 6.6.118.
Ambient ~29 °C. Device on a 500 mA SDP USB port throughout (not fast charging).

---

## 1. Stock `cpufreq_bouncing` config

```
clus 0 first_cpu 0 ctl 1              clus 1 first_cpu 6 ctl 1
last_ts: 1768106399874                last_ts: 1768106400395
acc: 0                                acc: 0
limit_freq: 2400000                   limit_freq: 2438400
limit_level: 10                       limit_level: 6
limit_thres: 50 ms                    limit_thres: 50 ms
enable: 1                             enable: 1
cur_level: 15                         cur_level: 15
max_freq: 3532800 15                  max_freq: 4320000 15
min_freq: 384000 0                    min_freq: 1017600 0
down_speed: 1  down_limit_lat: 50 ms  down_speed: 1  down_limit_lat: 50 ms
up_speed:   1  up_limit_lat:   50 ms  up_speed:   1  up_limit_lat:   50 ms
freq_levels: 16                       freq_levels: 16

global: core_boost_lat_ns=50000000  core_ctl_check=N  debug=N  decay=80
        enable=1  freq_qos_check=Y  self_activate=0  sleep_range_ms=20,30
```

OPP tables as reported by CFB (identical to `scaling_available_frequencies`):

```
policy0: 384000 556800 748800 960000 1152000 1363200 1555200 1785600
         1996800 2227200 2400000 2745600 2918400 3072000 3321600 3532800
                            ^ idx 10 = limit_level

policy6: 1017600 1209600 1401600 1689600 1958400 2246400 2438400 2649600
         2841600 3072000 3283200 3513600 3801600 4089600 4204800 4320000
                                    ^ idx 6 = limit_level
```

---

## 2. Clamp reproduction (screen ON, single thread on cpu7)

```
sec   cur_MHz   max_MHz   cpu7 junction
  0     1017      4320      33 C
  1     2438      2438      50 C      <- clamped
  5     2438      2438      50 C
 10     2438      2438      51 C
 16     2438      2438      52 C
elapsed for 8e6 shell iterations: 18140 ms
```

Android `Thermal Status: 0` throughout. All 20 CPU cooling devices at `cur_state=0`.
HAL hot-throttling thresholds for CPU sensors: `105.0` / `125.0`.

---

## 3. A/B — CFB `enable`

Identical workload, both starting from ~32 °C after a 30 s cooldown.

| `enable` | t+0 | t+1 … t+15 |
|---|---|---|
| `1` | 2 649 600 | **2 438 400**, held |
| `0` | 2 649 600 | **2 649 600**, held |

(Run with the screen off — hence the 2 649 600 rather than 4 320 000 baseline. See
METHODOLOGY.md trap 2. The A/B delta is still valid: only `enable` differed.)

---

## 4. `freq_qos` requesters (`/proc/oplus_freqreq_monitor/fqm_dump`)

Only two non-init requesters appear across 593 logged entries.

**cpufreq_bouncing** — steps `max` down the OPP table to `limit_freq`:

```
41848, 15, 1858718, 1, 136, 0, 2438400, 0, 3072000, 1, kworker/5:1H,
   freq_qos_update_request<-cb_do_boundary_change_work [cpufreq_bouncing]<-process_scheduled_works
41848, 17, 1858832, 1, 136, 0, 2438400, 0, 2649600, 1, kworker/5:1H, ...
41848, 18, 1858888, 1, 136, 0, 2438400, 0, 2438400, 1, kworker/5:1H, ...
41848,  6, 1861678, 1, 136, 0, 2438400, 0, 2147483647, 1, kworker/5:1H,
   freq_qos_update_request<-enable_store [cpufreq_bouncing]<-param_attr_store   <- released by enable=0
```

**UrccWorker** (`vendor.urcc-hal-aidl`) — screen-state power policy, *not* a fault:

```
69848,  5, 1598172, 1, 2611, 0, 1958400, 0, 4320000, 1, UrccWorker, 15:45:01.964,
   freq_qos_update_request<-set_cpu_max_freq [msm_performance]<-kobj_attr_store<-sysfs_kf_write
69848,  6, 1608195, 1, 2611, 0, 1958400, 0, 2649600, 1, UrccWorker, 15:45:11.987,   (+10.023 s)
69848,  7, 1639185, 1, 2611, 0, 1958400, 0, 4320000, 1, UrccWorker, 15:45:42.978,
69848,  8, 1649229, 1, 2611, 0, 1958400, 0, 2649600, 1, UrccWorker, 15:45:53.022,   (+10.044 s)
```

---

## 5. Screen state determines the URCC cap

```
screen OFF : cpu_max_freq = 0:1996800 ... 6:2649600 7:2649600   p0max=1996800 p6max=2649600
screen ON  : cpu_max_freq = 0:3532800 ... 6:4320000 7:4320000   p0max=3532800 p6max=4320000
```

The screen-off cap is **not** released by `stop vendor.urcc-hal-aidl` — the kernel
`freq_qos` request outlives the daemon — and does not decay after 150 s of idle at 29.7 °C.
It is released by waking the display.

---

## 6. Single-thread equilibrium vs ceiling (screen ON, CFB off)

25 s runs, average taken over the settled window (t ≥ 10 s), 30 s cooldown between.

| Ceiling | t+5 | t+10 | t+15 | t+20 | Steady avg | Peak | Shell |
|---|---|---|---|---|---|---|---|
| 2 841 600 | 60 | 61 | 62 | 62 | **62 °C** | 64 °C | 33 °C |
| 3 283 200 | 69 | 72 | 73 | 74 | **73 °C** | 74 °C | 33 °C |
| 3 513 600 | 77 | 79 | 80 | 81 | **80 °C** | 82 °C | 33 °C |

`scaling_cur_freq` equalled the ceiling exactly in all three runs.

### Unlimited (CFB off, no ceiling)

```
sec  cur_MHz max_MHz cpu6j cpu7j cluss shell
  1     3801    4089   73C   81C   61C   32C
  5     3801    4089   78C   88C   63C   32C
 11     3801    3801   79C   94C   67C   32C
 22     4320    3283   75C   92C   67C   32C
 25     4320    3513   74C   99C   66C   32C
 29     3283    4320   76C  101C   67C   32C   <- 100 C abort
```

`max_MHz` oscillating between 3 283 and 4 320 is the LMH/DCVS loop regulating. Junction
oscillates around a mean of ~88 °C rather than climbing monotonically — regulation, not
runaway. Shell never moved off 32 °C.

---

## 7. All-core validation (40 s, screen ON, CFB off)

**Ceilings 2 918 400 / 3 283 200:**

```
sec  p0cur p6cur  j6   j7  cluss front back
  5   2918   3283  77C  84C  73C  34C  34C
 10   2918   3072  83C  89C  78C  34C  34C
 20   2745   2841  84C  89C  80C  34C  34C
 35   2745   2841  84C  89C  81C  34C  34C
END after 40s: completed        Thermal Status: 0
```

**Ceilings 2 745 600 / 3 072 000:**

```
sec  p0cur p6cur  j6   j7  cluss front back
  5   2745   3072  71C  77C  69C  35C  35C
 15   2745   3072  80C  85C  76C  35C  35C
 25   2745   2841  84C  89C  80C  35C  35C
 35   2745   2841  84C  89C  81C  35C  35C
END after 40s: completed        Thermal Status: 0
```

Both converge on p6 = 2 841 600 and j7 = 89 °C. The all-core steady state is set by the
thermal/power loop, not by the configured ceiling.

---

## 8. CFB re-enable trigger

```
t=0    cfb=0   (screen kept ON via svc power stayon usb)
t=10s  cfb=0
t=20s  cfb=0
t=30s  cfb=0
t=40s  cfb=0
t=50s  cfb=0
t=60s  cfb=0        <- no periodic restore
screen off -> cfb=0 <- survives sleep
screen on  -> cfb=1 <- re-enabled on wake
```

The userspace `scaling_max_freq` ceiling survives the same cycle and does not need
re-applying — but it is re-applied by the watchdog anyway, idempotently.

---

## 9. Provenance — why reflashing cannot help

```
ro.build.fingerprint        OnePlus/CPH2653EEA/OP5D55L1:16/BP2A.250605.015/V.R4T3.52da06f-2e397f6-2e81775
ro.vendor.build.fingerprint OnePlus/CPH2653EEA/OP5D55L1:16/BP2A.250605.015/V.R4T3.52da06f-2e397f6-2e81775
ro.odm.build.fingerprint    OnePlus/CPH2653EEA/OP5D55L1:16/BP2A.250605.015/V.R4T3.52da06f-2e397f6-2e81775
ro.bootimage.build.fingerprint  OnePlus/CPH2653EEA/OP5D55L1:16/BP2A.250605.015/V.R4T3.52da06f-2e397f6-2e81775
ro.system.build.fingerprint     oplus/ossi/ossi:16/BP2A.250605.015/...   (generic by design)

cpufreq_bouncing scmversion: g708cd7576750
kernel: 6.6.118-android15-8-g2e6b9c3812c5-ab15114928-4k
```

`my_product` 2.6 GB mounted and populated with region-correct content; `my_region` 53 MB
mounted. No `cpufreq_bouncing` node in `/proc/device-tree`. No reference to the module in
any file under `/vendor/etc`, `/odm/etc`, `/my_product`, `/my_region` other than SELinux
policy.

The module is compiled into a `boot` image whose fingerprint already matches `vendor` and
`odm` exactly. Reflashing the same build reinstalls the same module with the same
compiled-in defaults.

---

## 10. Intervention validation (Geekbench 7)

Device state at the time of the run, read back directly rather than assumed:

```
cfb=0
p0max=2918400
p6max=3283200
screen=ON
uptime=5473s          (no reboot — same boot as the characterisation runs)
service.d=[]          (volatile only, nothing persistent installed)
```

| | Stock (4 runs) | Tuned (1 run) | Change |
|---|---|---|---|
| Single-core | 891, 1052, 911, 935 → ~950 | **1253** | +32% |
| Multi-core | 5279, 5344, 5178, 5086 → ~5220 | **5945** | +14% |

Prediction made from the clock ratio before the run:

```
single-core: 950 × (3283200 / 2438400) = 1280   predicted
                                          1253   measured   → 2.1% error

multi-core:  mid   2745600–2918400 / 2400000 = +18%
             prime 2841600 / 2438400         = +16.5%
             pure-clock expectation          ≈ +17%
                                               +14%   measured
```

Single-core tracks clock ratio almost exactly. Multi-core falls slightly short of pure clock
scaling, as expected for a workload with more memory and DSU dependence than the ALU loop
used for thermal characterisation.

---

## 11. GPU under load — Geekbench 7 OpenCL, **with** the 40 W active cooler

Adreno 830v2, `max_gpuclk` 1 100 000 000. 420 s of 1 Hz read-only sampling
(`scripts/gpu-sample.sh`), full log in `data/gpu-opencl-with-40w-cooler.log`.
Result: **15537 OpenCL**.

Idle state before the run:

```
max_pwrlevel = 0        (0 is the top level — no cap)
min_pwrlevel = 12
thermal_pwrlevel = 0
throttling = 0
lm = 0   bcl = 1   popp = 0
gpu cooling device = cooling_device37, max_state = 13
freq table MHz: 1100 1050 967 900 832 734 660 607 525 443 389 342 222 160
```

### No throttling occurred at any point

`thermal_pwrlevel`, the `gpu` cooling device `cur_state`, and `throttling` were **0 in every
one of the 366 samples**, with no exceptions.

Clock distribution across samples with `gpu_busy_percentage >= 90`:

| Clock | Samples |
|---|---|
| **1100 MHz** | **156** |
| 660 MHz | 1 |
| 443 MHz | 1 |
| 389 MHz | 1 |
| 342 MHz | 3 |

The six sub-maximum samples are the gaps between subtests. The GPU held its rated maximum
for 96% of the busy window.

It did so even at 93 °C junction:

```
 sec  gpuMHz busy% thermal_pwrlvl cdev throttling gpuTemp gpussMax cpu7j shell p6cur
  227   1100    97   0    0   0      90      89    55    24   1017
  231   1100    96   0    0   0      93      93    57    24   1017
```

Compare with the CPU, where `cpufreq_bouncing` cuts the prime cluster to 56% after 50 ms at
50 °C. **The GPU has no equivalent of CFB.** The two domains are governed completely
differently on this device.

### Mixed-load observation

During GPU-bound work the prime cluster sat at **1 017 600 MHz** (idle) for most samples,
rising to the 3 283 200 ceiling only in the gaps between subtests, with `cpu7j` at 39–72 °C.
The CPU tune adds no thermal burden in GPU-bound workloads — it only engages when the
workload is CPU-bound.

### Scope limit — this run was actively cooled

Shell sensors read **23–26 °C** throughout, against 31–35 °C in every passive CPU test in
this document. The OnePlus 40 W magnetic Peltier back-clip was attached.

**The "never throttled" conclusion is therefore established only under active cooling.**
The cooler pulled the shell down roughly 9 °C; in steady state that offset transfers to the
junction, so a passive run would plausibly have reached 101–103 °C rather than 93 °C — right
at the threshold where the cooling device would be expected to engage. A passive A/B using
the same Geekbench 7 OpenCL workload is required before this can be called unconditional.

### Score caveat

15537 OpenCL is recorded for reference only. No Geekbench 7 GPU baseline for this device is
available, and comparing it against Geekbench 6 or any other version would repeat the error
corrected in section 10. The mechanistic finding does not depend on the score: the GPU ran at
100% of its rated clock with zero throttling events.

---

## 12. Geekbench version caveat (applies to section 10) — REVISED 2026-08-13

These are Geekbench **7** numbers on both sides of the section 10 comparison, and that part
stands. What does not stand is the conclusion this section previously drew from it.

**Still true:** GB7 rebased in July 2026 and its results are not directly comparable with GB6.
The commonly cited OnePlus 13 figures near 2 900–3 000 single-core are Geekbench 6.

**Now retracted:** "…and therefore an earlier revision inferred a *non-existent* second
bottleneck." The second bottleneck was dismissed on the strength of a rescale whose size was
never checked.

### The rescale is 9–15%, not a halving

[Signal65's paired GB6/GB7 measurements](https://signal65.com/research/geekbench-7-analysis-and-early-results/)
on identical hardware:

```
Snapdragon X2 Elite      -15%
Apple M5                 -14%
Intel Core Ultra X9 388H -10%
AMD Ryzen AI 9 465        -9%
```

GB7 also kept GB6's baseline *score* of 2 500 and only moved the baseline *machine*
(Dell Precision 3460 / i7-12700 → Lenovo Legion / Ryzen 7 7700), which independently bounds
the rescale to roughly this size.

Applied to the OnePlus 13's ~3 000 GB6 single-core, the expected GB7 figure is **2 550–2 730**.
A user-supplied GB7 7.0.0 result for a CPH2655 reads **2 681 / 8 846**, inside that band.
(`browser.geekbench.com/v7/cpu/116261` — the Geekbench Browser serves HTTP 403 to automated
fetches, so this is recorded as unverified here.)

### Residual against a same-version reference

| State | Prime ceiling | Ratio to 4 320 000 | Predicted | Measured | Residual |
|---|---|---|---|---|---|
| Stock CFB | 2 438 400 | 0.564 | 1 513 | 947 | **0.626** |
| Tuned | 3 283 200 | 0.760 | 2 038 | 1 234 | **0.606** |

The residual is essentially unchanged across two clamp levels that differ by 35%. A
frequency-independent multiplicative loss is a **per-cycle** effect, not a duty-cycle one.

### Why section 10's prediction still validated to 2.1%

Section 10 predicted `947 × (3 283 200 / 2 438 400) = 1 280` and measured 1 253. That is a
*ratio* between two states of the same device, and a constant factor cancels in a ratio.
Clean ratio agreement was read as evidence that the absolute level was also correct. It is
not evidence of that, and the two claims are independent.

### Terminology correction

`3 283 200` is **76%** of the prime cores' `cpuinfo_max_freq` of `4 320 000`, and `2 918 400`
is **83%** of the mid cores' `3 532 800`. Anywhere in this repository that treats the tuned
ceilings as "full speed" or treats 1 234 as a healthy SoC baseline is wrong.

---

## 13. GPU passive A/B — same workload, cooler removed

Same Geekbench 7 OpenCL workload, same CPU tune (`cfb=0`, ceilings 2918400 / 3283200), same
screen-on foreground state. Only difference: the 40 W Peltier back-clip removed and the
device allowed to re-equilibrate to ambient first. Full log in `data/gpu-opencl-passive.log`.

### Idle starting point (screen on, Geekbench foreground)

| | Cooled | Passive | Delta |
|---|---|---|---|
| GPU junction | 26 °C | 40 °C | +14 °C |
| Shell | 23 °C | 35 °C | +12 °C |

### Under load

| | Cooled | Passive |
|---|---|---|
| Peak GPU junction | 93 °C | **104 °C** |
| Peak shell | 26 °C | **39 °C** |
| Throttle events | **0** | **1** |
| Samples at 1100 MHz (busy ≥ 90) | 156 | 150 |
| Samples at 1050 MHz | 0 | 2 |
| **Score** | **15537** | **15432** (−0.68%) |

The single throttle event:

```
 sec  gpuMHz busy% thermal_pwrlvl cdev throttling gpuTemp gpussMax cpu7j shell p6cur
  231   1050    96   1    0   0     104     103    69    36   1017
```

### Findings

**GPU throttling does exist, and the cooled-run conclusion was conditional as suspected.**
`thermal_pwrlevel` reached 1 at 104 °C junction, one step below maximum.

**But it barely engages.** Two samples out of ~156 busy samples, one power level down
(1100 → 1050 MHz, −4.5%), about 1.3% of the busy window. The score difference of −0.68% is
consistent with that and is within run-to-run noise. Predicted before the run at 15380–15540
from the sample counts; measured 15432.

**The throttle path is `kgsl`'s own `thermal_pwrlevel`, not the Linux thermal framework.**
The `gpu` cooling device stayed at `cur_state=0` for the entire passive run even while
`thermal_pwrlevel` was 1. Monitoring only cooling devices would have missed this entirely.

### What the cooler is actually worth here

For a workload of this length it buys headroom, not throughput:

```
cooled  : peak 93 C  -> 12 C of margin to the 105 C trip
passive : peak 104 C ->  1 C of margin
```

The passive run was working right against the trip point and only survived because the
workload ended after ~7 minutes. A sustained load — a game running for tens of minutes —
would consume that 1 °C immediately, and throttling would stop being two samples and become
the steady state. That regime is issue #3 and remains unmeasured.

---

## 14. Boot persistence and watchdog cost

Verified across a real reboot, not inferred.

```
uptime=144s   boot_completed=1
watchdog: PID 3473, PPID 1, "busybox sh /data/adb/service.d/oneplus13_cfb_tune.sh", alive
log: 20:06:57 start cfb=1 p0=2400000 p6=2649600   <- caught CFB active at boot
     20:06:57 re-disabled CFB (count=1)
```

`p0=2400000` in that first line is CFB's own clamp value, so the watchdog observed the
limiter engaged at boot and corrected it. Magisk does execute `service.d` on this setup.

### Watchdog CPU cost

Measured from `/proc/PID/stat` (utime + stime) over 90 s of wall time:

```
t=0    utime=0  stime=1  jiffies
t=90   utime=0  stime=2  jiffies
consumed: 1 jiffy = 10 ms over 90 s = 0.011% of one core
```

A spinning loop would have consumed ~9000 jiffies. The 20 s poll is effectively free.

### Known limitation: a wake window of up to one poll interval

The system re-enables CFB on wake, and the watchdog corrects it on its next pass, so there is
a window of up to `POLL` seconds after unlocking during which the stock clamp is active.
Observed accidentally when a load test was started immediately after `KEYCODE_WAKEUP`:

```
sec  p6cur  p6max
  0   1958   1958    <- CFB active, watchdog has not polled yet
  1   1958   1958
  2   1958   1958
  3   3283   3283    <- watchdog corrects
  4   2438   2438    <- and CFB clamps again before settling
```

Practical effect: launching a heavy app in the first ~20 s after unlocking runs at stock
clamped performance. Shortening the poll reduces the window at the cost of more wakeups.

---

## 15. Power delivery A/B — 500 mA USB versus battery only

Tested over wireless ADB so the cable could be removed mid-session. Same single-thread load,
same tune, screen on and unlocked, comparable starting temperatures. Preconditions were
asserted before each run rather than assumed — the first attempt was correctly refused
because the screen had slept.

| | Plugged, 500 mA SDP | Unplugged, battery |
|---|---|---|
| `p6cur` | 3 283 200 for all 20 samples | **3 283 200 for all 20 samples** |
| Junction | 66 → 73 °C | 66 → 72 °C |
| `current_now` | 216–252 | 94 → 471 → **763** |
| Battery status | `Not charging` | `Discharging` |

**No difference in frequency behaviour.** `bcl=1` is enabled but does not engage at this power
level. The original hypothesis that the weak PC USB port was suppressing performance is ruled
out, and no measurement taken during this investigation carries a systematic bias from it.

Note `Not charging` while plugged: at 500 mA the supply is entirely consumed by the load, and
`current_now` roughly triples once the cable is removed and the battery carries everything.

### Scope

Single-threaded CPU load only. A simultaneous CPU + GPU load — a game — draws far more, and
whether BCL engages there is untested.

---

## 16. Geekbench 7 reproducibility — three tuned runs

Runs 2 and 3 were driven over ADB with a sampler confirming `cfb=0`, `p0max=2918400`,
`p6max=3283200` held for the entire duration — no configuration drift during any run.

| | Stock (4 runs) | Tuned (3 runs) | Change |
|---|---|---|---|
| Single-core | 891, 1052, 911, 935 → **947** | 1253, 1225, 1224 → **1234** | **+30.3%** |
| spread | 18% | **2.4%** | |
| Multi-core | 5279, 5344, 5178, 5086 → **5222** | 5945, 6626, 6082 → **6218** | **+19.1%** |
| spread | 5% | **11.5%** | |

### Single-core became more reproducible, not just faster

Spread fell from 18% to 2.4%. This follows from the mechanism: stock behaviour depends on
when CFB's 50 ms accumulator trips, which varies with the workload's duty cycle, whereas a
fixed `scaling_max_freq` ceiling is deterministic. Single-core sits at 3 283 200 with the
junction at ~73 °C, far from any thermal limit, so nothing else modulates it.

### Multi-core became less reproducible

Spread rose from 5% to 11.5%. Stock multi-core was clamped to 2 400 000 / 2 438 400, which is
thermally comfortable and therefore stable. Tuned multi-core runs near the thermal loop's
operating point, where LMH picks the landing frequency from temperature.

An initial guess that the variance tracks starting junction temperature does **not** hold:
runs 2 and 3 both started at 37 °C and differed by 8.9%. Run 3 began about a minute after run
2 finished, so bulk chassis heat was likely still present while the junction sensor had
already recovered — plausible, but not measured. **The cause is unresolved.**

Honest summary: multi-core gain is **+14% to +27%** depending on conditions, mean +19%.
Single-core gain is **+30%** and repeatable to within 2.4%.

---

## 17. Sustained all-core load, 15 minutes — the 40 s snapshot was misleading

Tuned config (`cfb=0`, ceilings 2 918 400 / 2 918 400... prime 3 283 200), passive cooling,
screen on, 8-thread ALU load for 900 s. Zones resolved by name. Full log in
`data/sustained-allcore-tuned-passive.log`.

```
sec   p0cur p6cur  j6  j7 cluss shell batt tstat
  0    2918  3283  44  49  47     35   35   0
 60    2400  2649  85  90  83     36   36   0
120    2400  2438  86  90  83     37   37   0
180    2400  2438  87  91  84     39   39   1
240    2400  1689  76  78  74     40   40   1
300    2400  1689  76  78  74     42   42   2
360    1996  1689  72  74  71     43   43   2
420    1785  1689  69  70  67     43   43   2
480    1785  1689  69  70  67     43   43   2
...
900    1785  1689  68  69  66     43   43   2
```

### The "89 °C plateau" from section 7 was a transient, not a steady state

A 40 s run stops before the system begins to respond. Over 15 minutes the prime cluster walks
down `3283 → 2649 → 2438 → 1689` and settles at **1 689 600**, with the mid cluster at
**1 785 600**. True steady state is reached after roughly 7 minutes.

### The sustained landing point is below the stock CFB clamp

1 689 600 is lower than CFB's stock `limit_freq` of 2 438 400. Under a sustained all-core
load the tune's advantage is gone after about 3 minutes, and the endpoint is *below* where
stock would have been clamping.

**The control for this is missing.** Stock runs at 2 400 000 / 2 438 400 from the first
second, generates less heat, and may never escalate the thermal framework at all — in which
case its sustained landing point could be higher than the tune's. Until stock is measured
over the same 15 minutes, "the tune is worse for sustained load" is a plausible reading, not
a demonstrated one.

### Android's thermal framework does engage here

`Thermal Status` escalated 0 → 1 at ~180 s → 2 at ~300 s. Every earlier measurement in this
document reported status 0, because none ran long enough. Status 2 is `MODERATE`, which
affects more than CPU clocks — charging rate and display brightness are also governed by it.

### Junction temperature at steady state is *lower*, not higher

69 °C at 900 s, against the 89 °C transient. Earlier text in this repository described the
tune as costing "+20 °C junction under sustained load". That figure came from the 40 s window
and is wrong for genuinely sustained work: the thermal loop trades clock for temperature and
converges cooler. The +20 °C figure remains accurate for short bursts.

### Shell temperature and recovery hysteresis

Shell rose 35 → 44 °C and tracked the battery sensor exactly throughout, which is the
signature of a real thermal measurement rather than the misattributed sensor described in
METHODOLOGY trap 3.

After the load stopped, throttling did **not** release promptly:

```
t+30s  j7=45C shell=42C p6max=1689600 status=2
t+150s j7=42C shell=40C p6max=1689600 status=2
```

Still clamped 2.5 minutes later with the junction down to 42 °C. The framework's release
threshold has hysteresis, so a phone stays throttled for minutes after a heavy session ends.

---

## 18. Sustained all-core with the 40 W cooler — the framework escalates on skin, not junction

Identical to section 17 — same tune, same 900 s, same 8-thread load, zones by name — with the
OnePlus 40 W Peltier back-clip attached. Log in `data/sustained-allcore-tuned-cooled.log`.

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

### Steady state

| | Passive | Cooled | Delta |
|---|---|---|---|
| Prime | 1 689 600 | **2 438 400** | **+44%** |
| Mid | 1 785 600 | **2 400 000** | **+34%** |
| `Thermal Status` | 2 | **0**, never escalated | |
| Shell | 43 °C | 35 °C | −8 °C |
| Junction | 69 °C | 90 °C | **+21 °C** |

### The mechanism

Both runs reach the same peak junction temperature, 90–91 °C. The difference is entirely in
skin: passive climbs to 43 °C and trips Android's thermal framework to status 1 at ~180 s and
status 2 at ~300 s, which clamps the clocks. Cooled holds skin at 35 °C, the framework never
escalates, and the clocks hold.

**The framework governs on skin temperature, not junction.** That is why a back-clip — which
does nothing for junction-to-package thermal resistance — has such a large effect here, while
it was worth only −0.68% on a 7-minute GPU benchmark (section 13) that never escalated the
framework in either state.

### Three things this does not mean

**The cooler does not make the chip cooler.** Cooled junction is 90 °C sustained for 15
minutes against 69 °C passive. Passive is cooler precisely because it is throttled. What the
cooler buys is a cool shell plus sustained clocks, at the cost of hot silicon for longer.

**Even cooled, sustained all-core never reaches the 3 283 200 ceiling.** It lands at
2 438 400, 26% below it. The ceiling matters for bursts and single-thread work, not for
sustained all-core.

**The cooled landing point equals CFB's stock `limit_freq` of 2 438 400.** Almost certainly
coincidence — both are entries in the same OPP table — but it underlines that the stock
control (#9) is still missing. Where stock lands over the same 15 minutes is unknown.

---

## 19. The `config` write format, and a per-cluster disable that survives wake

The format is documented in OnePlus's own kernel source
([cpufreq_bouncing.c, OnePlusOSS sm8350](https://github.com/OnePlusOSS/android_kernel_oneplus_sm8350/blob/2578666fe1999778d99ad48f707dd8ead15e9347/techpack/oneplus/coretech/cpufreq_bouncing/cpufreq_bouncing.c))
and is **comma-separated**:

```
clus,enable,limit_level,limit_thres_ms,down_speed,down_limit_ms,up_speed,up_limit_ms
```

An earlier round of this investigation tried a dozen space-separated variants, got `-EINVAL`
on all of them, and abandoned the approach in favour of the global `enable` parameter plus a
watchdog. The separator was the only thing wrong.

Verified on this device (SM8750), original values restored afterwards:

```
write "1,1,11,50,1,50,1,50"  ->  clus 1 limit_level: 6 -> 11    confirmed
write "1,0,6,50,1,50,1,50"   ->  clus 1 enable:      1 -> 0     confirmed
```

Note the source also shows the in-tree default is `enable = false` — the module ships off and
something in userspace turns it on, which matches the wake-time re-enable observed in
section 8.

### Per-cluster disable is not reset on wake

With the watchdog stopped, both clusters set to `enable=0` via `config`, and the **global**
`enable` parameter left at 1:

```
TEST 1, load                cur = 3283200 for the whole run   (not clamped to 2438400)
screen off -> screen on
after wake                  global=1, per-cluster still 0 of 2 enabled
TEST 2, load                cur = 3283200 for the whole run
```

The system's wake handler writes the global parameter and does not touch per-cluster config.
**A one-shot boot write would therefore replace the 20 s watchdog entirely**, eliminating the
resident process and the wake window of issue #8.

### Not adopted — unexplained thermal discrepancy

Single-thread load at the same 3 283 200 ceiling:

| Mode | Steady junction |
|---|---|
| Global `enable=0` (current watchdog approach) | 73 °C passive, 76 °C cooled |
| Per-cluster `enable=0`, global `enable=1` | **86–96 °C** |

13–23 °C apart on nominally identical work, with 96 °C leaving only 9 °C to the 105 °C trip
point. Candidate explanations — different starting temperature, CFB's `core_boost` path still
running while the global parameter is set, or measurement noise — were not separated, and the
per-cluster run's starting temperature was not recorded.

The watchdog approach is fully validated across reboot, screen cycle, and load, and costs
0.011% of one core. Trading that for an unexplained thermal delta to save a background loop
is not a good exchange. Left as issue #10.

---

## 20. App cold start A/B — no measurable benefit

CFB's threshold is 50 ms and an app cold start is 500–2000 ms of dense CPU work, so the
limiter certainly engages during launch. Whether that is measurable is a separate question.

`am force-stop` then `am start -W`, five cold starts per app per condition, `TotalTime` in ms.
First run of each set discarded as a page-cache outlier.

| App | Tuned (`cfb=0`, ceiling 3 283 200) | Stock (`cfb=1`) |
|---|---|---|
| Settings | 284 246 270 260 → **265** | 276 301 267 258 287 → **276** |
| Maps | 198 196 214 201 → **200** | 203 191 205 205 196 → **203** |

Differences of 1–4%, inside batch noise. In the Maps case the fastest block of all was a
stock one.

### Test flaws, disclosed

The third block was labelled "tuned" but its header reported `cfb=1`. Stopping the watchdog
via the kill switch meant nothing was holding `enable=0`, and the system re-enabled CFB on a
wake during the run. That block is therefore a second stock block — which incidentally gives
a useful repeatability check on stock (Settings 276 then 271, Maps 203 then 193).

Chrome returned no `TotalTime` on any iteration; not investigated.

### Interpretation

Cold start is dominated by I/O, zygote fork, class loading and binder rather than sustained
single-thread compute, and much of it runs on the mid cluster rather than the heavily clamped
prime. The clamp is present but is not the bottleneck.

This closes the last plausible everyday-responsiveness benefit. What remains untested is
**sustained single-threaded compute in real applications** — video export, large image
processing, emulation, compilation — which is the workload shape Geekbench single-core
actually models, and where the +30% should be real.

### Consequence for issue #8

The 20 s wake window was filed as a real usability problem on the reasoning that app
cold-starts immediately after unlock would miss the tune. Since cold starts do not benefit
from the tune at all, that window costs nothing measurable, and #8 drops from a usability
concern to a cosmetic one. The same reasoning removes most of the motivation for #10.

---

## 21. Scheduler/placement survey — hunting the residual from section 12

Read-only survey run 2026-08-13 to find candidates for the ~0.61 per-cycle residual. Build at
the time: `ro.build.version.oplusrom V16.1.0`, OTA `CPH2653_11.F.91_2910_202607050051`,
fingerprint unchanged from section 9. Tune still installed and active (`cfb enable=0`,
watchdog alive).

### Topology, re-read rather than assumed

```
/sys/devices/system/cpu/cpufreq/  ->  policy0, policy6   (no policy2)
policy0  related_cpus 0 1 2 3 4 5   cpuinfo_max_freq 3532800   governor walt
policy6  related_cpus 6 7           cpuinfo_max_freq 4320000   governor walt
```

### `freq_qos` requesters — CFB is one of five

A 5-second idle `fqm_dump` capture, entries grouped by `comm` and by the module named in the
call stack:

```
UrccWorker        400   msm_performance      screen-state policy (normal)
gameSceneLooper    80   oplus_bsp_game_opt   OPLUS game optimiser
thermal-engine-    50   qti_cpufreq_cdev     thermal cooling device
kworker/7:1H       50   cpufreq_bouncing     the documented clamp
sh / busybox       32   sched_walt (24)      the tune's own watchdog writes
```

`gameSceneLooper` / `oplus_bsp_game_opt` had not appeared in any earlier capture in this
repository and is not accounted for by any existing section.

### `/proc/game_opt`

```
chtb_cpu_max_freq            0..5:3072000  6:4089600  7:4089600
cpu_max_freq                 all 2147483647     (INT_MAX = not capping, at idle)
cpu_min_freq                 all 0
disable_cpufreq_limit        0
dsu_freq                     0
fake_cpu7_cpuinfo_max_freq   0
game_pid                     game_pid=-1 child_num=0 ui_assist_num=0
skip_gameself_setaffinity, task_boost, geas_ctrl, tlt_ctrl, gamt, yield_opt, ...
```

Two things matter here. `chtb_cpu_max_freq` caps the prime pair at `4 089 600` rather than
`4 320 000`. And `fake_cpu7_cpuinfo_max_freq` exists at all — a node whose purpose is to
falsify CPU7's advertised ceiling. It reads `0`, so every `4 320 000` in this repository is a
genuine hardware value and not a synthesised one. That is worth stating explicitly because
the whole residual argument in section 12 rests on it.

### cpusets, including the OIface groups

```
top-app        0-7      foreground     0-7      restricted      0-7
background     0-5      system-background 0-5   l-background    0-3
oiface_fg      3-6      oiface_fg+     3-7      oiface_bg       0-2
```

**`oiface_fg` excludes CPU7.** `oiface` is running (`init.svc.oiface: running`,
`persist.sys.oiface.enable=2`, `persist.sys.hardcoder.name=oiface`). Whether a benchmark
thread is ever placed there is untested.

### uclamp

There is no `cpu.uclamp.min` / `cpu.uclamp.max` anywhere under `/sys/fs/cgroup` — this kernel
is built without `CONFIG_UCLAMP_TASK_GROUP` — so uclamp is only observable per task, in
`/proc/PID/task/TID/sched`:

```
uclamp.min / uclamp.max                0 / 1024
effective uclamp.min / uclamp.max      0 / 512      (process in /restricted)
```

System-wide `/proc/sys/kernel/sched_util_clamp_{min,max}` are both `1024`, so the 512 is not
a global setting. A capture that happened to straddle a screen-on/screen-off transition
resolved it:

```
t=0.0-2.2s   cpuset=/foreground   eff uclamp 0/1024   p6max=3283200
t=3.4s       cpuset=/restricted   eff uclamp 0/512    p6max=2649600
```

**Effective uclamp.max tracks the cpuset/task profile.** 512 on a backgrounded app is normal
Android behaviour, not a fault. Whether `top-app` also yields 1024 during an actual benchmark
is the remaining question.

### Cooling devices, at idle

`cpu-cluster0`, `cpu-cluster1` (max_state 15 each), `ddr-cdev`, `pause-cpu0..7`, `kgsl`, `gpu`
all read `cur_state=0`. `ddr-cdev` is the one to watch for the residual: a DDR clamp costs
IPC rather than clock and would be invisible to any `scaling_cur_freq` reading.

### Tooling

The diagnostic toolchain — a resident on-device sampler driven over `adb exec-out` at ~4 Hz,
a host-side CSV logger, and an analyser. Entirely read-only. It records per-CPU frequency and
utilisation, the busiest Geekbench thread's CPU/cpuset/affinity/uclamp/util, both process- and
thread-level cpuset, the cooling devices above, the `game_opt` nodes, and `fqm_dump` at exit.

Geekbench 7's package name is `com.primatelabs.parkdale`.

---

## 22. The residual is not IPC — the benchmark never runs on the prime cores

437 s trace, 1368 samples at 3.1 Hz, tuned config verified live throughout (`cfb enable=0`,
`p0max=2918400`, `p6max=3283200`, watchdog alive). Geekbench 7 scored **1145 / 6382**.

### The benchmark ran on the mid cluster

Taken over the 961 samples where system-wide busy load is 0.75–1.6 cores — i.e. genuinely
single-threaded — and derived from `/proc/stat` per-CPU utilisation, so this does not depend
on identifying the right thread:

| | |
|---|---|
| busiest core is a **mid** core (cpu0/1/4/5) | **95.8%** of samples |
| a **prime** core ≥70% busy | **19/961 = 2.0%** |
| prime `scaling_cur_freq` at idle minimum 1 017 600 | **940/961 = 97.8%** |
| prime reached 3 283 200 | 20 samples = 2.1% |

The multi-core phase is the same pathology:

```
              util    freq
cpu0-cpu5    86-90%   2896 MHz   (at the 2918400 ceiling)
cpu6-cpu7    39-40%   1852 MHz
```

Six mid cores saturated while the two fastest cores on the SoC are 40% idle.

### It is not any of the limiters this repository already documents

| Mechanism | Reading during the run |
|---|---|
| `policy6 scaling_max_freq` | **3 283 200, constant, one segment, 14 s → 362 s** |
| `policy0 scaling_max_freq` | 2 918 400, constant |
| cpuset (process and thread) | `/top-app`, `cpus_allowed=0-7`, 100% of samples |
| `oiface_*` cpusets | 0 samples |
| `Thermal Status` | `NONE` for all 437 s |
| `cpu-cluster0/1`, `ddr-cdev`, `pause-cpu6/7` | `cur_state=0` in every sample |
| `game_opt cpu_max_freq` | `2147483647` (not capping) in every sample |
| `game_opt game_pid` | `-1` in every sample |

Nothing lowered the ceiling. The cores were available, unclamped, cool, and idle.

### `uclamp.max = 466` on the benchmark worker

The Geekbench worker thread — `pool-5-thread-1`, TID 30423, distinct from the main thread —
carried this for the **entire** benchmark:

```
uclamp.min 0   uclamp.max 466   effective uclamp.min 0   effective uclamp.max 466
```

It reverted to `1024` at t≈368 s, immediately after the run ended and the thread exited. All
threads read `1024` when sampled afterwards. So 466 is applied dynamically for the duration of
the workload, not a static profile.

### Why 466 is sufficient to explain everything above

```
/sys/devices/system/cpu/cpu*/cpu_capacity
cpu0-cpu5 = 792        cpu6-cpu7 = 1024
```

**466 < 792.** A task whose utilisation is clamped to 466 fits entirely inside one mid core's
capacity, so EAS/WALT never has a reason to migrate it to a prime core — the mid cluster can
satisfy the clamped demand by construction. The prime cores are not blocked, not clamped and
not hot; they are simply never asked for.

The same clamp also suppresses frequency within the cluster it does use. During true
single-thread samples the mid cores averaged **2 555 MHz against an available ceiling of
2 918 400** — they were not pinned at their own ceiling either, which is what a
utilisation-driven governor does when the driving utilisation is capped.

### Consequence for section 12

The section 12 residual was characterised as a per-cycle (IPC) loss because it did not move
with the ceiling. That reasoning holds, but the cause is not IPC: **the ceiling being varied
was `policy6`'s, and the benchmark was never running on `policy6`.** Changing a ceiling the
workload never reaches cannot change the score, which is exactly the frequency-independence
that was observed. DSU/LLC and DDR are no longer needed to explain it.

This also revises section 16. Removing CFB raised the score because it lifted the *mid*
cluster ceiling from 2 400 000 to 2 918 400 — a +21.6% mid-cluster clock change against a
measured +30% single-core. The prime-cluster ceiling in that tune was very likely irrelevant.

### Not established: who writes 466

`/proc/oplus_qos_sched/` contains `qos_task_uclamp`, `qos_lut`, `qos_level`, `qos_task_prio`,
`qos_task_latency`. `qos_task_uclamp` is the obvious candidate by name, but all of these read
empty once the workload ends (`qos_level` reads `pid: 0, level: -1`), and the run's logcat
contains no `uclamp` or `466` line. The attribution is **unproven**.

What logcat does show is that OPLUS's game/scene framework was tracking the benchmark:

```
gameoptHal: notify complex scene com.primatelabs.parkdale#4~com.primatelabs.parkdale#1
```

`gameSceneLooper` / `oplus_bsp_game_opt` is also an active `freq_qos` requester (section 21).
It did not cap frequency here — `game_opt cpu_max_freq` stayed at INT_MAX — but a scene
framework that classifies the foreground app and a per-task uclamp cap appearing for exactly
that app's worker threads are worth testing for a common origin.

The next run must sample `/proc/oplus_qos_sched/*` and `qos_level` *during* the workload.

---

## 23. Attribution — `oplus_bsp_task_overload` and the `abnormal_task` table

Section 22 established that the Geekbench worker carries `uclamp.max = 466` and that this
explains the placement collapse, but left the writer unidentified. It is identified.

### The module

`/proc/kallsyms` and `/proc/modules` show a loaded OPLUS module `oplus_bsp_task_overload`
exporting, among others:

```
t set_uclamp_max        [oplus_bsp_task_overload]
b golden_cpu            b golden_cpu_first      b goplus_cpu
b max_cluster_id        b min_cluster_id        b atd_count      b task_info
```

`golden` / `goplus` is Qualcomm's gold / gold-plus naming — the mid and prime clusters. The
module therefore knows the cluster topology and has a function whose entire job is to set a
uclamp maximum.

Its procfs interface:

```
/proc/task_overload/abnormal_task        -rw-rw----  system system
/proc/task_overload/skip_goplus_enabled  -rw-rw-rw-  root   root   -> "debug_enabled=1"
```

`skip_goplus_enabled` — *skip gold-plus* — is the prime cluster by name.

### The module's own record of the clamp

`abnormal_task` is a kernel-maintained table. Its header names the columns:

```
pid    uid    limit_flag  comm             date           temp  freq
30423  10xxx  466         pool-5-thread-1  1786635235185  0     3283200
18846  10xxx  466         pool-7-thread-1  1786636130741  0     3283200
```

**TID 30423 / `pool-5-thread-1` is the exact thread the section 22 trace observed carrying
`uclamp.max = 466`**, and 466 is the exact value, recorded by the module itself under a column
called `limit_flag`.

Other entries show the mechanism is general and the value is variable:

```
23682  10xxx  376  pool-5-thread-1     13011  10xxx  346  DefaultDispatch
19515  10xxx  376  SessionManager      19515  10xxx  436  SessionManager
 5270  10xxx  466  HeapTaskDaemon      19778  10xxx 1024  UnityMain
```

1024 entries are unclamped; 346 / 376 / 436 / 466 are clamps. Both Geekbench worker pools and
ordinary app threads appear, so this is a general "runaway thread" guard, not benchmark
detection.

### Timing, and why the clamp was present from sample 0

Converting the `date` column (ms since epoch, local time):

```
TID 30423  pool-5-thread-1  ->  2026-08-13 17:33:55
TID 18846  pool-7-thread-1  ->  2026-08-13 17:48:50
```

The traced run spans 17:48:30 → 17:55:07. So:

- **18846 was flagged 20 s into the traced benchmark** — the clamp is applied *during* the
  workload, as it runs.
- **30423 was flagged at 17:33:55, during the *previous* benchmark run**, and the clamp
  persisted on the pooled thread into the next run. That is why section 22 saw `uclamp.max =
  466` from its very first sample, and why that thread's `nr_migrations` already read 31 037
  at trace start.

Both of the cases that needed distinguishing therefore occur: a thread clamped mid-run, and a
reused pool thread that starts a run already clamped from a previous one.

### Confidence

- **PROVEN** — `oplus_bsp_task_overload` records TID 30423 / `pool-5-thread-1` with
  `limit_flag = 466`, matching the trace exactly in thread identity and value.
- **HIGHLY LIKELY** — that module applies it to the task's `uclamp.max`. It exports
  `set_uclamp_max`, the observed `uclamp.max` equals its recorded `limit_flag`, and no other
  candidate wrote a matching value. The write itself has not yet been caught with a timestamp.
- **UNKNOWN** — the trigger condition, whether any userspace daemon requests it, and what
  selects 346 / 376 / 436 / 466. `/proc/oplus_qos_sched/qos_task_uclamp` reads empty
  throughout and is *not* implicated; the earlier suspicion of it was wrong.
  `gameoptHal`'s scene notifications remain unconnected to the clamp by any evidence.

### Instrumentation for the confirming run

kprobes registered against symbols verified in `/proc/kallsyms`, into a private tracing
instance so the global buffer and any other tracer are untouched:

```
p:tol    set_uclamp_max            arg0=%x0:x64 arg1=%x1:u32 arg2=%x2:u32
p:tolw   proc_task_uclamp_write
p:ucl    __sched_setscheduler      flags=+8(%x1):x64 umin=+48(%x1):u32 umax=+52(%x1):u32
p:uclsys __arm64_sys_sched_setattr tpid=+0(%x0):s32 flags=+8(+8(%x0)):x64 umax=+52(+8(%x0)):u32
```

`sched_attr.sched_util_min` / `sched_util_max` are at +48 / +52 by uapi definition. Probes are
removed and the instance disabled on exit. Trace-only: nothing writes a scheduler, uclamp,
cpuset, cpufreq or thermal tunable.

---

## 24. Catching the clamp live — and how it spreads

Second attribution run, on a freshly rebooted device so `abnormal_task` started empty and any
row in it is unambiguously from this session. Geekbench 7 scored **1229 / 7382**. Full capture
in `data/uclamp-writer-hunt.txt`.

### The clamp, caught on the same 100 ms tick

```
t=611.25  TOLNEW  26298  10xxx  466  pool-5-thread-1  ...  3283200
t=611.25  sampler TID 26298 pool-5-thread-1  uclamp.max=466  effective=466  util_avg=1014
```

uid 10xxx is `com.primatelabs.parkdale`. The module wrote its `abnormal_task` row and the
thread's `uclamp.max` read 466 within the same sample. `util_avg` was 1014 out of 1024 — the
thread was fully loaded when it was flagged, which is consistent with an overload guard.

### The standard API did not do it

`__sched_setscheduler` was kprobed for the whole run — that path carries both the
`sched_setattr` syscall and the kernel-internal `sched_setattr_nocheck`:

```
9873  __sched_setscheduler calls
8491  flags=0x0
1468  flags=0x1
   4  flags=0x78   <- the only calls carrying SCHED_FLAG_UTIL_CLAMP
```

All four were `binder:4542_*` setting **umax=1024**. **Not one call in the entire run set 466.**
So no userspace process and no standard kernel API applied the clamp. `proc_task_uclamp_write`
never fired either, confirming `/proc/oplus_qos_sched/qos_task_uclamp` is uninvolved.

`set_uclamp_max` also recorded zero hits. It is a static symbol; its call sites are almost
certainly inlined, so the out-of-line copy never executes and a kprobe on it cannot fire. That
is a limitation of the probe, not evidence against the module.

### One thread is flagged; the clamp then spreads by inheritance

169 distinct threads carried `uclamp.max = 466` during the run, but `abnormal_task` contains
exactly **one** Geekbench row for the whole session.

```
t=596.4   0 clamped of 15 threads
t=611.2   1 clamped of 22      <- TID 26298, the logged row
t=688.2   2 clamped of 22
t=861.4   8 / 16 / 24 clamped  <- multi-core phase, in waves of eight
```

Every thread in those waves was **already at 466 the first time it was sampled**, and none of
them produced an `abnormal_task` row. Linux copies `uclamp_req` from parent to child in
`uclamp_fork()` unless `reset_on_fork` is set, so a single flagged thread is enough to poison
every worker the pool spawns afterwards.

This is why the whole benchmark is affected rather than one thread, and why the previous
session's `pool-5-thread-1` was already clamped at trace start — the clamp outlives the
workload that triggered it and rides the thread pool into the next run.

**Graded HIGHLY LIKELY, not proven.** The alternative — the module clamping each new thread of
an already-flagged process without logging it — fits the same data. Distinguishing them needs
a probe that fires, i.e. one placed on the module's caller rather than on an inlined callee.

### It is not benchmark detection

On the same clean table, before Geekbench was even launched:

```
22287  10xxx  376  pool-5-thread-1  18:36:32  0  2649600
```

that uid belongs to an unrelated third-party app that happens to use the same Java
thread-pool naming. It was clamped to **376** while idle at the launcher. The guard fires on
thread behaviour, not on package identity.

### Placement, and a result that separates uclamp from frequency

CPU residency of *running* Geekbench threads across the run:

```
CPU0-CPU5 (mid)   90.7%
CPU6-CPU7 (prime)  9.3%
```

Still broken, as in section 22. But this run's ceiling behaved very differently: it oscillated
continuously between 2 438 400 and 3 283 200 as CFB stepped it down and the watchdog pushed it
back up, whereas section 22's run held a flat 3 283 200 for its entire duration.

**The run with the worse ceiling scored higher** — 1229 against 1145 single-core, 7382 against
6382 multi-core. Whatever is costing this device its performance, the prime-cluster ceiling is
not it.

### Aside — the tune did not hold after this reboot

Checked before the run, screen awake, global `cpufreq_bouncing` `enable` reading 0 and the
watchdog alive:

```
p0max = 2400000   (CFB's own clus0 limit_freq)
p6max = 1689600
fqm_dump: cb_do_boundary_change_work [cpufreq_bouncing] still issuing freq_qos requests
config:  per-cluster enable: 1 on both clusters
```

Global `enable=0` did **not** stop CFB on this boot, contradicting sections 3 and 19. The
ceilings did come back to 2 918 400 / 3 283 200 once the benchmark load started, so the run
itself was not invalid, but the watchdog's guarantee is weaker than this repository has been
claiming. Unresolved, and tracked separately from the uclamp work.

---

## 25. The clamp value is computed from the prime clock — and the two limiters compound

A/B arm A (control, nothing modified), run from a cold start with the thread pool
force-stopped first so no clamp could ride in from an earlier session. Ceilings verified at
2 918 400 / 3 283 200 and `cfb=0` immediately before the run. Geekbench 7: **934 / 6017**.

That is the *lowest* score of the whole investigation, on the run with the most carefully
controlled preconditions. The reason is in the flag record.

### The clamp was 346, not 466

```
TOLNEW  t=2541.83  16276  10xxx  346  pool-5-thread-1  ...  2438400
```

83 threads carried `uclamp.max = 346` for the run. Prime residency of running Geekbench
threads: **8.0%**, unchanged from the 9.3% of section 24.

The `freq` column of `abnormal_task` reads **2 438 400** — CFB's clamp value. The guard fired
at a moment when CFB had the prime cluster pulled down, and the limit it applied was lower to
match.

### The formula

Across every `abnormal_task` row observed so far:

| prime `scaling_cur_freq` | `limit_flag` | `0.6 × 1024 × freq / 4 320 000` |
|---|---|---|
| 3 283 200 | 466 | 466.94 |
| 3 072 000 | 436 | 436.91 |
| 2 649 600 | 376 | 376.83 |
| 2 438 400 | 346 | 346.79 |

```
limit_flag = floor(0.6 × 1024 × prime_cur_freq / 4320000)
```

Four points, all within 1 unit, consistent with truncation. The module clamps an "abnormal"
task to **60% of the utilisation its current prime frequency represents**.

**Graded HIGHLY LIKELY.** Four observations fitting a two-parameter line is a good fit but not
a derivation; the 0.6 factor is inferred, not read out of source. A fifth point at a
substantially different clock would settle it.

### The two limiters compound, multiplicatively

This closes a loop that was not visible before:

```
CFB pulls the prime cluster from 4 320 000 down toward 2 438 400
        ↓
task_overload samples that clock and computes 346 instead of 466
        ↓
a harder uclamp pins the worker further onto the mid cluster, and holds
the mid cluster below its own ceiling as well
        ↓
934 instead of ~1200
```

CFB does not merely cost clock on the prime cores the benchmark never reaches. It *feeds* the
uclamp guard a lower number. The repository has treated these as unrelated mechanisms.

### It also explains the run-to-run spread

Section 16 attributed the tuned single-core spread to thermal variance and left it
unresolved. It is not thermal:

| Run | `limit_flag` | Single-core |
|---|---|---|
| section 22 | 466 | 1145 |
| section 24 | 466 | 1229 |
| arm A | **346** | **934** |

Clamp ratio 346/466 = **0.742**. Score ratio 934/1187 = **0.787**. Within 6%.

**Score is very nearly proportional to `uclamp.max`.** The spread across runs is not noise —
it is the clamp value itself changing, depending on where CFB happened to have the prime
cluster when the guard fired. Any single Geekbench figure from this device is one sample from
a distribution whose width is set by a race between two vendor limiters.

This is also an unplanned dose-response curve, which is stronger causal evidence than the
single-value observation in section 24: two different clamp values, two proportional scores,
same mechanism, same placement.

### Prediction recorded before arm B

If `uclamp.max` is the whole story, lifting it to 1024 with the prime ceiling at 3 283 200
should give:

```
2681 × (3 283 200 / 4 320 000) = 2038
```

Linear extrapolation of the dose-response alone would predict ~2600, but the prime ceiling
truncates it — a task that reaches the prime cluster still cannot exceed 3 283 200. So: 1900
to 2100, with prime residency going from 8% to a majority. Materially below 1900 means a
third mechanism remains.

---

## 26. A/B — lifting only `uclamp.max` more than doubles single-core

The controlled experiment. Both arms used the identical sampler, kprobes and logcat capture,
both started from a force-stopped thread pool so no clamp could ride in from a previous
session, both from a cool device with ceilings verified at 2 918 400 / 3 283 200 and `cfb=0`.

**The only difference in arm B** was a loop running `uclampset -a -M 1024 -p <pid>` every
250 ms. Toybox's first-party `uclampset`, going through the ordinary `sched_setattr` path.
Nothing else was touched — no cpufreq, no cpuset, no thermal, no governor, no module
parameter.

### Result

| | Arm A (control) | Arm B (uclamp lifted) | Change |
|---|---|---|---|
| `uclamp.max` on workers | **346** | **1024** | |
| Prime residency of running threads | **8.0%** | **59.5%** | |
| CPU7 alone | 6.3% | **46.4%** | |
| **Single-core** | **934** | **2126** | **+128%** |
| **Multi-core** | **6017** | **8386** | **+39%** |

The prediction recorded before the run was 1900–2100. Measured 2126, **4.3% above the top of
the range**.

### Against a same-version reference

Reference: 2681 / 8846 (GB7 7.0.0, CPH2655).

```
Arm A  single-core  934 = 34.8% of reference     multi-core 6017 = 68.0%
Arm B  single-core 2126 = 79.3% of reference     multi-core 8386 = 94.8%
```

The single-core shortfall that remains is the tune's own ceiling, not a defect:

```
prime ceiling 3 283 200 / 4 320 000 = 76.0% of rated
arm B achieved                        79.3% of the reference score

2126 × (4 320 000 / 3 283 200) = 2797 at rated clock, against a 2681 reference
```

**Scaled to its rated clock this device is fully healthy** — slightly above the reference,
within sample-to-sample variation. There is no third mechanism. The entire deficit this
repository has been chasing was `uclamp.max`.

### The intervention was caught in the act

```
t=11.72s   TID 17073 (pool-5-thread-1)  uclamp.max 466 -> 1024   effective -> 1024
```

`oplus_bsp_task_overload` still fired during arm B — `abnormal_task` gained its row at
t=3205.98 with `limit_flag=466` — but the loop reverted it within one 250 ms poll. Across the
whole run, thread-samples read:

```
uclamp.max = 1024 : 34121 samples
uclamp.max =  466 :     1 sample
```

One sample. That single 466 is the window between the guard writing and the loop undoing it,
and it is the clearest possible statement of the causal chain: the guard clamps, and while the
clamp is held off, the workload runs on the prime cores.

### What it costs — the honest part

| | Arm A | Arm B |
|---|---|---|
| Junction, median | 40.5 °C | 54.0 °C |
| Junction, p95 | 52.1 °C | **87.2 °C** |
| Junction, max | 78.4 °C | **95.0 °C** |
| Shell, max | 35.0 °C | 36.1 °C |

The safety guard fired at the end of the run:

```
!! THERMAL ABORT - reverting to stock clamp: ABORT|98400|35500
```

98.4 °C junction against a 105 °C hardware trip point, with the shell at 35.5 °C. Arm B's
score of 2126 was achieved *including* the portion of the run after the abort, when stock
behaviour had resumed.

**The shell barely moved — 35.0 to 36.1 °C — while the junction rose 35 °C at p95.** Section 18
established that Android's thermal framework escalates on skin temperature, not junction. So
nothing in the framework would intervene here: the user cannot feel it, `Thermal Status` stays
0, and the only remaining backstop is Qualcomm's LMH loop at the trip point.

That is the real argument for the guard existing. A runaway thread on this SoC will sit at
87 °C junction indefinitely without the phone ever feeling warm or the OS noticing. What the
guard cannot do is tell that thread apart from a user who deliberately asked for sustained
compute.

### Scope of the claim

One A/B pair, one device, one benchmark. The effect size (+128%) is far outside the observed
run-to-run spread (934–1229 stock, a 31% band), and the mechanism is independently supported
by the dose-response in section 25 and the per-thread traces in sections 22 and 24. But the
arms were not repeated or order-reversed, so the ordering effect is unmeasured.

---

## 27. What triggers the clamp

Controlled probing with `trigger_probe.sh`: a bounded busy loop spawned under a chosen uid and
optional affinity mask, polling both `abnormal_task` and the task's own `uclamp.max` until one
of them moves. Aborts at 90 °C junction. Prime ceiling 3 283 200 and `cfb=0` throughout, so
every trial saw the same clock.

Watching the table alone is not enough — it can log without clamping — so the task's
`uclamp.max` is read directly and the two outcomes are reported separately.

### The gate is uid, and it is absolute

Identical busy loop, identical `comm` (`sh`), identical prime clock. Only the uid differs:

| uid | Result | `uclamp.max` | Time |
|---|---|---|---|
| 10999 (app) | **CLAMPED** | **466** | 5.84 s |
| 10999 (app) | **CLAMPED** | **466** | 26.79 s |
| 0 (root) | logged only | 1024 | 14.06 s |
| 1000 (system) | logged only | 1024 | 41.75 s |

Root and system tasks *are* evaluated and *are* written into `abnormal_task` — with
`limit_flag = 1024`, meaning no clamp. The exemption is applied at the clamp decision, not by
skipping the check. This is the clean version of the pattern the historical table showed,
where every uid 0 and uid 1000 row carried 1024 even at full prime clock.

**This also invalidates every benchmark run from a root shell.** A `taskset`-pinned busy loop
run as root — the proxy this repository used for all of its thermal characterisation in
sections 2, 6 and 7 — is exempt from the guard, and therefore cannot reproduce what an app
experiences. Those thermal numbers remain valid as thermal numbers; they are not valid as a
model of app behaviour.

### It only fires on the prime cluster

Same uid, same load, only the affinity mask differs:

| Affinity | Result | Time | Junction reached |
|---|---|---|---|
| `taskset 3f` — mid cluster, CPU0-5 | **never clamped** | 45 s timeout | 45.1 °C |
| `taskset c0` — prime cluster, CPU6-7 | **CLAMPED at 466** | 5.12 s | 64.8 °C |
| unpinned | CLAMPED at 466 | 5.1–26.8 s | 61–73 °C |

**The guard is a one-way ratchet:**

```
task starts, utilisation ramps
   -> the scheduler correctly promotes it to the prime cluster
   -> the guard sees sustained load ON PRIME and clamps uclamp.max
   -> the clamped task falls back to the mid cluster
   -> on mid it can never satisfy the trigger again, so it never returns
```

It punishes precisely the tasks the scheduler got right, and there is no path back. That is
why `abnormal_task`'s `freq` column always holds a *prime* frequency, and why the limit is
computed from the prime clock: the task was on prime at the moment it was judged.

**Confound, stated:** cluster and temperature are not separated by this pair. The mid-pinned
run only reached 45.1 °C against 64.8 °C for prime, so a temperature threshold would fit the
same two data points. The cluster reading is favoured by the rest of the evidence — the
module's own `goplus_cpu` symbol, its `skip_goplus_enabled` node, and the prime-clock-based
formula — but a mid-cluster load driven to 65 °C is needed to settle it.

### Timing

Time from load start to clamp, app uid, unpinned or prime-pinned: **5.91, 5.13, 5.84, 26.79,
5.14, 5.12 s**. Five of six inside six seconds, one outlier at 27 s.

There is no long grace period. Any sustained single-threaded work an app does — a video
export, a compile, an emulator, a benchmark — is clamped within seconds of the scheduler
promoting it. Section 20's finding that app cold starts see no benefit from the CFB tune now
has a second explanation: a 500–2000 ms launch ends before this guard would even engage.
