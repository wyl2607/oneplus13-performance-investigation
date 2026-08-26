#!/usr/bin/env python3
"""Offline counterfactual exploration for bounded burst uclamp.min policies.

This tool refuses to simulate the uclamp counterfactual unless the caller
explicitly acknowledges the unmeasured assumption that WALT placement sees
max(observed demand, requested uclamp.min). S2b exists to test exactly that.

No extrapolation is allowed beyond the measured prime-admission demand domain.
"""

import argparse
import csv
import importlib.util
import json
from pathlib import Path


def load_fit_tool():
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(
        "prime_fit", here / "fit-prime-admission.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FIT = load_fit_tool()


def load_workload(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fields = set(reader.fieldnames or [])
        if "demand" not in fields:
            raise ValueError("workload CSV needs demand")
        rows = []
        for lineno, raw in enumerate(reader, start=2):
            try:
                demand = float(raw["demand"])
                weight = float(raw.get("weight") or 1.0)
            except ValueError as exc:
                raise ValueError(f"line {lineno}: invalid workload value") from exc
            if weight <= 0:
                raise ValueError(f"line {lineno}: weight must be > 0")
            rows.append((demand, weight))
    if not rows:
        raise ValueError("empty workload")
    return rows


def weighted_mean(items):
    num = sum(value * weight for value, weight in items)
    den = sum(weight for _, weight in items)
    return num / den


def predict_distribution(points, workload, clamp=None):
    lo, hi = FIT.domain(points)
    effective = []
    outside = 0
    for demand, weight in workload:
        d = max(demand, clamp) if clamp is not None else demand
        if not lo <= d <= hi:
            outside += 1
            continue
        effective.append((FIT.interpolate(points, d), weight))
    if outside:
        return {
            "status": "OUT_OF_MODEL_DOMAIN",
            "prime_share_pct": None,
            "outside_rows": outside,
            "total_rows": len(workload),
            "measured_domain": [lo, hi],
        }
    return {
        "status": "OK",
        "prime_share_pct": weighted_mean(effective),
        "outside_rows": 0,
        "total_rows": len(workload),
        "measured_domain": [lo, hi],
    }


def simulate(model, workload, uclamp_values, assume=False, prime_wake_penalty_us=None):
    if not assume:
        raise ValueError(
            "counterfactual refused: pass --assume-clamp-visible-to-walt only for "
            "hypothesis exploration; S2b has not validated this mechanism"
        )
    points = model["points"]
    baseline = predict_distribution(points, workload)
    arms = []
    for clamp in uclamp_values:
        pred = predict_distribution(points, workload, clamp=clamp)
        row = {
            "uclamp_min": clamp,
            "status": pred["status"],
            "predicted_prime_share_pct": pred["prime_share_pct"],
            "outside_rows": pred["outside_rows"],
        }
        if pred["status"] == "OK" and baseline["status"] == "OK":
            delta = pred["prime_share_pct"] - baseline["prime_share_pct"]
            row["delta_prime_share_pp"] = delta
            if prime_wake_penalty_us is not None:
                row["estimated_extra_wake_us"] = (
                    delta / 100.0 * prime_wake_penalty_us
                )
        else:
            row["delta_prime_share_pp"] = None
        arms.append(row)
    return {
        "status": "HYPOTHESIS_ONLY",
        "assumption": "WALT placement uses max(observed_demand, requested_uclamp_min)",
        "s2b_validated": False,
        "baseline": baseline,
        "arms": arms,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_csv", help="measured demand/prime-share aggregate CSV")
    ap.add_argument("workload_csv", help="demand[,weight] samples to explore")
    ap.add_argument("--uclamp", type=float, action="append", required=True)
    ap.add_argument("--assume-clamp-visible-to-walt", action="store_true")
    ap.add_argument("--prime-wake-penalty-us", type=float)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    model = FIT.fit(FIT.load_points(args.model_csv))
    try:
        result = simulate(
            model,
            load_workload(args.workload_csv),
            args.uclamp,
            assume=args.assume_clamp_visible_to_walt,
            prime_wake_penalty_us=args.prime_wake_penalty_us,
        )
    except ValueError as exc:
        ap.error(str(exc))
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    print("Burst-policy exploration: HYPOTHESIS ONLY")
    base = result["baseline"]
    if base["status"] == "OK":
        print(f"baseline predicted prime share: {base['prime_share_pct']:.1f}%")
    else:
        print("baseline: OUT_OF_MODEL_DOMAIN")
    for arm in result["arms"]:
        if arm["status"] == "OK":
            print(
                f"uclamp.min={arm['uclamp_min']:g}: "
                f"{arm['predicted_prime_share_pct']:.1f}% "
                f"({arm['delta_prime_share_pp']:+.1f} pp)"
            )
        else:
            print(
                f"uclamp.min={arm['uclamp_min']:g}: OUT_OF_MODEL_DOMAIN "
                f"({arm['outside_rows']} workload rows)"
            )


if __name__ == "__main__":
    main()
