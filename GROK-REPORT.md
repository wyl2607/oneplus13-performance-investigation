# GROK-REPORT

Work in `C:\Users\yzwdm\oneplus13-cpufreq-bouncing`. No `adb`, no `gh`, no
`git push`. No existing `docs/DATA.md` section was edited. Scripts under
`mitigation/experimental/` and `experiments/real-workloads/` were written
only, not installed and not executed against the phone.

## Task 1 — LICENSE, CONTRIBUTING.md, issue templates

Created:

- `LICENSE` — MIT, copyright `wyl2607`, 2026
- `CONTRIBUTING.md` — diagnosis vs mitigation split, device-report
  emphasis (especially non-OnePlus-13 OPLUS), UID >= 10000 redaction
- `.github/ISSUE_TEMPLATE/device-report.yml` — model, build, kernel,
  module presence, `cpu_capacity`, clamped `limit_flag` values, benchmark
  score and version, notes, required UID-redaction checkbox

Could not do: nothing in this task.

`TODO: unmeasured` in this file is a contribution guideline, not a new
claim.

## Task 2 — docs/ROOT_CAUSE.md

Created `docs/ROOT_CAUSE.md`. Linear chain: module, `abnormal_task`
columns, formula, uid gate, prime-only trigger and ratchet,
`cpu_capacity` / 466 < 792, A/B. Confidence grades copied verbatim
(PROVEN / HIGHLY LIKELY / UNKNOWN) and not upgraded. Confounds stated:
cluster-vs-temperature not separated; formula fitted, not derived.

Could not do: the task packet asked for "the five observed points".
`docs/DATA.md` section 25 and `data/ab-arm-a-control.txt` document **four**
unique `(prime_cur_freq, limit_flag)` pairs:

| freq | limit_flag |
|---|---|
| 3 283 200 | 466 |
| 3 072 000 | 436 |
| 2 649 600 | 376 |
| 2 438 400 | 346 |

A fifth distinct clock is not in the repo. I did not invent one.

`TODO: unmeasured` in this file:

- fifth `limit_flag` point at a clock other than the four above
- mid-cluster load driven to 65 °C (cluster vs temperature)
- A/B ordering effect (arms not repeated or reversed)
- video export / compile / emulator / on-device inference (same *shape*
  as the reproducer; not measured)

## Task 3 — tools/collect-report.sh

Replaced the CFB-era script. New script is `/system/bin/sh`, read-only,
no logcat, no on-device writes. Prints one pasteable block: model, build,
kernel, SoC, every `cpu_capacity`, every cpufreq policy (min/max/governor),
whether `oplus_bsp_task_overload` is loaded and whether
`/proc/task_overload/abnormal_task` is readable, the full table with
uid >= 10000 redacted to `10xxx`, optional per-thread `uclamp.max`,
`Thermal Status`, and cpu-/shell_* zones by name. Prime cluster is
resolved from `cpu_capacity`. Avoids `${var#*(}` and on-device `sed -i`.

Extra, still read-only: screen/wake (trap 2) and a short
`cpufreq_bouncing` stanza so the older `limit_level` question in README
still has a place to land.

Could not do: syntax-check on the phone (`sh -n` via adb is forbidden).
Not run.

## Task 4 — docs/THERMALS.md

Created `docs/THERMALS.md`. Consolidates DATA.md sections 2, 6, 7, 13,
17, 18, 26. Leads with the section 27 correction: the root-shell
`taskset` loop is uid-gate exempt, so those numbers are thermal
characterisation, not an app model. Load-bearing results: framework
escalates on skin, 15-minute walk-down to 1 689 600, active-cooling A/B,
cost of lifting the clamp (p95 52.1 → 87.2 °C, peak 95.0 °C, shell
35.0 → 36.1 °C).

Could not do: nothing required that was missing, except gaps the record
already marks.

`TODO: unmeasured` in this file:

- stock 15-minute all-core control
- sustained GPU / game under the cooler (section 13 scope)

## Task 5 — docs/REPRODUCTION.md

Created `docs/REPRODUCTION.md`. Three sections: `tools/diagnose.sh`,
`tools/trigger-probe.sh` (uid 0 / 1000 / app, `taskset 3f` vs `c0`, bare
hex), A/B via `gb7_hunt.py --arm control` then `--arm unclamp`.
Preconditions restated every time. Points at METHODOLOGY traps.

Could not do: `gb7_hunt.py` / `gb7_unclamp_loop.sh` are not in this tree
(they live in the host toolchain that produced section 26). I documented
the command the investigation used and the equivalent on-device
`uclampset` loop, rather than vendoring that tree (it also holds raw
captures). Not requested to add those files.

`TODO: unmeasured` in this file: mid-cluster load at 65 °C.

## Task 6 — mitigation/ three-mode design

Changed `mitigation/README.md`. Created:

- `mitigation/experimental/common.sh` — zone-by-name abort at 95 °C /
  42 °C, same thresholds as `gb7_unclamp_loop.sh` (the loop that aborted
  at 98.4 °C in the real A/B)
- `mitigation/experimental/balanced.sh` — genuine no-op
- `mitigation/experimental/performance.sh` — per-app allowlist,
  foreground cpuset only, required duration, junction abort, revert by
  stopping `uclampset`
- `mitigation/experimental/extreme.sh` — requires `--yes-junction-95c`,
  still per-package, no foreground gate, default 600 s

README states why a global unclamp is not acceptable. Left
`mitigation/oneplus13_cfb_tune.sh` in place as the historical CFB
watchdog; it is not one of the three modes.

Could not do: did not install or run any of these, as required.

`TODO: unmeasured` in this file: whether Performance helps any real
workload.

## Task 7 — experiments/real-workloads/

Created:

- `experiments/real-workloads/README.md` — hypothesis (benchmark-shaped
  work affected, short bursts not) and current status **unmeasured**
- `experiments/real-workloads/common.sh` — sampler in the style of
  `gb7_sampler.sh` / `gb7_uclamp_hunt.sh` (uptime, zones by name,
  `/proc/stat` prime residency from `cpu_capacity`, per-thread
  `uclamp.max`, ceilings, 95 °C / 42 °C abort)
- `experiments/real-workloads/compile.sh`
- `experiments/real-workloads/decompress.sh`
- `experiments/real-workloads/video-export.sh`

Each arm is `stock` or `unclamp`. Workload runs as an app uid (default
10999). Missing clang/gzip/ffmpeg is a hard error, not a busy-loop
substitute. Every `RESULT` line is tagged `TODO: unmeasured`.

Could not do: did not execute against the phone, as required. No
compiler/ffmpeg probe on the device either (that would be adb).

`TODO: unmeasured` in this directory:

- compile stock vs unclamp (wall-clock, uclamp, prime residency, temps)
- decompress stock vs unclamp (same)
- video-export stock vs unclamp (same)
- this guard's own launch A/B (CFB-tune launches are the only launch
  numbers in the record)

## Every `TODO: unmeasured` written in this pass

Distinct gaps, collapsed:

1. Fifth `limit_flag` point at a new prime clock
2. Mid-cluster load driven to ~65 °C
3. A/B order-reversal / repeat
4. Compile / decompress / video-export (and other benchmark-shaped
   app work) under this guard
5. This guard's own app-launch A/B
6. Stock 15-minute all-core control
7. Sustained game / GPU-bound session under the cooler
8. Whether Performance mode helps any real workload

## Not done, on purpose

- No commit of this file
- No README / FOR-USERS / DATA.md edits (not in the task list). README
  question 2 still points at `tools/collect-report.sh`; the new script
  still prints CFB `limit_level` so that pointer is not dead
- `mitigation/oneplus13_cfb_tune.sh` not removed
- Host toolchain (`gb7_hunt.py` and friends) not copied in
