#!/usr/bin/env python3
"""Inspect separately-installed performance backends on a rooted Android device.

This tool deliberately does not install, start, stop, or reconfigure GPL-licensed
upstream modules. It establishes the integration boundary used by experiments:
we can identify which backends are installed/active before a run and refuse a
comparison when multiple controllers could contaminate the result.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "integrations" / "upstreams.json"


@dataclass(frozen=True)
class BackendState:
    name: str
    module_id: str | None
    installed: bool
    enabled: bool
    remove_pending: bool
    module_path: str | None


class AdbDevice:
    def __init__(self, adb: str = "adb") -> None:
        self.adb = adb

    def shell(self, script: str, root: bool = False) -> str:
        cmd = [self.adb, "shell"]
        if root:
            cmd += [f"su -c {shell_quote(script)}"]
        else:
            cmd += [f"sh -c {shell_quote(script)}"]
        result = subprocess.run(
            cmd, check=True, text=True, encoding="utf-8", capture_output=True
        )
        return result.stdout.strip()

    def path_exists(self, path: str) -> bool:
        out = self.shell(f"test -e {shell_quote(path)} && echo yes || echo no", root=True)
        return out == "yes"


def shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def load_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or not isinstance(data.get("backends"), dict):
        raise ValueError("unsupported integrations manifest")
    return data


def inspect_backend(device: AdbDevice, name: str, spec: dict[str, Any]) -> BackendState:
    module_id = spec.get("module_id")
    if not module_id:
        return BackendState(name, None, False, False, False, None)

    module_path = f"/data/adb/modules/{module_id}"
    installed = device.path_exists(f"{module_path}/module.prop")
    disabled = installed and device.path_exists(f"{module_path}/disable")
    remove_pending = installed and device.path_exists(f"{module_path}/remove")
    enabled = installed and not disabled and not remove_pending
    return BackendState(name, module_id, installed, enabled, remove_pending, module_path)


def inspect_all(device: AdbDevice, manifest: dict[str, Any]) -> list[BackendState]:
    return [inspect_backend(device, name, spec) for name, spec in manifest["backends"].items()]


def conflict_report(states: list[BackendState]) -> dict[str, Any]:
    runtime = [s for s in states if s.module_id and s.enabled]
    controllers = [s.name for s in runtime if s.name in {"op13perf", "fas-rs", "yumi", "thread-opt"}]
    return {
        "active_runtime_backends": controllers,
        "clean_single_backend": len(controllers) <= 1,
        "reason": None if len(controllers) <= 1 else "multiple performance backends enabled; A/B result would be contaminated",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("status", "preflight"))
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--adb", default="adb")
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    states = inspect_all(AdbDevice(args.adb), manifest)
    payload = {
        "backends": [s.__dict__ for s in states],
        "conflict": conflict_report(states),
    }
    print(json.dumps(payload, indent=2, sort_keys=True))

    if args.command == "preflight" and not payload["conflict"]["clean_single_backend"]:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
