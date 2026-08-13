# Reproduction

How to reproduce each headline claim. Getting the preconditions wrong
invalidated runs during this investigation; they are restated in every
section on purpose.

The five traps that produced confidently wrong answers are in
[METHODOLOGY.md](METHODOLOGY.md). Trap 2 (screen off) and trap 3 (thermal
zone indices) are the ones that silently ruin a capture. Trap 5 is the
`sed` line-ending "fix" that deletes a trailing `r` from every line; do
not normalise scripts on the device.

Root is required. Nothing below should be run against a phone you do not
own. Diagnosis is read-only. The A/B is not.

---

## Preconditions (every time)

1. **Screen stays on.** An ADB session does not hold the display.
   `svc power stayon usb` before the run, `svc power stayon false` after.
   Assert, do not assume:
   ```
   dumpsys display | grep mScreenState
   dumpsys power  | grep mWakefulness=
   ```
   A phone on a desk goes to `Dozing` within seconds and every subsequent
   frequency number describes the idle power profile (METHODOLOGY trap 2).
2. **Force-stop the target app first.** `am force-stop <package>`. The
   clamp rides on pooled threads into the next session (DATA.md sections
   23–24). A run that starts already clamped is not a fresh observation.
3. **Start from a cool device.** Arm A of the A/B sat at 40.5 °C junction
   median. A phone that just ran a benchmark is not a control for the next
   one. Read `cpu-1-1-1` (by name, not index) and wait until it has
   actually fallen, not until the shell feels fine.
4. **Record the cpufreq ceilings before and during.**
   `scaling_max_freq` / `scaling_cur_freq` for every policy, plus
   `cat /sys/module/cpufreq_bouncing/parameters/enable` if that module
   exists. CFB feeds `task_overload` a lower prime clock and so a harder
   clamp (section 25). A run that does not record the ceiling cannot be
   compared to another run.

`date +%s%N` does not work on toybox. Use `/proc/uptime`. Resolve thermal
zones by name (trap 3). Do not push a script and then `sed -i` it on the
device (trap 5).

---

## 1. Observing the clamp

Claim: while an app is under sustained CPU load, `oplus_bsp_task_overload`
writes a row into `/proc/task_overload/abnormal_task` and that thread's
`uclamp.max` reads the same `limit_flag` (466, 346, or similar — not
1024). Prime cores sit at idle.

```
adb push tools/diagnose.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/diagnose.sh <package>'
```

Run it **while the app is working**, a few seconds in, not at the
launcher. On the reference device the clamp lands 5–30 s after load
begins.

`diagnose.sh` is strictly read-only. It resolves the fastest cluster from
`cpu_capacity` rather than assuming CPU6/7.

What a positive result looks like:

- one or more threads with `uclamp.max` other than 1024
- a matching `limit_flag` row in `abnormal_task` (uids already worth
  redacting if you paste this)
- fastest cores at their minimum clock while the app is busy

A negative result at idle is not evidence the module is absent. A negative
result on a root-shell workload is not evidence either — see section 2.

`tools/collect-report.sh` produces the same facts as a single pasteable
block, including a full redacted table, and is what a device report should
attach.

---

## 2. Trigger conditions

Claim: the clamp is gated on uid (root and system are logged but not
clamped) and only fires while the thread is on the prime cluster. Mid-
cluster pin never clamps. The same loop as an app uid clamps in seconds.

```
adb push tools/trigger-probe.sh /data/local/tmp/
```

The probe spawns a bounded busy loop under a chosen uid and optional
affinity, and polls both `abnormal_task` and the task's own `uclamp.max`.
Watching the table alone is not enough — it can log without clamping.
Aborts at 90 °C junction. Does not write any kernel tunable.

### Uid-gate control

Identical load, identical `comm`, only uid changes. Use a synthetic app
uid (10999 was used in this repository and is not an installed app), then
root, then system:

```
adb shell su -c 'sh /data/local/tmp/trigger-probe.sh 10999 90 none app'
adb shell su -c 'sh /data/local/tmp/trigger-probe.sh 0     90 none root'
adb shell su -c 'sh /data/local/tmp/trigger-probe.sh 1000  90 none system'
```

Expected shape, from `data/trigger-conditions.txt`:

| uid | result | `uclamp.max` |
|---|---|---|
| 10999 | CLAMPED | 466 |
| 0 | LOGGED_ONLY | 1024 |
| 1000 | LOGGED_ONLY | 1024 |

Apply the preconditions. Screen on. Cool start. Record the prime ceiling
before each trial; the probe holds `cfb=0` / 3 283 200 only if you set
them. On the original run the ceiling was 3 283 200 and every app trial
saw `limit_flag = 466`.

### Prime-only control

Toybox `taskset` wants a **bare hex** mask. `0x3f` is rejected.

```
adb shell su -c 'sh /data/local/tmp/trigger-probe.sh 10999 45 3f mid'
adb shell su -c 'sh /data/local/tmp/trigger-probe.sh 10999 45 c0 prime'
```

On this device `3f` is CPU0–5 (mid) and `c0` is CPU6–7 (prime). Other
OPLUS layouts differ; compute the mask from `cpu_capacity`, do not copy
these two values onto a different SoC.

Expected shape:

| mask | result |
|---|---|
| `3f` | TIMEOUT, `uclamp.max` still 1024, 45 s |
| `c0` | CLAMPED at 466, ~5 s |

**Confound:** the mid-pinned trial reached 45.1 °C, the prime-pinned trial
64.8 °C. Cluster and temperature are not separated. A mid-cluster load
driven to 65 °C is `TODO: unmeasured`.

Force-stop is irrelevant here (the loop is not an app pool) but the other
three preconditions still apply. Do not run the prime-pinned trial on an
already-hot device; the probe's 90 °C abort will eat the result.

---

## 3. A/B — lifting only `uclamp.max`

Claim: with every other tunable held equal, resetting `uclamp.max` to 1024
every 250 ms takes Geekbench 7 single-core from 934 to 2126 and prime-core
residency of running threads from 8.0% to 59.5%.

The host driver used for that pair was:

```
python gb7_hunt.py --arm control
python gb7_hunt.py --arm unclamp
```

`gb7_hunt.py` is the host-side capture used to produce DATA.md section 26
(sampler + kprobes + logcat, and in the unclamp arm a 250 ms
`uclampset` loop). It is not shipped in this tree. The intervention it
applies in `--arm unclamp` is exactly:

```
uclampset -a -M 1024 -p <pid>
```

re-applied on a 250 ms interval, aborting at 95 °C junction or 42 °C
shell, failing back to stock. That loop is `gb7_unclamp_loop.sh` in the
same toolchain; `mitigation/experimental/` reuses the abort logic.

If you do not have the host driver, the equivalent on-device steps are:

1. Preconditions. Force-stop `com.primatelabs.parkdale` (or your package).
   Screen on. Cool. Record ceilings.
2. Arm control: start the sampler / `diagnose.sh` polling, start the
   benchmark, do not touch `uclamp`.
3. Cool down. Force-stop again. Confirm ceilings have not drifted.
4. Arm unclamp: start the same sampler, start
   `uclampset -a -M 1024 -p <pid>` in a 250 ms loop with the 95 °C / 42 °C
   abort, start the benchmark.
5. Record score, version, per-thread `uclamp.max`, prime residency,
   junction and shell, and the ceilings throughout.

Do not change cpufreq, cpusets, the governor, thermal configuration, or
any module parameter between arms. The point of this pair is that only
`uclamp.max` moved.

Expected shape, from `data/ab-result.txt`, Geekbench 7, ceilings
2 918 400 / 3 283 200, `cfb=0`:

| | control | unclamp |
|---|---|---|
| worker `uclamp.max` | 346 | 1024 (one sample at 466) |
| prime residency | 8.0% | 59.5% |
| single-core | 934 | 2126 |
| multi-core | 6017 | 8386 |
| junction p95 | 52.1 °C | 87.2 °C |
| junction peak | 78.4 °C | 95.0 °C |
| shell max | 35.0 °C | 36.1 °C |

The original unclamp arm aborted at 98.4 °C. That is expected, not a
failed run. The phone will not feel hot. Supervise it anyway.

The arms were not repeated or order-reversed. A reproduction that only
runs `--arm unclamp` and compares against the numbers above is not an A/B.

---

## Out of scope here

Real-workload A/Bs (compile, decompress, video export) have harnesses
under `experiments/real-workloads/` and are **unmeasured**. Do not quote
those scripts as evidence that those workloads are affected; they exist
so the measurement can be made. See that directory's README.
