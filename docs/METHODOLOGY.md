# Methodology, and ten traps that produced wrong answers

Documenting the false starts because each is easy to hit and each looked convincing at the
time. Three of them produced conclusions that had to be withdrawn after they were written
down, trap 4 produced a wrong conclusion in *both* directions before it settled, and trap 7 is
the same mistake as a previously withdrawn result, made a second time.

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

## Safety invariant: boost exit must be verified

R3's Phase-4 smoke test (2026-08-27, see Trap 10 below) found that an
active-set `uclamp.min` boost mechanism can leave threads clamped after the
run believes it has cleaned up. Any future code that applies an experimental
`uclamp.min` boost (or any other per-thread kernel-state boost) to a subset
of a process's threads must, on exit:

1. reset **every thread currently in the affected process/task group**, not
   only the tracked subset (top-K, active-set, or whatever bookkeeping
   selected them to be boosted in the first place) — bookkeeping can miss
   threads that were boosted indirectly (e.g. kernel-side priority
   inheritance across binder/sync).
2. **verify** the reset by reading the value back (`uclampset -p`, not just
   re-issuing the reset command) rather than trusting that the reset syscall
   succeeded.
3. **fail closed** if verification still shows residue after one retry: emit
   a distinct, unmissable status (not folded into a generic `OK`/error) and
   leave a persistent on-device marker, so a human has to clear it before the
   device is trusted clean again. Never let a boost-exit failure silently
   read as a clean run.

Reference implementation: `experiments/r3-real-app/common.sh`
(`verify_boost_clean`, `uclamp_min_readback`), wired into
`experiments/r3-real-app/run-one.sh`'s `cleanup()`, with a standalone
audit tool at `experiments/r3-real-app/check-uclamp.sh`. This is scoped to
the experiment harness only — no production `perfd`/profile code is wired
to this invariant yet.

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

---

## Trap 6 — the instrument ran on the cluster it was measuring

The first real-workload A/B (section 31) produced control runs that were clamped to 466 for
most of their duration while the prime cluster sat at its full 3 283 200 ceiling. That is not
possible from the workload alone: a task clamped to 466 asks for
`466/1024 x 4 320 000 = 1966 MHz`. Something else was holding the clock up.

It was the sampler. Per 250 ms tick it ran roughly fifteen short-lived processes — `sed`, `awk`,
and a `cat | tr | grep | cut` pipeline per sysfs read — all as root, all therefore exempt from
the clamp under test. **cpu6 and cpu7 share one cpufreq policy**, so any unclamped task landing
on either core sets the frequency for both, and EAS puts exactly that kind of short bursty work
on the fastest available core.

The contamination was also asymmetric: arm B carried an additional `uclampset` loop, so the arm
whose result depended on high frequency had more of the thing that produces high frequency.

Pinning the harness to the mid cluster and handing the workload back its full mask changed the
measured effect from 6.8% to 1.4%:

```sh
taskset -p 3f $$                      # harness and every child on mid
su $UID -c "taskset ff sh -c '...'"   # workload alone gets all 8 cores
```

- **A sampler is a workload.** Frequency-domain sharing means an observer on the same cluster is
  inside the experiment, not outside it. Pin the harness, or read through something that does
  not schedule.
- **Sanity-check the physics of your own control arm.** The tell was there in the first table:
  a 466-clamped task cannot sustain 3 283 200. Any sample where the reported cause and the
  reported effect are inconsistent is an instrument fault until proven otherwise.

---

## Trap 7 — `pgrep -f` matched the idle parent, twice

The previous round's `workload_clamp_probe.sh` reported no effect while monitoring an idle
parent shell, and every conclusion drawn from it was withdrawn. Building the replacement, the
same bug was written again:

```sh
su $APPUID -c "taskset ff sh -c '$BODY # plsleepprobe'" &
PID=$(pgrep -u $APPUID -f plsleepprobe | head -1)     # WRONG
```

`su`'s own command line contains the marker string, and after it drops privileges it matches
`-u $APPUID` too. `head -1` takes the lowest pid, which is the `su` parent — blocked in
`wait()`, on a mid core, never clamped. Both trials returned `prime_residency=0.0%` and
`clamp: never`, a clean and completely false null.

What caught it was that the null was *too* clean: two workloads designed to differ produced
byte-identical outcomes, and one of them contradicted the already-established section 27 result
that an unpinned app-uid busy loop is clamped within seconds. A null that disagrees with a
previously confirmed positive is an instrument failure first and a discovery second.

The fix is to validate the probe's *target*, not just its readout — the same discipline as the
`uclampset` positive control, applied one level further out:

```sh
# sample utime+stime over 1 s; pick the candidate actually burning CPU, refuse if none is
for c in $CANDS; do ... d=$((b - a)) ...; done
[ "$BESTD" -lt 20 ] && { echo "probe target invalid"; return; }
```

The A/B harness escaped the bug only because it happened to use `pgrep -u $APPUID -x gzip`,
matching the binary's name rather than a command-line substring.

**Confirming that the probe can see the effect is not enough if it is pointed at the wrong
process.** Validate the readout *and* the target.

---

## Trap 8 — a cooldown that can time out is not a safety limit

The placement experiment used the same shape of cooldown as every other script here:

```sh
n=0; while [ $n -lt 90 ]; do j=$(cat $Z_J); [ "$j" -lt 45000 ] && break; n=$((n+5)); sleep 5; done
```

If the device has not cooled within 90 seconds, this **falls through and runs the trial anyway**.
Run back-to-back after a long experiment, it did exactly that: two trials started at 69 °C and
66 °C junction instead of the intended sub-45 °C.

A prime-pinned spin loop at 3 283 200 takes the junction from 52 °C to 93 °C in 26 seconds. From
a 69 °C start it passed **104.6 °C within one 250 ms sample** — over the script's own 92 °C abort
and 0.4 °C from the 105 °C hardware trip. The abort did fire and the trial did stop, but it fired
late, because the sensor was only read once per 250 ms data point while the ramp is much faster
than that.

Nothing was damaged — `Thermal Status` stayed 0, battery health `Good`, and the device cooled
normally to 55 °C — but the envelope this repository states for itself was exceeded, and it was
exceeded by the safety code, not by the experiment.

Three separate faults, all of which read as reasonable when written:

- **The gate was advisory.** A precondition that proceeds when unmet is not a precondition. It
  now waits up to 300 s for < 42 °C and **aborts the whole script** if that is not reached.
- **The sensor was sampled at the data rate, not the hazard rate.** Temperature is now
  sub-sampled every 50 ms between data points.
- **The operating point was higher than the question required.** The experiment only needs the
  prime cluster to be *more attractive* than mid, not fast. Re-pinned to 2 649 600 / 2 400 000,
  which preserves the mechanism under test — prime effective capacity 628 against mid 538, and a
  clamp of 376 still fits inside mid — at a fraction of the power.

The last one is the general lesson. **Choose the mildest operating point that still exercises the
mechanism.** The earlier runs used 3 283 200 because that was the number the rest of the
repository used, not because the question needed it.

---

## Trap 9 — cleanup matched a name the run never used, and the clean-check believed it

After an aborted experiment, three busy loops kept running under the app uid for **fifteen
minutes**, unnoticed, while `tools/verify-clean.sh` reported the device clean. They were only
found because an unrelated `/proc/*/fd` scan happened to list them.

Two independent failures lined up:

- **The teardown pattern did not match what the run launched.** Cleanup used
  `pkill -9 -f "$MARK"`. In the run that leaked, the marker had been written as a trailing
  `# $MARK`, which `su`'s own shell stripped as a **comment** before exec — so no process ever
  carried it. `pkill` matched nothing and reported success. (This is the same root cause as
  trap 7 seen from the other end: there, the missing marker made the probe target the wrong
  process; here, it made teardown target nothing.)
- **The clean-check tested names, not behaviour.** `verify-clean.sh` searched a hardcoded list
  of marker strings from the harnesses that existed when it was written. A later experiment used
  a new marker *and* renamed its worker binaries, so it fell outside the list entirely.

The fix is to check the property that actually matters. `verify-clean.sh` now samples every
non-system task's `utime+stime` over one second and reports anything above 20% of a core,
regardless of what it is called:

```
=== any non-system process burning CPU (the check that actually matters) ===
  none above 20% of a core
```

**Identify processes by what they are doing, not by what they are called.** Three separate
failures tonight — the probe target, the teardown, and the clean-check — were all
name-matching, and all three reported success while being wrong. A name is metadata the
experiment controls and can silently lose; CPU time is the thing under test.

Related: the deletion of that same directory appeared to fail with `Permission denied` on every
file when issued as `adb shell su -c "cmd1; rm -rf ...; cmd2"`. Re-issued from a pushed script
it succeeded immediately. Multi-level `su -c` quoting produced a plausible, entirely misleading
error — the same hazard as trap 5. Push a script.

---

## Trap 10 — active-set cleanup swept only the tracked top-K, not the whole process

R3's Phase-4 smoke test (docs/R3_REAL_APP_PILOT.md, 2026-08-27) found dozens of untracked
threads still boosted to `uclamp.min=512` after an active-set run's cleanup ran and reported
success.

The active-set mechanism (`experiments/r3-real-app/common.sh:active_set_tick`) re-ranks a
process's threads every 250 ms and clamps only the current top-K, resetting threads that drop
out of the ranking as it goes — so at any tick it is only ever supposed to be tracking a small
set, recorded in `SETFILE`. The original cleanup trusted that bookkeeping: at end of run it reset
only the tids in `SETFILE`, on the assumption that every boosted tid had passed through the
tracked set at some point and been reset on drop-out.

That assumption was false. Threads outside the tracked top-K still ended up boosted — consistent
with kernel-side boost propagation (binder/sync priority inheritance can carry an effective
uclamp value onto a thread the harness never directly touched) — and a set-file-scoped reset
cannot reach them because they were never in the set file to begin with.

The fix already in `run-one.sh`'s `cleanup()` is to stop trusting the tracked set at exit and
sweep unconditionally: reset every tid currently under `/proc/<pid>/task/`, regardless of
mechanism or bookkeeping. This is now promoted to a general safety invariant — see "Safety
invariant: boost exit must be verified" above — because a full sweep still is not enough on its
own: exit needs to *verify* the readback and fail closed if residue survives a retry, not just
run the reset command and assume it worked.

**Bookkeeping that tracks a subset for efficiency is not a safe basis for a cleanup sweep.**
Anything that can affect a wider set than it tracks (kernel-side propagation, in this case) needs
its cleanup scoped to the wider set, verified, not inferred from the tracker.
