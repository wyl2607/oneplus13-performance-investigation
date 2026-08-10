# OnePlus 13 — `cpufreq_bouncing` frequency clamp

Investigation into why a OnePlus 13 (CPH2653, SM8750 / Snapdragon 8 Elite) sustains only
**56% of its rated prime-core clock** under load, and what can be done about it.

Everything here is measured on-device over ADB. No inferred numbers.

---

## TL;DR

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

### All-core (8 threads)

| Ceilings (p0 / p6) | Landing freq | Steady junction | Shell | Result |
|---|---|---|---|---|
| 2 918 400 / 3 283 200 | p6 → 2 841 600 | 89 °C plateau | 34 °C | 40 s, no abort, `Thermal Status: 0` |
| 2 745 600 / 3 072 000 | p6 → 2 841 600 | 89 °C plateau | 35 °C | 40 s, no abort, `Thermal Status: 0` |

**Both configurations converge to the identical plateau.** Under all-core load the steady
state is set by the thermal/power loop, not by the ceiling — so lowering the ceiling below
3 283 200 buys no thermal headroom and only costs single-thread performance.

---

## Mitigation

Two facts shape the fix:

1. Once CFB is disabled, a userspace `scaling_max_freq` write **does** bind (it becomes the
   minimum QoS request). This gives a precise, predictable ceiling without needing to
   reverse-engineer CFB's `config` write format.
2. **CFB is re-enabled by the system on every screen-on/wake event.** Verified: it stays at
   `0` for 60 s with the screen on, survives screen-off, and flips back to `1` on wake. A
   one-shot boot script is therefore not sufficient — a watchdog is required.

`tune/oneplus13_cfb_tune.sh` implements this. See [tune/README.md](tune/README.md) for the
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

## Open question — help wanted

**Is `limit_level 6` stock for CPH2653, or specific to this unit's build?**

Nothing on this device can answer that. It needs one data point from another OnePlus 13.
If you have one, please run [`scripts/contribute-comparison.sh`](scripts/contribute-comparison.sh)
(read-only, no root changes, no PII) and open an issue with the output.

### Correction — there is no evidence of a "second factor"

An earlier revision of this document argued that because a fully unclamped 4 320 000 would
only extrapolate to ~1 680 single-core, while "healthy" Snapdragon 8 Elite units score
2 200–3 000, frequency could not explain the whole gap and some second bottleneck (DSU clock,
memory frequency, scheduler) had to exist.

**That reasoning was invalid and is withdrawn.** It compared Geekbench 7 results from this
device against Geekbench 6 reference figures. Geekbench 7 (released July 2026) rebased its
calibration from a Core i7-12700 to a Ryzen 7 7700, and substantially rewrote its workloads
and datasets — [independent testing found single-core scores drop across all tested platforms
relative to Geekbench 6](https://signal65.com/research/geekbench-7-analysis-and-early-results/).
Primate Labs states GB7 results are comparable only with other GB7 results. The widely quoted
OnePlus 13 figures of ~2 900–3 000 single-core are Geekbench **6** numbers.

No cross-version percentage should be computed from them, and none of the measurements in
this repository support the existence of a non-frequency bottleneck.

---

## Reproducing

All scripts are read-only unless named `*-test`/`*-sweep`/`*-validate`. Every script that
modifies kernel state has an unconditional `restore` and a `trap`, and aborts on
junction > 95 °C or shell > 42 °C.

```bash
adb push scripts /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/scripts/collect-baseline.sh'
```

See [docs/METHODOLOGY.md](docs/METHODOLOGY.md) — including two measurement traps that
produced false conclusions before being caught.

## License

MIT. Findings are observations about a specific device; no warranty. Disabling a vendor
thermal/power limiter is at your own risk.
