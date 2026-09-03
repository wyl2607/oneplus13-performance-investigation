#!/usr/bin/env python3
"""Run the non-disruptive OnePlus 13 Device Health Baseline Phase A over ADB."""

from __future__ import annotations

import argparse
import datetime as dt
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEVICE_DIR = ROOT / "experiments" / "device-health-baseline" / "device"
LIVE_DIR = ROOT / "experiments" / "device-health-baseline" / "live"
REMOTE_DIR = "/data/local/tmp/op13-device-health"


class RunError(RuntimeError):
    pass


def run(cmd: list[str], *, capture: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(cmd, text=True, capture_output=capture)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RunError(f"command failed ({result.returncode}): {' '.join(cmd)}\n{detail}")
    return result


def adb(*args: str, capture: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["adb", *args], capture=capture)


def push_script(name: str) -> str:
    local = DEVICE_DIR / name
    if not local.exists():
        raise RunError(f"missing script: {local}")
    remote = f"{REMOTE_DIR}/{name}"
    adb("push", str(local), remote)
    return remote


def execute(remote: str) -> str:
    return adb("shell", "sh", remote).stdout


def write(session: Path, name: str, text: str) -> None:
    (session / name).write_text(text.rstrip() + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ufs", action="store_true", help="also run bounded 256 MiB temporary UFS read/write probe")
    ap.add_argument("--session-id", help="override timestamp session id")
    args = ap.parse_args()

    run(["adb", "version"])
    devices = adb("devices").stdout.splitlines()[1:]
    ready = [line for line in devices if line.strip().endswith("\tdevice")]
    if len(ready) != 1:
        raise RunError(f"expected exactly one authorized ADB device, found {len(ready)}")

    session_id = args.session_id or dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S%z")
    session = LIVE_DIR / session_id
    session.mkdir(parents=True, exist_ok=False)

    adb("shell", "mkdir", "-p", REMOTE_DIR)
    try:
        preflight = push_script("preflight.sh")
        text = execute(preflight)
        write(session, "preflight.txt", text)
        if "PREFLIGHT_PASS" not in text:
            raise RunError("preflight did not emit PREFLIGHT_PASS")

        for script, output in (
            ("snapshot.sh", "snapshot.txt"),
            ("wifi-probe.sh", "wifi.txt"),
            ("bluetooth-probe.sh", "bluetooth.txt"),
            ("gps-probe.sh", "gps.txt"),
            ("ram-probe.sh", "ram.txt"),
        ):
            remote = push_script(script)
            write(session, output, execute(remote))

        if args.ufs:
            remote = push_script("ufs-bounded.sh")
            write(session, "ufs.txt", execute(remote))

        manifest = [
            f"session_id={session_id}",
            "phase=A",
            "status=COLLECTED_NOT_YET_CLASSIFIED",
            f"ufs={'RUN' if args.ufs else 'NOT_TESTED'}",
            "privacy=SANITIZED_OUTPUTS_ONLY",
        ]
        write(session, "manifest.txt", "\n".join(manifest))
        print(f"PHASE_A_COLLECTED: {session}")
        print("No PASS/FAIL claim is made until the collected probes are reviewed.")
        return 0
    finally:
        try:
            adb("shell", "rm", "-rf", REMOTE_DIR)
        except RunError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
