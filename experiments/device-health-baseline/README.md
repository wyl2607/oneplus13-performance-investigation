# Device Health Baseline

Repeatable OnePlus 13 whole-device diagnostics and regression baseline.

See `docs/DEVICE_HEALTH_BASELINE_V1.md` for protocol and attribution rules.

## Quick start

```bash
adb devices
bash experiments/device-health-baseline/device/preflight.sh
bash experiments/device-health-baseline/device/snapshot.sh > /data/local/tmp/op13-health-snapshot.txt
adb pull /data/local/tmp/op13-health-snapshot.txt
```

The scripts are intentionally read-only unless a future experiment explicitly documents a reversible state change.

## Domains

- cellular/n78: owned by `oneplus13-telekom-5g`; import sanitized summary only
- sustained: paired stock vs tuned 30-minute validation
- standby: paired tune/module OFF vs ON idle-drain validation
- Wi-Fi
- Bluetooth
- GPS/location
- UFS/storage
- RAM/zRAM/PSI/LMKD

## Privacy

Do not commit raw `dumpsys`, logcat, SIM, account, SSID/BSSID, GPS coordinate, serial, IMEI, IMSI, phone-number or MAC-address output. Raw session data belongs under `experiments/device-health-baseline/live/`, which must remain local/gitignored.
