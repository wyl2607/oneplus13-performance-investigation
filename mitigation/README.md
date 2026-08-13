# Mitigation

Diagnosis is read-only and safe. Everything in this directory is not.

Lifting the `uclamp.max` clamp lets a workload sit on the prime cores. On
the reference device that took Geekbench 7 single-core from 934 to 2126.
It also took CPU junction from 52.1 °C to 87.2 °C at p95, peaking at
95.0 °C, while the outside of the phone moved from 35.0 °C to 36.1 °C
([DATA.md](../docs/DATA.md) section 26). Android's thermal framework
escalates on skin, not junction ([THERMALS.md](../docs/THERMALS.md)).
The phone still feels cool. You cannot use your hand as a safety check.

The project's own abort fired at 98.4 °C during that A/B, with 6.6 °C of
margin to the 105 °C hardware trip point. That abort is the only reason
arm B did not keep climbing.

**Do not install these scripts as a boot service. Do not run them
unattended, in a case, or on a hot day. They are not a "performance
mode" for daily use.**

---

## Why a global unclamp is not an acceptable design

A loop that resets `uclamp.max` to 1024 on every process would switch
the guard off for the whole device.

The guard exists because a runaway thread on this SoC can sit at 87 °C
inside the package indefinitely without the phone ever feeling warm,
without `Thermal Status` leaving 0, and without any cooling device
moving off `cur_state=0`. The remaining backstop is Qualcomm's LMH loop
at the trip point. That is a real problem on a sealed, passively cooled
phone, and a guard against it is a defensible design.

What the guard cannot do is tell a runaway bug apart from a user who
deliberately asked for sustained compute. A global unclamp throws that
distinction away: every app, including ones the user did not choose,
including background work, including whatever will be installed next
week, runs without it. Combined with `uclamp_fork()` copying the (now
lifted) request onto every worker a pool spawns, there is no containment.

The design that does not do that is a **per-app allowlist**, a **junction
abort that fails back to stock**, and a **bounded window**. That is the
Performance mode. Extreme exists only as an opt-in for a supervised
benchmark or an actively cooled run, and it is still per-package.

---

## Three modes

**Balanced** — stock. A genuine no-op. Default. Honest entry in the list.

**Performance** — listed packages only, and only while in the foreground.
`uclamp.max` reset to 1024 on an interval. Own junction abort, bounded
duration, automatic revert when the app backgrounds or exits. A named
app the user chose, supervised.

**Extreme** — same primitive, still per-package, no foreground gate,
longer window. Requires an explicit confirmation flag. Benchmark or
active-cooling only.

The intervention primitive in Performance and Extreme is

```
uclampset -a -M 1024 -p <pid>
```

re-applied every 250 ms. It has to repeat: `oplus_bsp_task_overload`
re-flags the thread, and `uclamp_fork()` copies the clamp onto every
worker the pool spawns afterwards (DATA.md section 24). `uclampset` is
`/system/bin/uclampset` on the reference build. The change dies with the
process and is gone after a reboot. It touches nothing else: no cpufreq,
no cpuset, no thermal configuration, no governor, no module parameter.

Abort thresholds are the ones that fired correctly at 98.4 °C during the
real A/B (`gb7_unclamp_loop.sh`): junction 95 °C (`cpu-1-1-1`, by name)
or shell 42 °C (`shell_front`, by name). On abort the loop **stops
resetting** and lets the stock clamp return. Failing back to stock is
the safe direction. Zones are resolved by name (METHODOLOGY trap 3).

None of these scripts are installed by this repository. Push one, run it
under a root shell, watch the junction, stop it.

```
adb push mitigation/experimental /data/local/tmp/mitigation
adb shell su -c 'sh /data/local/tmp/mitigation/balanced.sh'
adb shell su -c 'sh /data/local/tmp/mitigation/performance.sh 300 pkg'
adb shell su -c 'sh /data/local/tmp/mitigation/extreme.sh --yes-junction-95c pkg 600'
```

Normalise line endings on the **host** before pushing. Do not `sed -i`
on the device (METHODOLOGY trap 5).

---

## Balanced

`experimental/balanced.sh` writes nothing and changes nothing. It prints
that it is stock and exits 0. It exists so the mode list is honest:
leaving the guard in place is a real choice, not the absence of a
choice.

---

## Performance

`experimental/performance.sh <max_seconds> <package> [package ...]`

- Only the packages on the command line are touched.
- A package is eligible only while one of its processes is in a
  foreground cpuset (`/top-app` or `/foreground`). Background, restricted
  or exited → the loop stops applying `uclampset` to that pid. Stock
  takes back over; the script does not write a clamp of its own.
- Duration is required. When the timer expires the loop stops. An app
  left running does not cook the device overnight.
- Junction / shell abort as above.
- Screen-on is the caller's job (`svc power stayon usb`). The script
  will refuse to start if it cannot resolve the junction sensor.

This is the design sketched in [FOR-USERS.md](../docs/FOR-USERS.md). It
has **not** been A/B'd as a daily driver. The 934 → 2126 result is one
Geekbench pair under supervision, not a warranty for any other package.

---

## Extreme

`experimental/extreme.sh --yes-junction-95c <package> [max_seconds]`

The confirmation flag is required; without it the script exits and
prints why. Default duration is 600 s if omitted.

Still one package, still the same `uclampset` primitive, still the same
95 °C / 42 °C abort. No foreground gate: a benchmark that is the only
thing running should not depend on cpuset spelling. Documented as
**benchmark or active-cooling only**. Passive, unattended, or "leave it
on overnight" is outside its contract.

The original A/B abort at 98.4 °C happened in this regime.

---

## What this directory also contains

`oneplus13_cfb_tune.sh` is the earlier `cpufreq_bouncing` watchdog. It
disables CFB and holds conservative `scaling_max_freq` ceilings. That
work predates the `uclamp.max` finding. It does not lift the placement
clamp, and the +30% it measured is most plausibly the mid-cluster
ceiling moving from 2 400 000 to 2 918 400 while the benchmark was
never on the prime pair (DATA.md section 22). It is left here as the
historical artifact. It is not one of the three modes above.

---

## Unmeasured

Whether Performance helps compile, video export, decompression or any
other real workload is `TODO: unmeasured`. The harnesses exist under
`experiments/real-workloads/` and have not been run for this tree.
Do not describe this directory as fixing those workloads.
