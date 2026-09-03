#!/usr/bin/env python3
"""Summarize paired OnePlus 13 device-health telemetry CSVs.

This tool intentionally does not declare a performance winner: the telemetry
captures thermal/energy/frequency context, while workload utility must come
from the workload-specific harness.
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path


def _num(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def load(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        raise ValueError(f"no telemetry rows: {path}")
    return rows


def values(rows: list[dict[str, str]], key: str) -> list[float]:
    out: list[float] = []
    for row in rows:
        value = _num(row.get(key))
        if value is not None:
            out.append(value)
    return out


def summarize(rows: list[dict[str, str]]) -> dict[str, object]:
    elapsed = values(rows, "elapsed_s")
    if not elapsed:
        raise ValueError("elapsed_s unavailable")
    duration = max(elapsed)
    landing_rows = [r for r in rows if (_num(r.get("elapsed_s")) or 0) >= max(0, duration - 300)]

    temps = values(rows, "battery_temp_tenths_c")
    levels = values(rows, "battery_pct")
    charge = values(rows, "charge_counter_uah")

    result: dict[str, object] = {
        "rows": len(rows),
        "duration_s": duration,
        "coverage_ok": duration >= 1740,
        "max_battery_temp_c": (max(temps) / 10) if temps else None,
        "battery_pct_drop": (levels[0] - levels[-1]) if len(levels) >= 2 else None,
        "charge_counter_drop_uah": (charge[0] - charge[-1]) if len(charge) >= 2 else None,
        "landing_window_s": min(300, duration),
    }

    for policy in (0, 6):
        cur = values(landing_rows, f"policy{policy}_cur_khz")
        maxf = values(landing_rows, f"policy{policy}_max_khz")
        result[f"policy{policy}_landing_cur_median_khz"] = statistics.median(cur) if cur else None
        result[f"policy{policy}_landing_max_median_khz"] = statistics.median(maxf) if maxf else None

    statuses = [r.get("thermal_status", "") for r in rows if r.get("thermal_status")]
    result["thermal_status_observations"] = sorted(set(statuses))[:20]
    return result


def delta(control: dict[str, object], tuned: dict[str, object], key: str) -> float | None:
    a = control.get(key)
    b = tuned.get(key)
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return float(b) - float(a)
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("control", type=Path, help="stock/control telemetry CSV")
    ap.add_argument("tuned", type=Path, help="tuned telemetry CSV")
    ap.add_argument("--output", type=Path)
    args = ap.parse_args()

    control = summarize(load(args.control))
    tuned = summarize(load(args.tuned))
    comparison = {
        "control": control,
        "tuned": tuned,
        "delta_tuned_minus_control": {
            key: delta(control, tuned, key)
            for key in (
                "max_battery_temp_c",
                "battery_pct_drop",
                "charge_counter_drop_uah",
                "policy0_landing_cur_median_khz",
                "policy6_landing_cur_median_khz",
            )
        },
        "verdict": "INCONCLUSIVE_WITHOUT_WORKLOAD_METRIC",
        "note": "Use workload-specific utility plus repeated paired runs before calling tuned better or worse.",
    }
    text = json.dumps(comparison, indent=2, sort_keys=True)
    if args.output:
        args.output.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
