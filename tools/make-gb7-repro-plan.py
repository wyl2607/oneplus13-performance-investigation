#!/usr/bin/env python3
"""Generate a drift-resistant two-arm benchmark run plan.

The default plan alternates ABBA and BAAB blocks.  Each block contains the
same number of A and B runs, so a slow thermal/battery/time drift is less able
to masquerade as an arm effect.

This tool is host-side only.  It writes a CSV plan and never touches a device.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


def build_plan(blocks: int, arm_a: str, arm_b: str):
    if blocks < 1:
        raise ValueError("blocks must be >= 1")
    patterns = (("A", "B", "B", "A"), ("B", "A", "A", "B"))
    labels = {"A": arm_a, "B": arm_b}
    rows = []
    order = 1
    for block in range(1, blocks + 1):
        pattern = patterns[(block - 1) % 2]
        for slot, arm in enumerate(pattern, start=1):
            rows.append(
                {
                    "run_id": f"b{block:02d}-r{slot}",
                    "block": block,
                    "order": order,
                    "arm": arm,
                    "label": labels[arm],
                }
            )
            order += 1
    return rows


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--blocks", type=int, default=4, help="number of 4-run blocks (default: 4)")
    p.add_argument("--arm-a", default="control", help="human-readable label for arm A")
    p.add_argument("--arm-b", default="candidate", help="human-readable label for arm B")
    p.add_argument("-o", "--output", default="-", help="CSV path, or - for stdout")
    args = p.parse_args(argv)

    try:
        rows = build_plan(args.blocks, args.arm_a, args.arm_b)
    except ValueError as exc:
        p.error(str(exc))

    fieldnames = ["run_id", "block", "order", "arm", "label"]
    if args.output == "-":
        fh = sys.stdout
        close = False
    else:
        path = Path(args.output)
        path.parent.mkdir(parents=True, exist_ok=True)
        fh = path.open("w", newline="", encoding="utf-8")
        close = True
    try:
        w = csv.DictWriter(fh, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)
    finally:
        if close:
            fh.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
