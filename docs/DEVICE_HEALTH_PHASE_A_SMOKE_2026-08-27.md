# Device Health Phase A smoke — 2026-08-27

Session: `20260827-235851+0200`

Overall verdict: **INCONCLUSIVE**. This was a smoke test of the harness, not Health Baseline #001. No evidence observed was sufficient for a device-level FAIL.

## Results

| Domain | Verdict | Evidence / limitation |
| --- | --- | --- |
| Preflight | PASS | CPH2653, Android 16, battery 85%, charging, battery temperature 32.8 C |
| Wi-Fi | NOT_TESTED | Wi-Fi was disabled. The old probe nevertheless measured 20 pings over another active network; those results are invalid as Wi-Fi evidence. |
| Bluetooth | INCONCLUSIVE | Bluetooth was enabled, manager-state parser returned UNKNOWN, and no active Bluetooth device was connected. |
| GPS/GNSS | INCONCLUSIVE | Location enabled and GNSS provider present; TTFF, accuracy and stationary drift were not exercised. |
| RAM | INCONCLUSIVE | About 14.1 GB MemAvailable and no recent LMKD marker. ADB shell could not read `/proc/pressure/*` or `/proc/swaps`. `/sys/block` exposed zRAM, proving the old `zram_present=false` result was a harness misclassification. |
| UFS | NOT_TESTED | User intentionally did not opt into the bounded storage probe for this smoke. |

## Harness findings

Two concrete harness defects were identified before the first official baseline:

1. Wi-Fi ping was unconditional. With Wi-Fi disabled, the probe could report latency/loss from cellular or another route and mislabel it as Wi-Fi evidence.
2. zRAM detection treated an unreadable `/proc/swaps` as an empty readable file, turning missing permission into `zram_present=false`.

Both are `TEST_HARNESS` findings, not device failures.

Bluetooth manager-state parsing was also broadened conservatively. Adapter enabled/requested state remains separate from active-device connection/reconnect validation.

## Cleanup / privacy validation

- Temporary device-side directory cleanup succeeded.
- Raw session remained under the gitignored `live/` path.
- Working tree remained clean after the smoke.

## Gate for Health Baseline #001

Do not call this session Baseline #001. Re-run Phase A after:

- connecting to a known Wi-Fi AP,
- preparing and actively connecting one Bluetooth device,
- applying the Wi-Fi/zRAM harness fixes,
- optionally running UFS only when explicitly desired.

GPS remains INCONCLUSIVE until an active TTFF/accuracy/drift protocol is added or performed.
