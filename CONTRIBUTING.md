# Contributing

This repository is an evidence record plus the tools used to produce it. Two
kinds of work live here, and they are not the same:

**Diagnosis is read-only and safe.** `tools/diagnose.sh`, `tools/collect-report.sh`,
and the samplers that only read `/proc` and `/sys` do not change scheduler,
cpufreq, thermal or module state. Root is required only because reading another
process's scheduler files is privileged.

**Mitigation is experimental.** Resetting `uclamp.max` lets a workload sit on
the prime cores. On the reference device that drove the CPU junction to 87.2 C
at p95 and 95.0 C peak, while the outside of the phone moved from 35.0 C to
36.1 C. Android's thermal framework escalates on skin temperature, not
junction, so nothing in the OS intervenes and the phone still feels cool. Do
not install a mitigation script as a boot service. Do not run one unattended,
in a case, or on a hot day. Read `mitigation/README.md` before touching
anything under `mitigation/experimental/`.

## What is useful

The investigation is one device, one benchmark, one A/B pair. The single most
useful contribution is a **device report**, especially from a non-OnePlus-13
OPLUS phone (other OnePlus, OPPO, realme, and related builds). That is what
decides whether `oplus_bsp_task_overload` is a OnePlus 13 quirk or an
OPLUS-wide behaviour.

A useful report answers:

- Is `oplus_bsp_task_overload` loaded?
- What does `cpu_capacity` look like per CPU?
- Which `limit_flag` values appear in `/proc/task_overload/abnormal_task`
  while an app is under sustained load?
- A Geekbench 7 (or other named benchmark) score **and version**, with the
  clamp state recorded in the same session.

Use the [device-report issue template](.github/ISSUE_TEMPLATE/device-report.yml)
or paste the output of `tools/collect-report.sh`. The script is read-only.

A second useful class of contribution is a measurement this tree marks
`TODO: unmeasured`: a mid-cluster load driven to ~65 C (to separate cluster
from temperature), a fifth `limit_flag` point at a clock other than the four
already fitted, or a real-workload A/B from `experiments/real-workloads/`.
Do not fill those gaps with guesses. If you cannot measure it, leave it
unmeasured.

## What is not useful

- A single benchmark number with no `limit_flag`, no build, and no kernel.
- A "fix" that globally disables the guard. The guard exists because a
  runaway thread on this SoC can sit at 87 C inside the package indefinitely
  without the phone ever feeling warm. A per-app allowlist with a junction
  abort is the design; a global unclamp is not.
- Rewriting `docs/DATA.md`. It is a chronological record, including entries
  that were later corrected. Append, do not edit existing sections.
- Invented numbers. Every figure in this project came from a capture. If a
  number is not in `data/` or `docs/DATA.md`, write `TODO: unmeasured`.

## Privacy

Redact UIDs **>= 10000** to `10xxx` in anything you paste. App UIDs plus
thread names are a partial inventory of installed apps. The analysis only
needs to distinguish app (`uid >= 10000`) from root (`0`) and system
(`1000`). `tools/collect-report.sh` does this redaction itself; still check
before you submit.

Do not attach `logcat`, `bugreport`, Magisk config, or anything that carries
a serial, IMEI, Android ID, account, or token. See `docs/PRIVACY.md`.

## Patches

- Match the existing prose: plain, specific, no marketing tone, no
  exclamation marks. State uncertainty with the same grades already used
  (PROVEN / HIGHLY LIKELY / UNKNOWN). Do not upgrade a grade.
- Keep line length around 100 characters.
- Shell is `/system/bin/sh`. No bash arrays, no `[[`, no `date +%s%N`.
  Resolve thermal zones by name, not index. See `docs/METHODOLOGY.md`
  traps 3 and 5, and do not use `${var#*(}` — mksh can swallow the rest of
  the script.
- Do not add a default path that writes to the device under test from a
  host-side helper. Diagnosis stays read-only.

Findings are observations about specific devices. No warranty.
