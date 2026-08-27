#!/usr/bin/env python3
"""Generate a deterministic, balanced control/512 run plan for the R3 real-app
uclamp pilot (docs/R3_REAL_APP_PILOT.md).

Same alternating-state approach as make-burst-detector-holdout-plan.py: pair
order is shuffled within a repeat, and arm order (control-first vs
512-first) alternates by repeat so an ABBA/BAAB pattern balances any
order/warm-up effect once the repeat count is even.

Each workload in workloads.csv lists its mechanisms in priority order
(docs/R3_REAL_APP_PILOT.md prioritizes the active-set level). By default this
generates one unit per workload using only the first-listed (primary)
mechanism, matching the 32/40-run budget in the design doc. Pass
--all-mechanisms to also generate units for every other mechanism listed, for
a supplementary comparison run separately from the primary pilot.

One row per (workload, mechanism, repeat) pair-half. Statistical unit is the
RUN (docs/R3_REAL_APP_PILOT.md), so each row is one run.
"""

import argparse
import csv
import random
from pathlib import Path


REQUIRED = {"workload_id", "role", "event_markers_required", "mechanisms", "default_app_slot", "notes"}
FIELDS = [
    "run_id",
    "repeat",
    "pair_index",
    "workload_id",
    "mechanism",
    "role",
    "event_markers_required",
    "app_slot",
    "arm",
    "arm_order",
    "notes",
]


def read_workloads(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fields = set(reader.fieldnames or [])
        missing = REQUIRED - fields
        if missing:
            raise ValueError("workload file missing columns: " + ", ".join(sorted(missing)))
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
                raise ValueError(f"line {lineno}: event_markers_required must be yes/no")
            mechanisms = [m.strip() for m in row["mechanisms"].split(";") if m.strip()]
            if not mechanisms:
                raise ValueError(f"line {lineno}: no mechanisms listed")
            for m in mechanisms:
                if m not in {"process", "active-set"}:
                    raise ValueError(f"line {lineno}: unknown mechanism '{m}'")
            rows.append({
                "workload_id": workload_id,
                "role": row["role"].strip(),
                "event_markers_required": markers,
                "mechanisms": mechanisms,
                "app_slot": row["default_app_slot"].strip(),
                "notes": row["notes"].strip(),
            })
    if not rows:
        raise ValueError("workload file is empty")
    return rows


def generate(workloads, repeats, seed, all_mechanisms=False):
    if repeats < 2 or repeats % 2:
        raise ValueError("repeats must be an even integer >= 2")
    rng = random.Random(seed)
    out = []
    run_no = 1
    units = []
    for workload in workloads:
        mechanisms = workload["mechanisms"] if all_mechanisms else workload["mechanisms"][:1]
        for mechanism in mechanisms:
            units.append((workload, mechanism))

    for repeat in range(1, repeats + 1):
        order = list(units)
        rng.shuffle(order)
        arms = ["control", "512"] if repeat % 2 == 1 else ["512", "control"]
        arm_order = "CONTROL_512" if repeat % 2 == 1 else "512_CONTROL"
        for pair_index, (workload, mechanism) in enumerate(order, start=1):
            for arm in arms:
                out.append({
                    "run_id": f"R{run_no:03d}",
                    "repeat": repeat,
                    "pair_index": pair_index,
                    "workload_id": workload["workload_id"],
                    "mechanism": mechanism,
                    "role": workload["role"],
                    "event_markers_required": workload["event_markers_required"],
                    "app_slot": workload["app_slot"],
                    "arm": arm,
                    "arm_order": arm_order,
                    "notes": workload["notes"],
                })
                run_no += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workloads", default="experiments/r3-real-app/workloads.csv")
    ap.add_argument("--repeats", type=int, default=4)
    ap.add_argument("--seed", type=int, default=20260826)
    ap.add_argument("--all-mechanisms", action="store_true",
                     help="generate units for every mechanism listed per workload, "
                          "not just the primary one")
    ap.add_argument("-o", "--output")
    args = ap.parse_args()
    try:
        workloads = read_workloads(args.workloads)
        rows = generate(workloads, args.repeats, args.seed, args.all_mechanisms)
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
