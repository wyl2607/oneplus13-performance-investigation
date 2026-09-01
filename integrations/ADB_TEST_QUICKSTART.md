# ADB live-test quickstart

This is the first live-device gate for the upstream backend integration work. The initial smoke test is **read-only**: it does not install modules, switch profiles, write sysfs, change uclamp/affinity, or reboot the phone.

## 1. Host prerequisites

- Python 3.11+
- Android platform-tools (`adb`) on `PATH`
- Phone connected over USB with USB debugging authorised
- Root available through `su`
- A clean checkout of this repository

On Windows PowerShell:

```powershell
git checkout main
git pull --ff-only
adb devices
python tools/adb-integration-smoke.py --output data/live/adb-smoke.json
```

Expected result:

- `preflight.adb_connected = true`
- `preflight.root_ok = true`
- `preflight.backend_conflict_free = true`
- `preflight.safe_for_next_controlled_arm = true`

The command exits with code `2` if the environment is not safe for a controlled arm.

## 2. What the smoke test records

The JSON includes:

- device identity, Android build fingerprint and kernel;
- SoC identifier;
- root result;
- installed/enabled state of `op13perf`, `fas-rs`, `yumi`, and `thread-opt`;
- policy0/policy6 current/max/rated frequencies and governor;
- OPlus URCC `cpu_max_freq` state when readable;
- `cpufreq_bouncing` enable state;
- current `op13perf` state/status when present;
- screen state;
- all readable thermal-zone names and temperatures.

This is enough to prove which controller owned the device before a test and to catch a contaminated setup before collecting performance data.

## 3. Conflict rule

Do **not** compare results when more than one runtime performance backend is enabled. In particular, do not run with combinations such as:

- `op13perf + yumi`
- `op13perf + fas-rs`
- `yumi + fas-rs`
- `thread-opt + another controller`

unless the experiment explicitly declares that combination as the arm being studied. The current preflight intentionally treats overlapping enabled modules as contaminated.

## 4. First live sequence

Use this order for the first phone-connected session:

1. Run the read-only smoke test and save the JSON.
2. If it fails, fix only the connection/root/backend-conflict problem first.
3. Capture a Stock baseline using the existing experiment harness.
4. Capture the current `op13perf` arm with the same workload and cooling condition.
5. Only after those two arms are reproducible should an upstream module be installed and tested.
6. Install/test **one** upstream backend at a time, reboot when its own installation instructions require it, then rerun the smoke test before collecting data.
7. Keep `Extreme` out of bare-phone testing; it remains a cooled/lab-only arm.

## 5. Data to keep for every arm

At minimum keep:

- smoke-test JSON before the arm;
- exact git commit of this repository;
- exact upstream backend/version/commit;
- workload and run order;
- frame p50/p90/p95/p99 and jank when available;
- CPU residency/frequency data;
- junction temperature peak/p95;
- shell/skin temperature when available;
- idle or steady-state power for observer-overhead tests;
- cleanup/stock-restore verification after the arm.

Do not promote an upstream component into the production path from a single benchmark win. The replacement gate is repeated A/B evidence plus no regression in thermals, idle power, recovery, or compatibility.
