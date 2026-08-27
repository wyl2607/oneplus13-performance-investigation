#!/usr/bin/env python3
"""Host-side session driver for the R4 burst-detector holdout
(experiments/burst-detector-holdout/README.md, r4-plan.csv).

Executes the frozen 88-run plan in order against a device backend, one run
at a time. Never reshuffles the plan (its sha256 is checked against
r4-plan.sha256 before anything runs), never overwrites a completed run's
output, and fails the whole session closed -- not a warning plus a
continue -- on a cleanup-verification failure, a module-state-set failure,
or a hard thermal gate, per the boost-exit safety invariant promoted in
PR #21 (docs/METHODOLOGY.md, "Safety invariant: boost exit must be
verified").

Device interaction itself lives in AdbDevice, which shells out to adb and
experiments/burst-detector-holdout/device/run-r4-one.sh. Everything else in
this file -- plan freezing, checkpoint/resume, thermal gating, human-assisted
pauses, replacement-id allocation -- is plain Python exercised by
tests/test_r4_holdout_runner.py against FakeDevice, so it can be validated
without a phone attached (Phase 8 dry run).
"""

import argparse
import csv
import hashlib
import io
import json
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

# workload_id -> app-manifest slot. Five interaction_transition workloads
# need a real installed app; the other six do not (README, "Workload roles").
AUTOMATABLE_SLOTS = {
    "app_launch_cold": "APP_A",
    "app_launch_warm": "APP_A",
    "app_switch": "APP_B",
    "browser_scroll": "APP_C",
    "camera_launch": "APP_D",
}
SYNTHETIC_WORKLOADS = {"synthetic_compute", "synthetic_wake"}
HUMAN_ASSISTED_WORKLOADS = {
    "steady_game_title", "steady_gameplay", "video_playback", "background_download",
}

THERMAL_SOFT_J = 92000
THERMAL_HARD_J = 95000
DEFAULT_DURATION_S = 30
DEFAULT_COOLDOWN_POLL_S = 30
DEFAULT_COOLDOWN_MAX_WAIT_S = 900

# Statuses a run can end in that are safe to record and move on from.
CONTINUE_STATUSES = {"OK", "NO_TOTALTIME_PARSED"}
# This-run-only failures: mark invalid, queue a replacement, keep going.
RETRYABLE_STATUSES = {"RUN_ABORT_THERMAL_92", "THERMAL_ABOVE_SOFT_GATE_AT_START", "OPERATOR_SKIPPED"}
# Whole-session fail-closed statuses: stop immediately, do not queue past this row.
SESSION_STOP_STATUSES = {
    "CLEANUP_VERIFY_FAILED", "MODULE_SET_FAILED", "SESSION_STOP_THERMAL_95",
}


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


class PlanIntegrityError(Exception):
    pass


class SessionAlreadyStopped(Exception):
    pass


class DeviceMismatch(Exception):
    pass


class SessionStop(Exception):
    """Raised to unwind the run loop on a fail-closed condition."""

    def __init__(self, reason, run_id=None):
        super().__init__(reason)
        self.reason = reason
        self.run_id = run_id


@dataclass
class RunResult:
    status: str
    exit_code: int
    raw_text: str
    observer_path: str = ""
    thermal_pre_j: "int | None" = None
    thermal_pre_s: "int | None" = None


# --- plan loading ---------------------------------------------------------

def load_frozen_plan(plan_path, sha256_path):
    data = Path(plan_path).read_bytes()
    actual = sha256_bytes(data)
    expected_raw = Path(sha256_path).read_text(encoding="utf-8").strip()
    expected = expected_raw.split()[0] if expected_raw else ""
    if actual != expected:
        raise PlanIntegrityError(
            f"{plan_path} sha256 {actual} does not match frozen {expected} "
            f"in {sha256_path} -- the holdout plan must not be regenerated "
            f"or reshuffled once a session has started"
        )
    rows = list(csv.DictReader(io.StringIO(data.decode("utf-8"))))
    if not rows:
        raise PlanIntegrityError(f"{plan_path} has no rows")
    return rows


def read_app_manifest(path):
    """slot -> {package, launch_activity}. Missing file is fine for a session
    that never reaches an automatable workload (e.g. a resume that only has
    human-assisted rows left); it is required at the point of use, not here.
    """
    p = Path(path)
    if not p.exists():
        return {}
    out = {}
    with p.open(newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            slot = (row.get("app_slot") or "").strip()
            if not slot or slot.startswith("#"):
                continue
            out[slot] = {
                "package": (row.get("package") or "").strip(),
                "launch_activity": (row.get("launch_activity") or "").strip(),
            }
    return out


# --- session state ---------------------------------------------------------

def default_state():
    return {
        "plan_sha256": None,
        "runner_commit": None,
        "device_fingerprint": None,
        "created_at": None,
        "updated_at": None,
        "completed": {},      # run_id -> {status, timestamp, out, observer_out, module_state, workload_id}
        "invalid": {},        # run_id -> {status, timestamp, replaced_by}
        "replacements": {},   # new_run_id -> original_run_id
        "thermal_log": [],    # [{run_id, phase, junction_c, shell_c, timestamp}]
        "last_completed_run": None,
        "session_stopped": False,
        "stop_reason": None,
        "stop_run_id": None,
        "stopped_at": None,
        "stop_history": [],
    }


def load_state(path):
    p = Path(path)
    if not p.exists():
        return default_state()
    return json.loads(p.read_text(encoding="utf-8"))


def save_state_atomic(path, state):
    state["updated_at"] = now_iso()
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(p)


def git_head_sha(repo_root=REPO_ROOT):
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo_root, capture_output=True,
            text=True, check=True, timeout=10,
        )
        return out.stdout.strip()
    except Exception:
        return None


# --- plan queue: resolve completed/invalid rows into what still needs running

def next_replacement_id(original_id, state):
    n = 1
    while True:
        candidate = f"{original_id}-R{n}"
        if candidate not in state["completed"] and candidate not in state["invalid"]:
            return candidate
        n += 1


def build_queue(plan_rows, state):
    """Yield (run_id, plan_row) pairs still needing an attempt, in frozen
    plan order. A row already in `completed` is skipped. A row in `invalid`
    without a completed replacement yields one more attempt under a new
    run_id (the frozen row's original run_id is never reused and never
    overwritten)."""
    queue = []
    for row in plan_rows:
        run_id = row["run_id"]
        if run_id in state["completed"]:
            continue
        if run_id in state["invalid"]:
            replaced_by = state["invalid"][run_id].get("replaced_by")
            if replaced_by and replaced_by in state["completed"]:
                continue
            new_id = replaced_by or next_replacement_id(run_id, state)
            queue.append((new_id, row))
            continue
        queue.append((run_id, row))
    return queue


# --- device backends --------------------------------------------------------

class Device:
    def fingerprint(self):
        raise NotImplementedError

    def screen_on(self):
        raise NotImplementedError

    def thermal_milli_c(self):
        """Return (junction_milli_c, shell_milli_c), either may be None."""
        raise NotImplementedError

    def push_scripts(self):
        raise NotImplementedError

    def run(self, run_id, row, package, activity, duration, out_path, observer_out_path):
        raise NotImplementedError


class AdbDevice(Device):
    DEVICE_DIR = "/data/local/tmp/op13-r4-device"

    def __init__(self, serial=None, adb="adb"):
        self.serial = serial
        self.adb = adb

    def _adb(self, args, timeout=60):
        cmd = [self.adb]
        if self.serial:
            cmd += ["-s", self.serial]
        cmd += args
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    def _shell(self, script, timeout=600):
        return self._adb(["shell", "su", "-c", script], timeout=timeout)

    def fingerprint(self):
        out = self._adb(["shell", "getprop", "ro.serialno"])
        return out.stdout.strip() or self.serial or "unknown-device"

    def screen_on(self):
        out = self._shell("dumpsys display | grep -m1 mScreenState")
        return "ON" in out.stdout.upper()

    def thermal_milli_c(self):
        script = (
            "for z in /sys/class/thermal/thermal_zone*; do "
            "t=$(cat $z/type 2>/dev/null); "
            "case \"$t\" in cpu-1-1-1) echo J:$(cat $z/temp);; "
            "shell_front) echo S:$(cat $z/temp);; esac; done"
        )
        out = self._shell(script)
        j = s = None
        for line in out.stdout.splitlines():
            if line.startswith("J:"):
                j = int(line[2:].strip() or 0)
            elif line.startswith("S:"):
                s = int(line[2:].strip() or 0)
        return j, s

    def push_scripts(self):
        device_dir = REPO_ROOT / "experiments" / "burst-detector-holdout" / "device"
        tools_dir = REPO_ROOT / "tools"
        self._adb(["shell", "mkdir", "-p", self.DEVICE_DIR])
        for src in (device_dir / "common.sh", device_dir / "run-r4-one.sh",
                    tools_dir / "dominant-thread-observer.sh"):
            self._adb(["push", str(src), f"{self.DEVICE_DIR}/{src.name}"])
        self._shell(f"chmod 755 {self.DEVICE_DIR}/run-r4-one.sh {self.DEVICE_DIR}/dominant-thread-observer.sh")

    def run(self, run_id, row, package, activity, duration, out_path, observer_out_path):
        remote_out = f"{self.DEVICE_DIR}/raw/{run_id}.log"
        remote_obs = f"{self.DEVICE_DIR}/raw/{run_id}.observer.log"
        self._adb(["shell", "mkdir", "-p", f"{self.DEVICE_DIR}/raw"])
        args = [
            "--run-id", run_id,
            "--workload", row["workload_id"],
            "--module-state", row["module_state"],
            "--out", remote_out,
            "--observer-out", remote_obs,
            "--duration", str(duration),
        ]
        if package:
            args += ["--package", package]
        if activity:
            args += ["--activity", activity]
        script = "sh {}/run-r4-one.sh {}".format(
            self.DEVICE_DIR, " ".join(f"'{a}'" for a in args)
        )
        proc = self._shell(script, timeout=duration + 120)
        self._adb(["pull", remote_out, str(out_path)])
        self._adb(["pull", remote_obs, str(observer_out_path)])
        raw_text = Path(out_path).read_text(encoding="utf-8", errors="replace") if Path(out_path).exists() else ""
        status = parse_result_status(raw_text)
        return RunResult(status=status or "UNKNOWN", exit_code=proc.returncode, raw_text=raw_text,
                          observer_path=str(observer_out_path))


def parse_result_status(raw_text):
    for line in raw_text.splitlines():
        if line.startswith("RESULT ") and "status=" in line:
            for tok in line.split():
                if tok.startswith("status="):
                    return tok[len("status="):]
    return None


class FakeDevice(Device):
    """In-memory device for tests and --simulate dry runs. `script` maps
    run_id -> RunResult (or a callable returning one), so a test can inject
    a CLEANUP_VERIFY_FAILED, a thermal breach, or a plain OK per run."""

    def __init__(self, script=None, fingerprint="FAKE-DEVICE-0001",
                 screen_on=True, thermal=(60000, 30000)):
        self.script = script or {}
        self._fingerprint = fingerprint
        self._screen_on = screen_on
        self._thermal = thermal
        self.pushed = False
        self.calls = []

    def fingerprint(self):
        return self._fingerprint

    def screen_on(self):
        return self._screen_on

    def thermal_milli_c(self):
        return self._thermal

    def push_scripts(self):
        self.pushed = True

    def run(self, run_id, row, package, activity, duration, out_path, observer_out_path):
        self.calls.append(run_id)
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        entry = self.script.get(run_id, RunResult(status="OK", exit_code=0, raw_text=f"RESULT run_id={run_id} status=OK\n"))
        if callable(entry):
            entry = entry(run_id, row)
        Path(out_path).write_text(entry.raw_text, encoding="utf-8")
        Path(observer_out_path).write_text("META|version=2\n", encoding="utf-8")
        return entry


# --- run loop ---------------------------------------------------------------

@dataclass
class RunnerConfig:
    duration_s: int = DEFAULT_DURATION_S
    cooldown_poll_s: int = DEFAULT_COOLDOWN_POLL_S
    cooldown_max_wait_s: int = DEFAULT_COOLDOWN_MAX_WAIT_S
    allow_device_mismatch: bool = False
    raw_dir: Path = None
    app_manifest: dict = field(default_factory=dict)
    confirm_fn: "callable" = input
    sleep_fn: "callable" = time.sleep
    max_runs: "int | None" = None


def prepare_workload_prompt(workload_id, run_id, notes):
    return (
        f"\n=== PREPARE_WORKLOAD {workload_id} (run {run_id}) ===\n"
        f"{notes}\n"
        "Get the real content running on the device now.\n"
        "Press Enter to start capture, or type 'skip' / 'abort': "
    )


def wait_for_screen_on(device, cfg):
    while not device.screen_on():
        cfg.confirm_fn(
            "Screen does not look ON. Unlock the device and press Enter to re-check: "
        )


def preflight_thermal(device, cfg, run_id, state):
    j, s = device.thermal_milli_c()
    state["thermal_log"].append({
        "run_id": run_id, "phase": "pre", "junction_c": (j / 1000 if j is not None else None),
        "shell_c": (s / 1000 if s is not None else None), "timestamp": now_iso(),
    })
    if j is not None and j >= THERMAL_HARD_J:
        raise SessionStop("THERMAL_HARD_AT_PREFLIGHT", run_id)
    waited = 0
    while j is not None and j >= THERMAL_SOFT_J:
        if waited >= cfg.cooldown_max_wait_s:
            return False  # caller marks this run invalid/retryable, does not stop the session
        cfg.sleep_fn(cfg.cooldown_poll_s)
        waited += cfg.cooldown_poll_s
        j, s = device.thermal_milli_c()
    if waited:
        state["thermal_log"].append({
            "run_id": run_id, "phase": "cooldown_wait_s", "value": waited, "timestamp": now_iso(),
        })
    return True


def resolve_package(workload_id, cfg):
    if workload_id not in AUTOMATABLE_SLOTS:
        return None, None
    slot = AUTOMATABLE_SLOTS[workload_id]
    entry = cfg.app_manifest.get(slot)
    if not entry or not entry.get("package"):
        raise PlanIntegrityError(
            f"workload {workload_id} needs app-manifest slot {slot}, but it is "
            f"missing or has no package. Copy "
            f"experiments/burst-detector-holdout/app-manifest.example.csv to "
            f"app-manifest.local.csv and fill in a real package for {slot}."
        )
    return entry["package"], entry.get("launch_activity") or None


def run_one(run_id, row, device, cfg, state):
    workload_id = row["workload_id"]
    wait_for_screen_on(device, cfg)

    ok = preflight_thermal(device, cfg, run_id, state)
    if not ok:
        state["invalid"][run_id] = {
            "status": "THERMAL_ABOVE_SOFT_GATE_AT_START", "timestamp": now_iso(), "replaced_by": None,
        }
        return

    if workload_id in HUMAN_ASSISTED_WORKLOADS:
        reply = cfg.confirm_fn(prepare_workload_prompt(workload_id, run_id, row.get("notes", ""))).strip().lower()
        if reply == "abort":
            raise SessionStop("OPERATOR_ABORT", run_id)
        if reply == "skip":
            state["invalid"][run_id] = {
                "status": "OPERATOR_SKIPPED", "timestamp": now_iso(), "replaced_by": None,
            }
            return

    package, activity = resolve_package(workload_id, cfg)

    out_path = cfg.raw_dir / f"{run_id}.log"
    observer_out_path = cfg.raw_dir / f"{run_id}.observer.log"
    for path in (out_path, observer_out_path):
        if path.exists():
            stale = path.with_name(path.name + f".stale-{int(time.time())}")
            path.rename(stale)

    result = device.run(run_id, row, package, activity, cfg.duration_s, out_path, observer_out_path)

    j, s = device.thermal_milli_c()
    state["thermal_log"].append({
        "run_id": run_id, "phase": "post", "junction_c": (j / 1000 if j is not None else None),
        "shell_c": (s / 1000 if s is not None else None), "timestamp": now_iso(),
    })

    record = {
        "status": result.status, "timestamp": now_iso(), "out": str(out_path),
        "observer_out": str(observer_out_path), "module_state": row["module_state"],
        "workload_id": workload_id,
    }

    if result.status in CONTINUE_STATUSES:
        state["completed"][run_id] = record
        state["last_completed_run"] = run_id
        return

    if result.status in SESSION_STOP_STATUSES:
        # Keep the data -- do not delete a hot or failed run -- but the
        # session must not proceed past it (fail closed, not a warning).
        state["invalid"][run_id] = {**record, "replaced_by": None}
        raise SessionStop(result.status, run_id)

    # RUN_ABORT_THERMAL_92 and anything else not explicitly whitelisted as
    # safe to continue: mark invalid, a replacement id will be queued next
    # time build_queue runs, and stop only if it is not in RETRYABLE_STATUSES
    # (unknown statuses are conservatively fatal, not silently retried).
    state["invalid"][run_id] = {**record, "replaced_by": None}
    if result.status not in RETRYABLE_STATUSES:
        raise SessionStop(f"UNRECOGNIZED_STATUS:{result.status}", run_id)


def run_session(plan_path, plan_sha256_path, state_path, device, cfg, acknowledge_stop=False):
    plan_rows = load_frozen_plan(plan_path, plan_sha256_path)
    state = load_state(state_path)

    if state["session_stopped"]:
        if not acknowledge_stop:
            raise SessionAlreadyStopped(
                f"session previously stopped: {state['stop_reason']} at run "
                f"{state['stop_run_id']}. Clear the underlying problem by hand, "
                f"then re-run with --acknowledge-stop to resume."
            )
        state["stop_history"].append({
            "reason": state["stop_reason"], "run_id": state["stop_run_id"],
            "stopped_at": state["stopped_at"], "acknowledged_at": now_iso(),
        })
        state["session_stopped"] = False
        state["stop_reason"] = None
        state["stop_run_id"] = None
        state["stopped_at"] = None

    plan_sha = sha256_bytes(Path(plan_path).read_bytes())
    if state["plan_sha256"] is None:
        state["plan_sha256"] = plan_sha
        state["runner_commit"] = git_head_sha()
        state["created_at"] = now_iso()
    elif state["plan_sha256"] != plan_sha:
        raise PlanIntegrityError("resumed session's frozen plan does not match the plan on disk")

    fp = device.fingerprint()
    if state["device_fingerprint"] is None:
        state["device_fingerprint"] = fp
    elif state["device_fingerprint"] != fp and not cfg.allow_device_mismatch:
        raise DeviceMismatch(
            f"session was started against device {state['device_fingerprint']!r}, "
            f"this device reports {fp!r}"
        )

    save_state_atomic(state_path, state)
    device.push_scripts()

    queue = build_queue(plan_rows, state)
    if cfg.max_runs is not None:
        queue = queue[: cfg.max_runs]

    for run_id, row in queue:
        try:
            run_one(run_id, row, device, cfg, state)
        except SessionStop as exc:
            state["session_stopped"] = True
            state["stop_reason"] = exc.reason
            state["stop_run_id"] = exc.run_id
            state["stopped_at"] = now_iso()
            save_state_atomic(state_path, state)
            raise
        save_state_atomic(state_path, state)

    return state


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--plan", default=str(REPO_ROOT / "experiments/burst-detector-holdout/r4-plan.csv"))
    ap.add_argument("--plan-sha256", default=str(REPO_ROOT / "experiments/burst-detector-holdout/r4-plan.sha256"))
    ap.add_argument("--state", default=str(REPO_ROOT / "experiments/burst-detector-holdout/raw/session-state.json"))
    ap.add_argument("--raw-dir", default=str(REPO_ROOT / "experiments/burst-detector-holdout/raw"))
    ap.add_argument("--app-manifest", default=str(REPO_ROOT / "experiments/burst-detector-holdout/app-manifest.local.csv"))
    ap.add_argument("--serial", default=None)
    ap.add_argument("--duration", type=int, default=DEFAULT_DURATION_S)
    ap.add_argument("--simulate", action="store_true",
                     help="use an in-memory fake device instead of adb (dry runs only)")
    ap.add_argument("--interactive-simulate", action="store_true",
                     help="with --simulate, still block on real stdin for human-assisted "
                          "pauses and screen-off prompts instead of auto-confirming")
    ap.add_argument("--acknowledge-stop", action="store_true")
    ap.add_argument("--allow-device-mismatch", action="store_true")
    ap.add_argument("--max-runs", type=int, default=None)
    args = ap.parse_args(argv)

    device = FakeDevice() if args.simulate else AdbDevice(serial=args.serial)
    if args.simulate and not args.interactive_simulate:
        def confirm_fn(prompt=""):
            print(prompt + "[simulate: auto-confirmed]")
            return ""
    else:
        confirm_fn = input
    cfg = RunnerConfig(
        duration_s=args.duration,
        raw_dir=Path(args.raw_dir),
        app_manifest=read_app_manifest(args.app_manifest),
        max_runs=args.max_runs,
        allow_device_mismatch=args.allow_device_mismatch,
        confirm_fn=confirm_fn,
    )
    try:
        state = run_session(args.plan, args.plan_sha256, args.state, device, cfg,
                             acknowledge_stop=args.acknowledge_stop)
    except SessionStop as exc:
        print(f"SESSION STOPPED: {exc.reason} at run {exc.run_id}", file=sys.stderr)
        return 3
    except (PlanIntegrityError, SessionAlreadyStopped, DeviceMismatch) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print(f"completed={len(state['completed'])} invalid={len(state['invalid'])} "
          f"last={state['last_completed_run']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
