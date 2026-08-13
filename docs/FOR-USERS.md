[English](FOR-USERS.md) · [简体中文](FOR-USERS.zh-CN.md)

# For OnePlus 13 owners — why your phone scores half of what it should

If you have benchmarked a OnePlus 13 and got a number far below what the same phone gets
elsewhere, this document explains what is happening, how to check it yourself in two commands,
and what your options are.

It is written for the OnePlus 13 (CPH2653/CPH2655, Snapdragon 8 Elite / SM8750) but the
mechanism is an OPLUS kernel module, so other OnePlus and OPPO devices very likely carry it
too. **If you test one, please open an issue — see [Help wanted](#help-wanted).**

---

## The short version

Your phone has two fast "prime" CPU cores (CPU6 and CPU7, rated 4.32 GHz) and six slower ones
(CPU0–CPU5, 3.53 GHz).

An OPLUS kernel module called **`oplus_bsp_task_overload`** watches for threads that stay busy
on the prime cores. When it finds one, it decides that thread is "abnormal" and caps how much
CPU the scheduler is allowed to believe it needs. The cap is low enough that the thread now
fits comfortably on a *mid* core — so Linux's scheduler, working exactly as designed, moves it
there and leaves it there.

The result: **your benchmark runs on the slow cores while the two fast cores sit idle.**

On the reference device, lifting only that cap — changing nothing else at all — moved
Geekbench 7 single-core from **934 to 2126**, and the share of time the benchmark spent on the
prime cores from **8% to 59.5%**.

### What it is *not*

This trips up everyone who investigates it, because every normal diagnostic looks perfectly
healthy:

| What you would check | What it says |
|---|---|
| CPU temperature | 40–50 °C. The trip point is 105 °C. |
| `Thermal Status` | `0` (NONE) for the whole run |
| Thermal cooling devices | all 20 at `cur_state=0` |
| `scaling_cur_freq` | normal |
| `scaling_max_freq` | not being lowered |
| cpuset / affinity | `top-app`, all 8 CPUs allowed |
| Governor | `walt`, normal |

**It is not thermal throttling, and your phone is not defective.** Scaled to its rated clock,
the reference device measured *slightly faster* than a healthy comparison unit once the cap
was lifted.

The only place the problem is visible is a per-thread scheduler file that no mainstream tool
reads.

---

## Check it yourself

**Root is required** to read another process's scheduler state. There is no way to see this
without it.

With the phone connected over ADB, run a benchmark or any sustained CPU task, and while it is
running:

```sh
adb shell su -c 'cat /proc/task_overload/abnormal_task'
```

If the module is present and has acted, you get a table like this:

```
pid    uid    limit_flag  comm             date           temp  freq
26298  10xxx  466         pool-5-thread-1  1786639362457  0     3283200
```

`limit_flag` is the cap. **`1024` means untouched. Anything lower is a clamped thread.**

To confirm it is really on the thread, with `<pkg>` being the app you are testing:

```sh
adb shell su -c 'grep -H "uclamp.max" /proc/$(pidof <pkg>)/task/*/sched'
```

A healthy thread reads `uclamp.max : 1024`. A clamped one reads the `limit_flag` value.

### What the numbers mean

The cap is not a constant. It is computed from what the prime cluster's clock happened to be
at the moment your thread was judged:

```
limit_flag = floor(0.6 × 1024 × prime_current_freq / 4320000)
```

So the thread is left with 60% of the performance it was using. And because the prime clock
varies, **the cap varies too** — which is why repeated benchmark runs on the same phone give
wildly different scores. On the reference device: 934, 1145, 1229 across three runs, tracking
caps of 346, 466 and 466. That is a 31% spread, and it is not noise.

**If you have been comparing single benchmark numbers between OnePlus devices, you have been
comparing samples from a distribution, not measurements.**

---

## What triggers it

Measured with a controlled busy loop:

- **App processes only.** Identical workload run as `root` or as `system` is written into the
  table with `limit_flag = 1024` and never actually clamped. Only ordinary app UIDs get capped.
  (This also means a benchmark you run from a root shell will *not* reproduce the problem.)
- **Only while the thread is on a prime core.** A loop pinned to CPU0–5 was never clamped in
  45 seconds. The same loop pinned to CPU6–7 was clamped in 5.1 seconds.
- **Within seconds.** Six trials: five clamped inside 6 seconds, one at 27 seconds.

Put together, it is a one-way ratchet:

```
your thread gets busy
  -> the scheduler correctly promotes it to a prime core
  -> the guard sees it there and caps it
  -> the thread falls back to a mid core
  -> on a mid core it can never trigger again, so it never gets promoted back
```

It penalises exactly the threads the scheduler judged correctly, and there is no way back.

### What is affected in real life

Anything that keeps one thread busy for more than a few seconds:

- benchmarks
- video export and transcoding
- large photo edits
- code compilation
- emulators
- on-device model inference
- large archive extraction

**App launches are not affected** — a cold start finishes in 0.5–2 s, before the guard engages.
That is consistent with the measurement that removing the *other* OPLUS limiter made no
difference to launch times either. Everyday responsiveness is genuinely fine. This costs you
specifically on long, heavy, single-threaded work — which is exactly the work where you notice.

---

## Why the module exists

It is worth being fair to it.

When the cap was lifted and the benchmark actually used the prime cores, the reference device's
CPU junction temperature ran at **87 °C at the 95th percentile, peaking at 95 °C** — while the
phone's outside surface moved barely one degree, from 35.0 to 36.1 °C.

Android's thermal framework escalates on *skin* temperature, not junction. So a genuinely
runaway thread can sit at 87 °C inside this SoC indefinitely, and the phone will never feel
warm, `Thermal Status` will never leave 0, and nothing in the OS will intervene. On a sealed,
passively cooled device that is a real problem, and a guard against it is a defensible design
decision.

What the guard cannot do is tell a runaway bug apart from a user who deliberately asked for
sustained compute. It sees the same thing in both cases: a thread pinned at 100% on a fast
core.

---

## Your options

**There is no safe fix that this project can hand you as a one-click toggle, and you should be
suspicious of anyone offering one.**

The intervention that produced the +128% result was a loop resetting `uclamp.max` back to 1024
every 250 ms using Android's own `uclampset` tool:

```sh
uclampset -a -M 1024 -p <pid>
```

`uclampset` ships at `/system/bin/uclampset` on this build. The change is not persistent — it
dies with the process and is gone after a reboot. It touches nothing else: no CPU frequency
limits, no cpusets, no thermal configuration, no governor, no kernel module parameter.

But read the temperature numbers above again before doing this. During that experiment our own
safety guard aborted the run at **98.4 °C**, with 6.6 °C of margin to the hardware trip point.
Running it unattended, on a hot day, or in a case, is a materially different proposition from
running it for one supervised benchmark.

If you build anything on this, the design that makes sense is **not** "disable the guard":

1. **Per-app allowlist** — only exempt applications the user explicitly chose, never globally.
2. **Your own thermal governor** — abort back to stock behaviour on a junction threshold. Ours
   fired correctly at 95 °C and it is roughly ten lines of shell.
3. **A time limit** — allow full performance for a bounded window, then fall back, so an app
   left running does not cook the device.

The tooling that produced every measurement here is in this repository and is read-only except
where explicitly noted.

---

## Help wanted

The whole investigation is **one device, one benchmark, one A/B pair**. The most useful thing
anyone else can contribute is a data point from a different phone.

If you have a OnePlus or OPPO device with root, please run:

```sh
adb shell su -c 'ls /proc/task_overload/ 2>/dev/null && cat /proc/task_overload/abnormal_task'
adb shell su -c 'grep -c oplus_bsp_task_overload /proc/modules'
adb shell su -c 'cat /sys/devices/system/cpu/cpu*/cpu_capacity'
```

and open an issue with the output, your model, and your build number. Specifically useful:

- **Does the module exist on your device at all?** That determines whether this is a OnePlus 13
  quirk or an OPLUS-wide behaviour.
- **Does the `0.6` factor hold?** The formula is fitted to four observations from one device.
- **A Geekbench 7 score from a device where `abnormal_task` shows no clamped rows**, which would
  give the comparison this project currently lacks.

Please redact UIDs above 10000 if you would rather not publish which apps you have installed —
the analysis only needs to distinguish "app" from "root/system".

---

## Where the detail is

- [`docs/DATA.md`](DATA.md) — every measurement, in order, including the ones that turned out
  to be wrong. Sections 22–27 cover this mechanism.
- [`docs/METHODOLOGY.md`](METHODOLOGY.md) — five traps that produced confidently wrong answers
  during this investigation, and how each was caught.
- [`README.md`](../README.md) — the `cpufreq_bouncing` limiter, which is a real and separate
  mechanism, and which compounds with this one.
