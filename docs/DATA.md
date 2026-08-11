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

## 12. Geekbench version caveat (applies to section 10)

### Version caveat

These are Geekbench **7** numbers on both sides of the comparison. Geekbench 7 rebased its
calibration machine and rewrote its workloads in July 2026; its results are not comparable
with Geekbench 6. The commonly cited OnePlus 13 figures near 2 900–3 000 single-core are
Geekbench 6 and must not be used to compute a deficit against these numbers. An earlier
revision of this repository did exactly that and inferred a non-existent second bottleneck.

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
