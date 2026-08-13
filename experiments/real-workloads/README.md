# Real-workload harnesses

**Status: unmeasured.** These scripts exist so the measurement can be
made. Nothing in this repository has run them against a device. Nothing
in this repository should be quoted as showing that compile, decompress
or video export are affected by `oplus_bsp_task_overload`.

## Hypothesis

`oplus_bsp_task_overload` flags a thread that stays busy on the prime
cluster and then holds it on the mid cluster via `uclamp.max` (see
[ROOT_CAUSE.md](../../docs/ROOT_CAUSE.md)). Workloads that have the same
*shape* as the Geekbench single-core phase — one (or a few) threads busy
for more than a few seconds — should see the clamp and should improve
when it is lifted. Short, bursty work should not: a cold start finishes
before the guard engages (DATA.md section 20; trigger window 5–27 s).

| Workload | Shape | Expected | Measured |
|---|---|---|---|
| Compile (single-threaded, seconds or more) | sustained | affected | `TODO: unmeasured` |
| Decompress (single-threaded, seconds or more) | sustained | affected | `TODO: unmeasured` |
| Video export / transcode | sustained | affected | `TODO: unmeasured` |
| App launch, scroll, short burst | < 2 s | not affected | see below |

Cold starts under the CFB tune showed no benefit (section 20). This
guard's own launch A/B is `TODO: unmeasured`; the 5–27 s trigger window
is why launches are expected to miss it.

An expected result is not a result. Do not promote the middle column.

## How to run (do not run from this working tree's automation)

Each script takes `stock` or `unclamp` and an optional uid (default
10999, the synthetic app uid used in `data/trigger-conditions.txt`).
The workload is executed *as that uid*. A root-shell compile will not
reproduce the clamp — uid 0 is exempt (DATA.md section 27).

```
adb push experiments/real-workloads /data/local/tmp/rw
# preconditions: screen on, cool device, force-stop the uid's leftover
# processes, record ceilings. see docs/REPRODUCTION.md
adb shell su -c 'sh /data/local/tmp/rw/compile.sh stock 10999'
adb shell su -c 'sh /data/local/tmp/rw/compile.sh unclamp 10999'
```

Same pattern for `decompress.sh` and `video-export.sh`.

Each run prints a single `RESULT|...` line and writes a sample log under
`/data/local/tmp/rw-<label>-<arm>.log`. The log is a capture, not a
claim. Until someone fills in wall-clock, `uclamp.max`, prime residency
and temperatures from a real pair of runs, every one of those fields is
`TODO: unmeasured`.

## What is recorded

Sampling is the same approach as the existing toolchain
(`gb7_sampler.sh` / `gb7_uclamp_hunt.sh`), simplified to what this
hypothesis needs:

- wall-clock from `/proc/uptime` (not `date +%s%N`)
- per-thread `uclamp.max` of the workload pid, one awk pass
- prime-core residency from `/proc/stat` jiffy deltas, with the prime
  set resolved from `cpu_capacity` (not hardcoded CPU6/7)
- junction (`cpu-1-1-1`) and shell (`shell_front`) by name
- `scaling_max_freq` / `scaling_cur_freq` for every policy, before and
  during
- `Thermal Status` at start and end (dumpsys is too slow for the inner
  loop)

The unclamp arm is the same primitive as the Geekbench A/B:
`uclampset -a -M 1024 -p <pid>` every 250 ms, abort at 95 °C junction or
42 °C shell, fail back to stock.

## Preconditions (same as docs/REPRODUCTION.md)

Screen on. Cool start. Record ceilings before and during. Do not
`sed -i` the scripts on the device. If you point a script at a real
package rather than uid 10999, force-stop it first so a previous clamp
does not ride in.

A compiler, gzip, or ffmpeg may be missing. The scripts exit 2 and say
so rather than substituting a different workload. Substituting a busy
loop would recreate sections 2/6/7, which are not an app model.

## What this is not

It is not evidence. It is not a benchmark suite. It is not a reason to
describe video export, compilation or decompression as affected in
README, FOR-USERS, or any issue. Those sentences stay qualified until a
capture lands in `data/`.
