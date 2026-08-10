# Methodology, and two traps that produced wrong answers

Documenting the false starts because both are easy to hit and both looked convincing.

---

## Trap 1 — `dumpsys thermalservice` serves a stale cache

The output contains two temperature blocks. The first is labelled `Cached temperatures` and
can be arbitrarily old:

```
=== reading at T ===          === same command, T+8s ===
CPU0  85.7                    CPU0  85.7      <-- byte-identical, stale
CPU7  93.0                    CPU7  93.0
...                           ...
CPU0  33.6                    CPU0  31.2      <-- live, decaying correctly
CPU7  33.6                    CPU7  32.4
```

Reading only the first block suggests the SoC is sitting at 93 °C while idle, which invites
a "broken thermal sensor / wrong sensor mapping after ROM conversion" conclusion. The live
values agree with `/sys/class/thermal/thermal_zone*/temp` (31–33 °C).

**Always cross-check against sysfs**, and prefer it:

```sh
cd /sys/class/thermal
for z in thermal_zone*; do echo "$(cat $z/temp) $(cat $z/type)"; done | sort -rn
```

Note also that `thermal_zone78` (`pmih010x_lite_tz`) idles around 63 °C. That is a PMIC
sensor, not a skin sensor, and mistaking it for one makes an idle phone look overheated.
The real skin sensors are `shell_front` / `shell_frame` / `shell_back`.

---

## Trap 2 — measuring with the screen off

This one invalidated an entire round of measurements.

With the screen off, `UrccWorker` (from `vendor.urcc-hal-aidl`) writes
`/sys/kernel/msm_performance/parameters/cpu_max_freq` and holds:

```
0:1996800 ... 5:1996800  6:2649600 7:2649600
```

This looks exactly like a second pathological limiter. It survives `stop vendor.urcc-hal-aidl`
(the kernel `freq_qos` request is not withdrawn when the daemon exits), it does not release
after 150 s of idle at 29.7 °C, and root writes to `scaling_max_freq` cannot exceed it. Every
symptom of a fault.

It is just the screen-off power policy. On wake:

```
cpu_max_freq = 0:3532800 ... 6:4320000 7:4320000
p0max=3532800  p6max=4320000
```

**Always assert display state before and during any CPU frequency measurement:**

```sh
dumpsys display | grep mScreenState
dumpsys power  | grep mWakefulness=
svc power stayon usb    # hold it on for the duration; svc power stayon false afterwards
```

An ADB session does not keep the screen awake. A phone on a desk goes to `Dozing` within
seconds and every subsequent number describes the idle power profile instead of the
workload.

---

## Locating a `freq_qos` holder

When `scaling_max_freq` reads back lower than written, some other QoS requester is holding
the ceiling — cpufreq applies `min()` across all requests. On OPLUS kernels the requester can
be identified directly, with a kernel stack trace:

```sh
cat /proc/oplus_freqreq_monitor/fqm_dump
```

Columns: `req, index, timestamp, cluster, pid, largest_min, smallest_max, min, max,
max_cluster, comm, utc, stack`.

This is what separated the two limiters — `cb_do_boundary_change_work [cpufreq_bouncing]`
versus `set_cpu_max_freq [msm_performance]` from `UrccWorker` — without guesswork.

`debugfs` is not mounted by default; `mount -t debugfs none /sys/kernel/debug` works if
needed, but `fqm_dump` was sufficient and is safer to leave alone.

---

## Establishing causation, not correlation

Parameter values matching observed clamps is suggestive, not conclusive. The A/B was run
against an identical workload from an identical thermal starting point:

| `enable` | Start | Result over 15 s |
|---|---|---|
| `1` | 2 649 600, 32 °C | drops to 2 438 400 within 1 s and stays |
| `0` | 2 649 600, 32 °C | holds 2 649 600 for the full run |

Cooldown of 30 s between phases, verified by reading the junction sensor before each start.

---

## Safety envelope

Every script that changes kernel state:

- installs `trap ... INT TERM` and calls an unconditional `restore`
- aborts on junction > 95 °C (trip point is 105 °C) or shell > 42 °C
- bounds the run to a fixed number of seconds
- re-enables CFB and resets `scaling_max_freq` to `cpuinfo_max_freq` on every exit path

An earlier equilibrium run used a 90 °C abort, which fired at t+2 s and produced the
misleading impression of thermal runaway. Raising the threshold to 100 °C revealed a stable
oscillation around 88 °C with the LMH loop actively modulating `scaling_max_freq` between
3 283 200 and 4 320 000 — the SoC was regulating, not running away. Choose abort thresholds
from the sensor's actual operating range, not from intuition.

Nothing here is persistent. All module parameters and `scaling_max_freq` values reset on
reboot. The only persistent artifact in this repo is `tune/oneplus13_cfb_tune.sh`, which is
opt-in and removable.

---

## Benchmark proxy

`taskset 80 sh -c 'i=0; while [ $i -lt N ]; do i=$((i+1)); done'` — pure shell arithmetic,
100% duty on one core, no memory stalls. Hotter than Geekbench per MHz, so thermal results
are conservative.

`date +%s%N` does not work on Android toybox (`%N` unsupported, yields garbage or negative
deltas). Use `/proc/uptime` instead:

```sh
now() { cut -d' ' -f1 /proc/uptime | tr -d '.'; }   # centiseconds
```
