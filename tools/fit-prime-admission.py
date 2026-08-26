#!/usr/bin/env python3
"""Fit a monotone prime-admission curve from measured aggregate points.

The model is deliberately small: weighted isotonic regression (PAVA) followed by
piecewise-linear interpolation. It is descriptive, not a scheduler model, and it
does not infer that uclamp.min changes WALT demand. Predictions outside the
measured demand domain are refused rather than extrapolated.
"""

import argparse
import csv
import json
from pathlib import Path


REQUIRED = {"demand", "prime_share_pct", "weight"}


def load_points(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        missing = REQUIRED - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"missing required columns: {', '.join(sorted(missing))}")
        points = []
        for lineno, raw in enumerate(reader, start=2):
            try:
                demand = float(raw["demand"])
                share = float(raw["prime_share_pct"])
                weight = float(raw["weight"])
            except ValueError as exc:
                raise ValueError(f"line {lineno}: non-numeric model input") from exc
            if not 0 <= share <= 100:
                raise ValueError(f"line {lineno}: prime_share_pct outside 0..100")
            if weight <= 0:
                raise ValueError(f"line {lineno}: weight must be > 0")
            points.append({"demand": demand, "share": share, "weight": weight})
    if len(points) < 2:
        raise ValueError("need at least two model points")
    points.sort(key=lambda p: p["demand"])
    if len({p["demand"] for p in points}) != len(points):
        raise ValueError("duplicate demand values")
    return points


def pava(points):
    """Weighted non-decreasing isotonic regression over prime share."""
    blocks = []
    for p in points:
        blocks.append({
            "lo": p["demand"],
            "hi": p["demand"],
            "weight": p["weight"],
            "sum": p["share"] * p["weight"],
            "members": [p],
        })
        while len(blocks) >= 2:
            a, b = blocks[-2], blocks[-1]
            if a["sum"] / a["weight"] <= b["sum"] / b["weight"]:
                break
            merged = {
                "lo": a["lo"],
                "hi": b["hi"],
                "weight": a["weight"] + b["weight"],
                "sum": a["sum"] + b["sum"],
                "members": a["members"] + b["members"],
            }
            blocks[-2:] = [merged]

    fitted = []
    for block in blocks:
        value = block["sum"] / block["weight"]
        for member in block["members"]:
            fitted.append({
                "demand": member["demand"],
                "observed_prime_share_pct": member["share"],
                "fitted_prime_share_pct": value,
                "weight": member["weight"],
            })
    fitted.sort(key=lambda p: p["demand"])
    return fitted


def domain(points):
    return points[0]["demand"], points[-1]["demand"]


def interpolate(points, demand):
    lo, hi = domain(points)
    if not lo <= demand <= hi:
        raise ValueError(
            f"demand {demand:g} outside measured model domain {lo:g}..{hi:g}"
        )
    if demand == lo:
        return points[0]["fitted_prime_share_pct"]
    if demand == hi:
        return points[-1]["fitted_prime_share_pct"]
    for left, right in zip(points, points[1:]):
        if left["demand"] <= demand <= right["demand"]:
            span = right["demand"] - left["demand"]
            frac = (demand - left["demand"]) / span
            return (
                left["fitted_prime_share_pct"]
                + frac * (
                    right["fitted_prime_share_pct"]
                    - left["fitted_prime_share_pct"]
                )
            )
    raise AssertionError("unreachable")


def demand_at_share(points, target):
    if not 0 <= target <= 100:
        raise ValueError("target share must be in 0..100")
    first = points[0]
    if target <= first["fitted_prime_share_pct"]:
        return first["demand"]
    for left, right in zip(points, points[1:]):
        yl = left["fitted_prime_share_pct"]
        yr = right["fitted_prime_share_pct"]
        if yl <= target <= yr:
            if yr == yl:
                return right["demand"]
            frac = (target - yl) / (yr - yl)
            return left["demand"] + frac * (right["demand"] - left["demand"])
    return None


def fit(points):
    fitted = pava(points)
    lo, hi = domain(fitted)
    return {
        "model": "weighted-isotonic-piecewise-linear",
        "scope": "descriptive prime admission vs measured WALT demand",
        "counterfactual_uclamp_validated": False,
        "measured_domain": {"min_demand": lo, "max_demand": hi},
        "points": fitted,
        "thresholds": {
            "demand_at_10pct": demand_at_share(fitted, 10.0),
            "demand_at_50pct": demand_at_share(fitted, 50.0),
            "demand_at_80pct": demand_at_share(fitted, 80.0),
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--predict", type=float, action="append", default=[])
    args = ap.parse_args()
    model = fit(load_points(args.csv))
    predictions = {}
    for x in args.predict:
        try:
            predictions[str(x)] = {
                "status": "OK",
                "prime_share_pct": interpolate(model["points"], x),
            }
        except ValueError as exc:
            predictions[str(x)] = {
                "status": "OUT_OF_MODEL_DOMAIN",
                "prime_share_pct": None,
                "reason": str(exc),
            }
    if predictions:
        model["predictions"] = predictions
    if args.json:
        print(json.dumps(model, indent=2, sort_keys=True))
        return
    print("Prime-admission model")
    print("  counterfactual uclamp validated: NO")
    print(
        "  measured demand domain: "
        f"{model['measured_domain']['min_demand']:g}.."
        f"{model['measured_domain']['max_demand']:g}"
    )
    for key, value in model["thresholds"].items():
        text = "not reached" if value is None else f"{value:.1f}"
        print(f"  {key}: {text}")
    for x in args.predict:
        pred = predictions[str(x)]
        if pred["status"] == "OK":
            print(f"  demand {x:g}: {pred['prime_share_pct']:.1f}% prime")
        else:
            print(f"  demand {x:g}: OUT_OF_MODEL_DOMAIN")


if __name__ == "__main__":
    main()
