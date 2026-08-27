# OnePlus 13 Device Health Baseline v1

## Goal

Build a repeatable, fail-closed health and performance regression baseline for this OnePlus 13. The suite separates device/system behavior from local tuning and carrier/network effects.

This project does **not** merge the 5G repository into this repository. Telekom NR/n78 evidence remains owned by `wyl2607/oneplus13-telekom-5g`; this repository consumes only exported summaries.

## Questions

1. Can the device discover and use Telekom n78 when RF/network conditions permit it?
2. Does the current performance tune improve or hurt 30-minute sustained workloads versus stock?
3. Does the tune materially increase screen-off idle drain or wakeups?
4. Are Wi-Fi, Bluetooth, GPS, UFS storage and RAM/background behavior healthy and stable?
5. After an OTA or tuning change, which subsystem regressed?

## Test matrix

| Domain | Primary comparison | Core metrics | Initial verdict |
| --- | --- | --- | --- |
| n78 / cellular | field locations; network-controlled | NR band/NRARFCN, NSA/SA, SS-RSRP, SS-SINR, LTE anchor/CA, throughput, latency | external evidence required |
| sustained performance | stock vs tuned, 30 min | workload throughput/frame pacing, frequencies, thermal status, battery temp, junction/skin proxies | paired A/B required |
| standby | module/tune OFF vs ON, screen off | battery delta, elapsed time, deep-sleep ratio, wakeups, thermal state | paired overnight/long-idle required |
| Wi-Fi | repeated same AP/position | RSSI, link properties, ping/loss/jitter, throughput where available | repeatability required |
| Bluetooth | idle + active device session | connection state, reconnects, disconnect count, relevant logs | no unexplained drops |
| GPS | cold/warm fixes and stationary samples | provider state, fix age, accuracy, TTFF when available, drift | no persistent loss/drift |
| UFS | idle, controlled benchmark | free space, mount/fs state, read/write benchmark output, thermal context | compare across runs; no destructive writes |
| RAM/background | fixed app set / controlled pressure | MemAvailable, swap/zRAM, PSI, LMKD evidence, process survival | no unexplained aggressive kills |

## Safety boundaries

- Read-only diagnostics by default.
- No NV/EFS/QCN/QMI writes.
- No modem band lock or NR-only forcing in this baseline.
- No filesystem fill tests.
- Storage benchmark must use a bounded temporary file and clean it up.
- Thermal gates fail closed. A hard thermal breach invalidates/stops the run.
- Stock-vs-tuned experiments must restore the prior module/tuning state after each arm.
- Raw dumps containing identifiers must not be committed.

## Canonical session layout

Each health session gets a local, gitignored directory:

```text
experiments/device-health-baseline/live/<session-id>/
  manifest.json
  preflight.txt
  summary.json
  cellular/
  sustained/
  standby/
  wifi/
  bluetooth/
  gps/
  ufs/
  ram/
```

Only sanitized summaries suitable for long-term comparison should be committed deliberately.

## Phase order

### Phase A — non-disruptive baseline

Run preflight plus Wi-Fi/Bluetooth/GPS/UFS/RAM snapshots. This establishes whether ordinary subsystems look healthy before changing any state.

### Phase B — cellular/n78

Use the existing `oneplus13-telekom-5g` Experiment 003 hunter. Export a sanitized summary into the session. Absence of n78 at one location is **not** a device failure; a failure verdict needs evidence that n78 is available to a suitable control/device or repeated evidence across known-good n78 locations.

### Phase C — sustained stock vs tuned

Run matched 30-minute arms from comparable starting thermal/battery conditions. Alternate arm order across repetitions. Do not infer a win from one run. Primary output is sustained workload utility plus thermal landing state, not peak benchmark score.

### Phase D — standby OFF vs ON

Run long screen-off paired windows with comparable charge level, radios and background conditions. Report battery percentage delta alongside charge-counter data when available; percentage alone is too coarse for small differences.

## Classification

Every domain ends in one of:

- `PASS`: sufficient evidence within the predefined criterion.
- `FAIL`: repeatable evidence of a real regression/abnormality.
- `INCONCLUSIVE`: data collected but insufficient/noisy/uncontrolled.
- `NOT_TESTED`: no valid evidence yet.

`UNKNOWN` or missing critical probes must never be silently converted into PASS.

## Attribution model

When a failure appears, classify the most likely layer only when the evidence separates it:

- `DEVICE_HARDWARE`
- `OXYGENOS_COLOROS`
- `LOCAL_TUNING_MAGISK`
- `CARRIER_NETWORK`
- `TEST_HARNESS`
- `UNKNOWN`

The baseline should prefer `UNKNOWN` over guessing.

## Current known starting point

- Persistent NR enablement has already survived three ordinary reboots in the Telekom 5G project.
- n1 NSA and n1 SA have both been observed; this establishes basic NR capability but not n78 validation.
- Existing performance work has shown real uclamp/DVFS effects, but the 30-minute stock control needed for sustained-performance attribution is still missing.
- The existing watchdog has a bounded post-wake stock-clamp window; standby impact of shortening/replacing it has not been established.
