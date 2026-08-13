# Methodology, and four traps that produced wrong answers

Documenting the false starts because each is easy to hit and each looked convincing at the
time. Three of them produced conclusions that had to be withdrawn after they were written
down, and trap 4 produced a wrong conclusion in *both* directions before it settled.

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
reboot. The only persistent artifact in this repo is `mitigation/oneplus13_cfb_tune.sh`, which is
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

---

## Trap 3 — thermal zone indices are reassigned across reboots

`/sys/class/thermal/thermal_zoneN` numbering is allocated in probe order and is **not stable
across boots**. On this device, before a reboot:

```
thermal_zone63 = shell_front
thermal_zone64 = shell_frame
thermal_zone65 = shell_back
```

After a reboot, the same indices resolved to completely different sensors:

```
thermal_zone63 = sys-therm-3
thermal_zone64 = sys-therm-4
thermal_zone65 = sys-therm-5      <- a fast-responding board sensor near the SoC
shell_front/frame/back had moved to thermal_zone57/58/59
```

A sustained-load script with hardcoded indices therefore aborted on a "shell temperature" of
45 °C that was not a shell temperature at all. The tell was that the battery sensor and
`shell_front` stayed at 34–35 °C while "back" climbed 9 °C in 30 seconds — physically
impossible for a back cover with the battery pressed against it.

The CPU junction zones (27, 28, 30) happened to keep their indices, so measurements using
them remained valid. That is luck, not design.

**Always resolve zones by name — and note that a name lookup is one extra `cat` at startup,
against a whole invalidated run:**

```sh
zone_by_name() {
  for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat $z/type 2>/dev/null)" = "$1" ] && { echo "$z/temp"; return 0; }
  done
  return 1
}
Z_J7=$(zone_by_name cpu-1-1-1) || exit 2
```

Failing closed on a missing sensor is better than silently reading the wrong one.

---

## Trap 4 — taking an effect's direction without checking its magnitude

The most expensive error in this repository, because it did not look like an error. It looked
like rigour.

The chain: this device's Geekbench **7** scores were compared against Geekbench **6**
reference figures, and the gap was read as evidence of a second bottleneck. Catching the
version mismatch was correct. What followed was not.

The fix cited a real source — [Signal65's GB7 analysis](https://signal65.com/research/geekbench-7-analysis-and-early-results/)
— for a real fact: GB7 single-core scores come in lower than GB6 on identical hardware. That
citation was then used to dismiss the entire gap. But the source's own numbers are **−9% to
−15%**, and the gap being explained away was **2.2×**.

A correctly-sourced, correctly-directed effect was used to explain a discrepancy fifteen times
its size. Nothing in the citation was misquoted. The magnitude was simply never put next to
the thing it was supposed to explain.

**The check that would have caught it takes one line:**

```
claimed cause:  -15%   ->  factor 0.85
observed gap:   947 vs ~2600   ->  factor 0.36
0.85 explains 0.36?   no, by 2.4x
```

Two habits fall out of this:

- **Withdrawing a claim is itself a claim, and needs the same evidence bar.** The retraction
  was written with more confidence than the original assertion and was checked less. A
  correction that over-shoots is not more conservative than the error it replaces — it just
  fails in the opposite direction, and it is harder to spot because it reads as caution.
- **A ratio validating does not validate the absolute level.** Section 10's clock-ratio
  prediction landed within 2.1% and was taken as confirmation the whole model was right. A
  constant multiplicative error cancels in a ratio, so that agreement was exactly as strong
  with the residual present as without it. Ratio evidence and level evidence are independent;
  collecting one does not get you the other.

---

## Trap 5 — a defensive normalisation step that silently corrupted the code it "fixed"

Scripts were pushed to the device and then normalised with what looked like a harmless
belt-and-braces line-ending fix:

```sh
adb shell "su -c \"sed -i \\\"s/\r$//\\\" /data/local/tmp/x.sh\""
```

Through that nesting the backslash does not survive. sed receives `s/r$//` and deletes a
**trailing letter `r`** from every line of the script. `order[++k] = cur` became
`order[++k] = cu`.

The failure mode is what makes this dangerous. awk treats `cu` as a new, empty variable, so
there is no syntax error and no warning — the program runs, opens the right number of files,
emits the right number of records, and fills every field with an empty string. The output
*looks* structurally correct. It was only caught because the fields were obviously blank; a
corruption in a less visible line would have produced quietly wrong numbers.

Three lessons:

- **The local files were LF-terminated already.** The step was unnecessary from the start.
  A defensive fix for a problem that does not exist still gets to break things.
- **Normalise on the host, where there is no quoting layer.** Reading the file in Python,
  replacing `\r\n`, and pushing the result cannot be misquoted.
- **Assert after pushing.** `sh -n <file> && echo SYNTAX_OK` costs one round trip and would
  not have caught *this* one — but pairing it with a smoke assertion on the first record
  (are the fields non-empty?) would have.

Blast radius, checked rather than assumed: `gb7_sampler.sh` has exactly three lines ending in
`r` and all three are comments, so the frequency and placement traces taken with it are
unaffected. Only the newer attribution sampler had functional code on such a line.
