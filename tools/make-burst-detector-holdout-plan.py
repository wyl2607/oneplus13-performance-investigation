#!/usr/bin/env python3
"""Generate a deterministic paired collection plan for detector holdout traces.

Each workload appears once per repeat as a two-run module-state pair. Pair order
is shuffled within a repeat, while module-state order alternates by repeat so
OFF->ON and ON->OFF are balanced when the repeat count is even.
"""

import argparse
import csv
import random
from pathlib import Path


REQUIRED = {"workload_id", "role", "event_markers_required", "notes"}
FIELDS = [
    "run_id",
    "repeat",
    "pair_index",
    "workload_id",
    "role",
    "event_markers_required",
    "module_state",
    "state_order",
    "frozen_candidates",
    "notes",
]


def read_workloads(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fields = set(reader.fieldnames or [])
        missing = REQUIRED - fields
        if missing:
            raise ValueError(
                "workload file missing columns: " + ", ".join(sorted(missing))
            )
        rows = []
        seen = set()
        for lineno, row in enumerate(reader, start=2):
            workload_id = row["workload_id"].strip()
            if not workload_id:
                raise ValueError(f"line {lineno}: empty workload_id")
            if workload_id in seen:
                raise ValueError(f"line {lineno}: duplicate workload_id {workload_id}")
            seen.add(workload_id)
            markers = row["event_markers_required"].strip().lower()
            if markers not in {"yes", "no"}:
                raise ValueError(
                    f"line {lineno}: event_markers_required must be yes/no"
                )
            rows.append({
                "workload_id": workload_id,
                "role": row["role"].strip(),
                "event_markers_required": markers,
                "notes": row["notes"].strip(),
            })
    if not rows:
        raise ValueError("workload file is empty")
    return rows


def generate(workloads, repeats, seed):
    if repeats < 2 or repeats % 2:
        raise ValueError("repeats must be an even integer >= 2")
    rng = random.Random(seed)
    out = []
    run_no = 1
    for repeat in range(1, repeats + 1):
        order = list(workloads)
        rng.shuffle(order)
        states = (
            ["module_off", "module_on"]
            if repeat % 2 == 1
            else ["module_on", "module_off"]
        )
        state_order = "OFF_ON" if repeat % 2 == 1 else "ON_OFF"
        for pair_index, workload in enumerate(order, start=1):
            for module_state in states:
                out.append({
                    "run_id": f"H{run_no:03d}",
                    "repeat": repeat,
                    "pair_index": pair_index,
                    "workload_id": workload["workload_id"],
                    "role": workload["role"],
                    "event_markers_required": workload["event_markers_required"],
                    "module_state": module_state,
                    "state_order": state_order,
                    "frozen_candidates": "C2_ROTATION_OR_LEADER;C4_INTERACTION_SHAPE",
                    "notes": workload["notes"],
                })
                run_no += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--workloads",
        default="experiments/burst-detector-holdout/workloads.csv",
    )
    ap.add_argument("--repeats", type=int, default=4)
    ap.add_argument("--seed", type=int, default=20260826)
    ap.add_argument("-o", "--output")
    args = ap.parse_args()
    try:
        workloads = read_workloads(args.workloads)
        rows = generate(workloads, args.repeats, args.seed)
    except ValueError as exc:
        ap.error(str(exc))

    if args.output:
        fh = Path(args.output).open("w", newline="", encoding="utf-8")
        close = True
    else:
        import sys
        fh = sys.stdout
        close = False
    try:
        writer = csv.DictWriter(fh, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    finally:
        if close:
            fh.close()


if __name__ == "__main__":
    main()
