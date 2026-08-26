#!/usr/bin/env python3
"""Summarise observer feature CSVs across named workloads.

This tool is descriptive only. It reports distributions and overlap-friendly
quantiles; it does not choose a burst detector threshold or label a workload as
latency-critical.
"""

import argparse
import csv
import json
import math
import statistics
from pathlib import Path


METRICS = [
    "busy_threads",
    "equiv_core_busy_pct",
    "runq_wait_per_runtime",
    "rank1_runtime_pct_wall",
    "rank1_share_of_runtime_pct",
    "top2_share_of_runtime_pct",
    "top4_share_of_runtime_pct",
    "captured_runtime_hhi",
    "top4_tid_churn_pct",
    "rank1_slices_per_ms",
    "rank1_runq_wait_per_runtime",
]


def percentile(values, p):
    vals = sorted(values)
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    k = (len(vals) - 1) * p / 100.0
    lo = int(math.floor(k))
    hi = min(lo + 1, len(vals) - 1)
    frac = k - lo
    return vals[lo] + (vals[hi] - vals[lo]) * frac


def parse_float(raw):
    if raw is None or str(raw).strip() == "":
        return None
    return float(raw)


def load_feature_csv(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fields = set(reader.fieldnames or [])
        required = {"total_runtime_ms", "leader_changed"} | set(METRICS)
        missing = required - fields
        if missing:
            raise ValueError(
                f"{path}: missing columns: {', '.join(sorted(missing))}"
            )
        rows = []
        for lineno, raw in enumerate(reader, start=2):
            try:
                row = {name: parse_float(raw.get(name)) for name in METRICS}
                row["total_runtime_ms"] = float(raw["total_runtime_ms"])
                row["leader_changed"] = int(raw["leader_changed"])
            except ValueError as exc:
                raise ValueError(f"{path}: line {lineno}: invalid numeric value") from exc
            if row["leader_changed"] not in (0, 1):
                raise ValueError(f"{path}: line {lineno}: leader_changed must be 0/1")
            rows.append(row)
    if not rows:
        raise ValueError(f"{path}: no feature rows")
    return rows


def metric_summary(rows, metric):
    vals = [r[metric] for r in rows if r[metric] is not None]
    if not vals:
        return {"n": 0, "p10": None, "p50": None, "p90": None, "mean": None}
    return {
        "n": len(vals),
        "p10": percentile(vals, 10),
        "p50": percentile(vals, 50),
        "p90": percentile(vals, 90),
        "mean": statistics.mean(vals),
    }


def summarise(label, rows):
    active = [r for r in rows if r["total_runtime_ms"] > 0]
    active_leader = [r["leader_changed"] for r in active]
    return {
        "label": label,
        "windows": len(rows),
        "active_windows": len(active),
        "active_window_pct": 100.0 * len(active) / len(rows),
        "leader_change_pct_active": (
            100.0 * sum(active_leader) / len(active_leader)
            if active_leader else None
        ),
        "all_windows": {m: metric_summary(rows, m) for m in METRICS},
        "active_windows_only": {m: metric_summary(active, m) for m in METRICS},
    }


def parse_input(value):
    if "=" not in value:
        raise ValueError("input must be LABEL=PATH")
    label, path = value.split("=", 1)
    label = label.strip()
    path = path.strip()
    if not label or not path:
        raise ValueError("input must be LABEL=PATH")
    return label, path


def analyse(inputs):
    seen = set()
    workloads = []
    for value in inputs:
        label, path = parse_input(value)
        if label in seen:
            raise ValueError(f"duplicate workload label: {label}")
        seen.add(label)
        workloads.append(summarise(label, load_feature_csv(path)))
    if not workloads:
        raise ValueError("at least one --input is required")
    return {
        "status": "DESCRIPTIVE_ONLY",
        "detector_threshold_selected": False,
        "metrics": METRICS,
        "workloads": workloads,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--input",
        action="append",
        required=True,
        metavar="LABEL=PATH",
        help="named feature CSV; repeat for multiple workloads",
    )
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    try:
        report = analyse(args.input)
    except ValueError as exc:
        ap.error(str(exc))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return

    print("Observer workload distributions: DESCRIPTIVE ONLY")
    print("detector threshold selected: NO")
    for workload in report["workloads"]:
        print(
            f"{workload['label']}: {workload['active_windows']}/"
            f"{workload['windows']} active windows "
            f"({workload['active_window_pct']:.1f}%)"
        )
        for metric in (
            "busy_threads",
            "equiv_core_busy_pct",
            "rank1_share_of_runtime_pct",
            "top4_tid_churn_pct",
        ):
            s = workload["active_windows_only"][metric]
            if s["p50"] is not None:
                print(
                    f"  {metric}: p10={s['p10']:.2f} "
                    f"p50={s['p50']:.2f} p90={s['p90']:.2f}"
                )


if __name__ == "__main__":
    main()
