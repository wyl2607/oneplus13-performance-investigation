# The tune — what it actually costs

This is not a free performance win. Read this before installing.

## What it does

1. Holds `cpufreq_bouncing`'s `enable` at `0`, removing the 2 438 400 / 2 400 000 clamp.
2. Sets a userspace `scaling_max_freq` ceiling of **3 283 200** (prime) and **2 918 400** (mid).
3. Re-applies both every 20 s, because the system turns CFB back on at every screen wake.

## What it does not do

- It does not touch the Qualcomm LMH/DCVS loop, the QTI thermal HAL, cooling devices, or the
  105 °C / 125 °C hardware trip points. Those all remain active.
- It does not disable screen-off power saving. URCC's screen-off cap is a separate, lower
  `freq_qos` request and still wins via `min()`.
- It does not persist across a reboot by itself if you remove the script — every value it
  writes is volatile.

## Measured cost

On the reference unit, with a pure-ALU busy loop (a worse case than Geekbench):

| | Stock | With tune |
|---|---|---|
| Single-thread junction | 51 °C | 73 °C |
| All-core junction plateau | not measured | 89 °C |
| Shell temperature | 31 °C | 34–35 °C |
| Android `Thermal Status` | 0 | 0 |

So daily junction temperatures go **up by roughly 20 °C** under sustained CPU load. The
shell barely moves, so you will not feel it, but the silicon runs hotter. Over years that is
a real electromigration and battery-ageing consideration, and it is the honest reason to
think twice rather than a disclaimer.

## Failure mode

If some vendor component ever overwrites the userspace `scaling_max_freq` request between
watchdog passes, the ceiling is lost while CFB is still disabled — the prime core would then
run unrestricted, which was measured as a stable oscillation around 88 °C peaking at 101 °C,
held below the trip point by LMH. Hot, not destructive. The watchdog closes that window
within 20 s.

## Choosing the ceiling

`3 283 200` was chosen from measurement, not preference:

- `3 513 600` → 80 °C single-thread. Viable if you want more, 25 °C of margin left.
- `3 283 200` → 73 °C single-thread. **Selected.**
- `3 072 000` → converges to the *identical* 89 °C all-core plateau as 3 283 200, so it
  sacrifices single-thread performance for zero thermal benefit. Do not use it thinking it
  is safer.

Any value you set must exist in `scaling_available_frequencies` for that policy; the script
refuses to run otherwise.

## Verifying it works

```sh
# after a reboot and a screen-off/on cycle
adb shell su -c 'cat /sys/module/cpufreq_bouncing/parameters/enable'   # expect 0
adb shell su -c 'cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq'  # expect 3283200 (screen on)
adb shell su -c 'cat /data/adb/cfb_tune.log'
```
