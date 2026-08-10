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
