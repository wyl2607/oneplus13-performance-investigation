#!/usr/bin/env python3
"""Read-only ADB smoke test for the upstream performance integration layer.

This command is intentionally non-destructive. It does not install Magisk modules,
change performance levels, write sysfs, reboot, or alter uclamp/affinity state.
It establishes whether a rooted device is connected and records enough state to
make the next live experiment reproducible.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
BACKEND_TOOL = ROOT / "tools" / "upstream-backends.py"


class AdbError(RuntimeError):
    pass


def run(cmd: list[str], timeout: int = 15, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            cmd,
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=timeout,
            check=check,
        )
    except FileNotFoundError as exc:
        raise AdbError(f"command not found: {cmd[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise AdbError(f"command timed out: {' '.join(cmd)}") from exc
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        stdout = (exc.stdout or "").strip()
        detail = stderr or stdout or f"exit {exc.returncode}"
        raise AdbError(f"command failed: {' '.join(cmd)}: {detail}") from exc


class Adb:
    def __init__(self, executable: str) -> None:
        self.executable = executable

    def host(self, *args: str, check: bool = True) -> str:
        return run([self.executable, *args], check=check).stdout.strip()

    def shell(self, script: str, root: bool = False, check: bool = True) -> str:
        cmd = [self.executable, "shell"]
        if root:
            cmd += [f"su -c {shell_quote(script)}"]
        else:
            cmd += [f"sh -c {shell_quote(script)}"]
        return run(cmd, check=check).stdout.strip()


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def read_node(adb: Adb, path: str, root: bool = True) -> str | None:
    q = shell_quote(path)
    out = adb.shell(f"if [ -r {q} ]; then cat {q}; else echo __MISSING__; fi", root=root)
    return None if out == "__MISSING__" else out


def getprop(adb: Adb, name: str) -> str | None:
    value = adb.shell(f"getprop {shell_quote(name)}")
    return value or None


def thermal_snapshot(adb: Adb) -> list[dict[str, Any]]:
    script = r'''
for z in /sys/class/thermal/thermal_zone*; do
  [ -r "$z/type" ] || continue
  type=$(cat "$z/type" 2>/dev/null)
  temp=$(cat "$z/temp" 2>/dev/null)
  [ -n "$type" ] || continue
  printf '%s\t%s\t%s\n' "${z##*/}" "$type" "$temp"
done
'''.strip()
    rows: list[dict[str, Any]] = []
    for line in adb.shell(script, root=True).splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        zone, sensor_type, raw_temp = parts
        temp_mc: int | None
        try:
            temp_mc = int(raw_temp)
        except ValueError:
            temp_mc = None
        rows.append({"zone": zone, "type": sensor_type, "temp_mC": temp_mc})
    return rows


def policy_snapshot(adb: Adb, policy: int) -> dict[str, Any]:
    base = f"/sys/devices/system/cpu/cpufreq/policy{policy}"
    return {
        "policy": policy,
        "scaling_cur_freq_khz": read_node(adb, f"{base}/scaling_cur_freq", root=False),
        "scaling_max_freq_khz": read_node(adb, f"{base}/scaling_max_freq", root=False),
        "cpuinfo_max_freq_khz": read_node(adb, f"{base}/cpuinfo_max_freq", root=False),
        "scaling_governor": read_node(adb, f"{base}/scaling_governor", root=False),
    }


def backend_snapshot(adb_executable: str) -> dict[str, Any]:
    proc = run(
        [sys.executable, str(BACKEND_TOOL), "status", "--adb", adb_executable],
        timeout=20,
    )
    return json.loads(proc.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb", help="adb executable/path")
    parser.add_argument("--output", type=Path, help="optional JSON output path")
    args = parser.parse_args()

    adb = Adb(args.adb)
    payload: dict[str, Any] = {
        "schema_version": 1,
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "read_only": True,
        "warnings": [],
    }

    try:
        state = adb.host("get-state")
        if state != "device":
            raise AdbError(f"adb state is {state!r}, expected 'device'")

        root_id = adb.shell("id", root=True)
        root_ok = "uid=0" in root_id
        if not root_ok:
            raise AdbError(f"su did not return uid=0: {root_id}")

        payload["device"] = {
            "serial": adb.host("get-serialno"),
            "manufacturer": getprop(adb, "ro.product.manufacturer"),
            "model": getprop(adb, "ro.product.model"),
            "device": getprop(adb, "ro.product.device"),
            "soc_model": getprop(adb, "ro.soc.model"),
            "android_release": getprop(adb, "ro.build.version.release"),
            "sdk": getprop(adb, "ro.build.version.sdk"),
            "build_fingerprint": getprop(adb, "ro.build.fingerprint"),
            "kernel": adb.shell("uname -a"),
            "root_id": root_id,
        }
        payload["backends"] = backend_snapshot(args.adb)
        payload["cpu_policies"] = [policy_snapshot(adb, 0), policy_snapshot(adb, 6)]
        payload["oplus_nodes"] = {
            "urcc_cpu_max_freq": read_node(
                adb, "/sys/kernel/msm_performance/parameters/cpu_max_freq"
            ),
            "cpufreq_bouncing_enable": read_node(
                adb, "/sys/module/cpufreq_bouncing/parameters/enable"
            ),
            "op13perf_state": read_node(adb, "/data/adb/op13perf/state"),
            "op13perf_status": read_node(adb, "/data/adb/op13perf/status"),
            "screen": read_node(adb, "/sys/class/drm/card0-DSI-1/enabled", root=False),
        }
        payload["thermal"] = thermal_snapshot(adb)

        conflict = payload["backends"]["conflict"]
        safe = bool(conflict.get("clean_single_backend"))
        payload["preflight"] = {
            "adb_connected": True,
            "root_ok": True,
            "backend_conflict_free": safe,
            "safe_for_next_controlled_arm": safe,
        }
        if not safe:
            payload["warnings"].append(conflict.get("reason"))

        soc = (payload["device"].get("soc_model") or "").lower()
        if soc and "8750" not in soc and "8 elite" not in soc:
            payload["warnings"].append(
                f"unexpected SoC for this repository: {payload['device'].get('soc_model')}"
            )
    except (AdbError, json.JSONDecodeError) as exc:
        payload["preflight"] = {
            "adb_connected": False,
            "root_ok": False,
            "backend_conflict_free": False,
            "safe_for_next_controlled_arm": False,
        }
        payload["error"] = str(exc)

    rendered = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    print(rendered)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")

    return 0 if payload.get("preflight", {}).get("safe_for_next_controlled_arm") else 2


if __name__ == "__main__":
    raise SystemExit(main())
