#!/usr/bin/env python3
"""Summarise S2b event-level runs without treating wake cycles as independent trials.

Input is one CSV row per wake/placement cycle. The experimental unit is a run:
cycle-level rows are reduced to run summaries first, then A/B effects are computed
within alternating blocks. This avoids pseudoreplication from hundreds of wakes
inside one thermal/scheduler state.

No device access. No scheduler writes.
"""

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

PRIME_CPUS = {6, 7}
REQUIRED = {"run_id", "block", "arm", "cycle_id"}
NUMERIC_OPTIONAL = {
    "requested_min", "effective_min", "pred_demand", "start_cpu", "candidate_mask",
    "misfit", "selected_cpu", "first_run_cpu", "wake_latency_us",
    "initial_junction_c", "peak_junction_c",
}

T95 = [
    None, 12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262,
    2.228, 2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093,
    2.086, 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045,
    2.042,
]


def parse_num(value):
    if value is None:
        return None
    value = str(value).strip()
    if value == "":
        return None
    if value.lower().startswith("0x"):
        return float(int(value, 16))
    return float(value)


def load_rows(path):
    path = Path(path)
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        missing = REQUIRED - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"missing required columns: {', '.join(sorted(missing))}")
        rows = []
        seen = set()
        for lineno, raw in enumerate(reader, start=2):
            key = (raw["run_id"].strip(), raw["cycle_id"].strip())
            if key in seen:
                raise ValueError(f"duplicate run_id/cycle_id at line {lineno}: {key}")
            seen.add(key)
            arm = raw["arm"].strip().upper()
            if arm not in {"A", "B"}:
                raise ValueError(f"line {lineno}: arm must be A or B")
            try:
                block = int(raw["block"])
            except ValueError as exc:
                raise ValueError(f"line {lineno}: invalid block") from exc
            row = {"run_id": key[0], "cycle_id": key[1], "block": block, "arm": arm}
            for name in NUMERIC_OPTIONAL:
                row[name] = parse_num(raw.get(name))
            rows.append(row)
    if not rows:
        raise ValueError("no data rows")
    return rows


def percentile(values, p):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    k = (len(vals) - 1) * p / 100.0
    lo = int(math.floor(k))
    hi = min(lo + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def mean(values):
    vals = [v for v in values if v is not None]
    return statistics.mean(vals) if vals else None


def pct_true(values, predicate):
    vals = [v for v in values if v is not None]
    if not vals:
        return None
    return 100.0 * sum(1 for v in vals if predicate(v)) / len(vals)


def candidate_has_prime(mask):
    if mask is None:
        return False
    return bool(int(mask) & ((1 << 6) | (1 << 7)))


def summarise_run(rows):
    first = rows[0]
    for r in rows[1:]:
        if r["block"] != first["block"] or r["arm"] != first["arm"]:
            raise ValueError(f"run {first['run_id']} spans multiple block/arm assignments")

    selected_pairs = [
        (r["selected_cpu"], r["first_run_cpu"])
        for r in rows
        if r["selected_cpu"] is not None and r["first_run_cpu"] is not None
    ]
    initial = [r["initial_junction_c"] for r in rows if r["initial_junction_c"] is not None]
    peak = [r["peak_junction_c"] for r in rows if r["peak_junction_c"] is not None]

    return {
        "run_id": first["run_id"],
        "block": first["block"],
        "arm": first["arm"],
        "cycles": len(rows),
        "requested_min_p50": percentile([r["requested_min"] for r in rows], 50),
        "effective_min_p50": percentile([r["effective_min"] for r in rows], 50),
        "pred_demand_p50": percentile([r["pred_demand"] for r in rows], 50),
        "start_prime_pct": pct_true([r["start_cpu"] for r in rows], lambda v: int(v) in PRIME_CPUS),
        "candidate_prime_pct": pct_true(
            [r["candidate_mask"] for r in rows], candidate_has_prime
        ),
        "misfit_pct": pct_true([r["misfit"] for r in rows], lambda v: int(v) != 0),
        "selected_prime_pct": pct_true(
            [r["selected_cpu"] for r in rows], lambda v: int(v) in PRIME_CPUS
        ),
        "first_run_prime_pct": pct_true(
            [r["first_run_cpu"] for r in rows], lambda v: int(v) in PRIME_CPUS
        ),
        "selected_eq_first_pct": (
            100.0 * sum(int(a) == int(b) for a, b in selected_pairs) / len(selected_pairs)
            if selected_pairs else None
        ),
        "wake_p50_us": percentile([r["wake_latency_us"] for r in rows], 50),
        "wake_p95_us": percentile([r["wake_latency_us"] for r in rows], 95),
        "initial_junction_c": mean(initial),
        "peak_junction_c": max(peak) if peak else None,
    }


def run_summaries(rows):
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["run_id"]].append(row)
    return [summarise_run(grouped[k]) for k in sorted(grouped)]


def ci95(values):
    vals = [float(v) for v in values if v is not None]
    n = len(vals)
    if n == 0:
        return {"n": 0, "mean": None, "low": None, "high": None}
    mu = statistics.mean(vals)
    if n == 1:
        return {"n": 1, "mean": mu, "low": None, "high": None}
    sd = statistics.stdev(vals)
    t = T95[n - 1] if n - 1 <= 30 else 1.96
    half = t * sd / math.sqrt(n)
    return {"n": n, "mean": mu, "low": mu - half, "high": mu + half}


def block_effects(runs, metric):
    by_block = defaultdict(lambda: {"A": [], "B": []})
    for r in runs:
        value = r.get(metric)
        if value is not None:
            by_block[r["block"]][r["arm"]].append(value)
    effects = []
    for block in sorted(by_block):
        arms = by_block[block]
        if arms["A"] and arms["B"]:
            effects.append({
                "block": block,
                "A": statistics.mean(arms["A"]),
                "B": statistics.mean(arms["B"]),
                "B_minus_A": statistics.mean(arms["B"]) - statistics.mean(arms["A"]),
            })
    return effects


def arm_summary(runs, metric):
    out = {}
    for arm in ("A", "B"):
        vals = [r[metric] for r in runs if r["arm"] == arm and r.get(metric) is not None]
        out[arm] = {
            "n_runs": len(vals),
            "mean": statistics.mean(vals) if vals else None,
            "median": statistics.median(vals) if vals else None,
            "sd": statistics.stdev(vals) if len(vals) >= 2 else None,
        }
    return out


def mechanism_gate(runs, min_prime_delta_pp=10.0, min_effective_delta=128.0):
    clamp = ci95([x["B_minus_A"] for x in block_effects(runs, "effective_min_p50")])
    prime = ci95([x["B_minus_A"] for x in block_effects(runs, "first_run_prime_pct")])
    start = ci95([x["B_minus_A"] for x in block_effects(runs, "start_prime_pct")])
    cand = ci95([x["B_minus_A"] for x in block_effects(runs, "candidate_prime_pct")])

    complete_blocks = min(clamp["n"], prime["n"])
    if complete_blocks < 2:
        verdict = "INCONCLUSIVE"
        reason = "fewer than two complete A/B blocks"
    elif clamp["mean"] is None or clamp["mean"] < min_effective_delta:
        verdict = "CLAMP_NOT_SEPARATED"
        reason = "effective uclamp.min did not separate enough between B and A"
    elif (
        prime["low"] is not None and prime["low"] > min_prime_delta_pp
        and (
            (start["low"] is not None and start["low"] > 0)
            or (cand["low"] is not None and cand["low"] > 0)
        )
    ):
        verdict = "PLACEMENT_EFFECT"
        reason = "prime first-run share and a causal placement field both moved"
    elif prime["high"] is not None and prime["high"] < min_prime_delta_pp:
        verdict = "NO_DETECTED_PLACEMENT_EFFECT"
        reason = "effective clamp separated, but prime effect stayed below the practical gate"
    else:
        verdict = "INCONCLUSIVE"
        reason = "confidence interval still overlaps the practical-effect boundary"

    return {
        "verdict": verdict,
        "reason": reason,
        "complete_blocks": complete_blocks,
        "min_prime_delta_pp": min_prime_delta_pp,
        "min_effective_delta": min_effective_delta,
        "effective_min_delta": clamp,
        "first_run_prime_delta_pp": prime,
        "start_prime_delta_pp": start,
        "candidate_prime_delta_pp": cand,
    }


METRICS = [
    "requested_min_p50", "effective_min_p50", "pred_demand_p50",
    "start_prime_pct", "candidate_prime_pct", "misfit_pct",
    "selected_prime_pct", "first_run_prime_pct", "selected_eq_first_pct",
    "wake_p50_us", "wake_p95_us", "initial_junction_c", "peak_junction_c",
]


def analyse(rows, min_prime_delta_pp=10.0, min_effective_delta=128.0):
    runs = run_summaries(rows)
    metrics = {}
    for metric in METRICS:
        effects = block_effects(runs, metric)
        metrics[metric] = {
            "arms": arm_summary(runs, metric),
            "block_effects": effects,
            "B_minus_A_ci95": ci95([e["B_minus_A"] for e in effects]),
        }

    warnings = []
    temp = metrics["initial_junction_c"]["B_minus_A_ci95"]
    if temp["mean"] is not None and abs(temp["mean"]) > 2.0:
        warnings.append(
            f"initial junction temperature imbalance: B-A={temp['mean']:.2f} C"
        )
    low_cycle = [r["run_id"] for r in runs if r["cycles"] < 20]
    if low_cycle:
        warnings.append("runs with fewer than 20 wake cycles: " + ", ".join(low_cycle))

    return {
        "runs": runs,
        "metrics": metrics,
        "mechanism_gate": mechanism_gate(
            runs,
            min_prime_delta_pp=min_prime_delta_pp,
            min_effective_delta=min_effective_delta,
        ),
        "warnings": warnings,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--min-prime-delta-pp", type=float, default=10.0)
    ap.add_argument("--min-effective-delta", type=float, default=128.0)
    args = ap.parse_args()
    report = analyse(
        load_rows(args.csv),
        min_prime_delta_pp=args.min_prime_delta_pp,
        min_effective_delta=args.min_effective_delta,
    )
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return
    gate = report["mechanism_gate"]
    print(f"S2b mechanism gate: {gate['verdict']}")
    print(f"  {gate['reason']}")
    for key in (
        "effective_min_delta", "first_run_prime_delta_pp",
        "start_prime_delta_pp", "candidate_prime_delta_pp",
    ):
        ci = gate[key]
        if ci["mean"] is None:
            print(f"  {key}: n=0")
        elif ci["low"] is None:
            print(f"  {key}: {ci['mean']:.2f} (n=1; no CI)")
        else:
            print(
                f"  {key}: {ci['mean']:.2f} "
                f"[95% CI {ci['low']:.2f}, {ci['high']:.2f}] n={ci['n']}"
            )
    for warning in report["warnings"]:
        print(f"WARNING: {warning}")


if __name__ == "__main__":
    main()
