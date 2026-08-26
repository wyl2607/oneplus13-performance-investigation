#!/usr/bin/env python3
"""Analyse a two-arm Geekbench 7 reproducibility run.

Required CSV columns:
    run_id, block, order, arm, single_score, multi_score

Optional columns are preserved by the collector but only a few are interpreted
here: initial_junction_c, peak_junction_c, prime_residency_pct,
walt_demand_p50, wake_p50_us.  Missing optional values are fine.

Primary inference uses within-block A/B differences when at least two complete
balanced blocks are present.  A Welch comparison over all individual runs is
reported as a secondary view.  No SciPy dependency is required.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics as stats
import sys
from collections import Counter, defaultdict
from pathlib import Path

REQUIRED = {"run_id", "block", "order", "arm", "single_score", "multi_score"}
OPTIONAL_NUMERIC = (
    "initial_junction_c",
    "peak_junction_c",
    "prime_residency_pct",
    "walt_demand_p50",
    "wake_p50_us",
)
SCORE_METRICS = ("single_score", "multi_score")

T95 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
    7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179,
    13: 2.160, 14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101,
    19: 2.093, 20: 2.086, 21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064,
    25: 2.060, 26: 2.056, 27: 2.052, 28: 2.048, 29: 2.045, 30: 2.042,
    40: 2.021, 60: 2.000, 120: 1.980,
}


def tcrit95(df: float) -> float:
    if not math.isfinite(df) or df <= 1:
        return T95[1]
    if df >= 120:
        return 1.960
    keys = sorted(T95)
    lo = max(k for k in keys if k <= df)
    hi = min(k for k in keys if k >= df)
    if lo == hi:
        return T95[lo]
    frac = (df - lo) / (hi - lo)
    return T95[lo] + frac * (T95[hi] - T95[lo])


def fnum(value, field, rownum, required=False):
    if value is None or value == "":
        if required:
            raise ValueError(f"row {rownum}: missing {field}")
        return None
    try:
        return float(value)
    except ValueError as exc:
        raise ValueError(f"row {rownum}: {field} is not numeric: {value!r}") from exc


def load_rows(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        if reader.fieldnames is None:
            raise ValueError("CSV has no header")
        missing = REQUIRED - set(reader.fieldnames)
        if missing:
            raise ValueError("missing required columns: " + ", ".join(sorted(missing)))
        rows = []
        seen = set()
        for rownum, raw in enumerate(reader, start=2):
            rid = raw["run_id"].strip()
            if not rid:
                raise ValueError(f"row {rownum}: empty run_id")
            if rid in seen:
                raise ValueError(f"row {rownum}: duplicate run_id {rid!r}")
            seen.add(rid)
            arm = raw["arm"].strip().upper()
            if arm not in {"A", "B"}:
                raise ValueError(f"row {rownum}: arm must be A or B, got {arm!r}")
            try:
                block = int(raw["block"])
                order = int(raw["order"])
            except ValueError as exc:
                raise ValueError(f"row {rownum}: block/order must be integers") from exc
            row = {
                "run_id": rid,
                "block": block,
                "order": order,
                "arm": arm,
                "single_score": fnum(raw["single_score"], "single_score", rownum, True),
                "multi_score": fnum(raw["multi_score"], "multi_score", rownum, True),
            }
            for field in OPTIONAL_NUMERIC:
                row[field] = fnum(raw.get(field), field, rownum, False)
            rows.append(row)
    if not rows:
        raise ValueError("CSV contains no runs")
    orders = [r["order"] for r in rows]
    if len(orders) != len(set(orders)):
        raise ValueError("order values must be unique")
    return sorted(rows, key=lambda r: r["order"])


def mean(xs):
    return stats.fmean(xs) if xs else None


def summary(xs):
    if not xs:
        return {"n": 0, "mean": None, "median": None, "sd": None, "cv_pct": None}
    m = stats.fmean(xs)
    sd = stats.stdev(xs) if len(xs) > 1 else 0.0
    return {
        "n": len(xs),
        "mean": m,
        "median": stats.median(xs),
        "sd": sd,
        "cv_pct": (sd / m * 100.0) if m else None,
    }


def mean_ci(values):
    n = len(values)
    if n == 0:
        return None, None, None, None
    m = stats.fmean(values)
    if n == 1:
        return m, None, None, None
    sd = stats.stdev(values)
    se = sd / math.sqrt(n)
    df = n - 1
    tc = tcrit95(df)
    return m, m - tc * se, m + tc * se, df


def welch(a, b):
    if len(a) < 2 or len(b) < 2:
        return {"delta": None, "ci_low": None, "ci_high": None, "t": None, "df": None}
    ma, mb = stats.fmean(a), stats.fmean(b)
    va, vb = stats.variance(a), stats.variance(b)
    se2 = va / len(a) + vb / len(b)
    if se2 == 0:
        return {"delta": mb - ma, "ci_low": mb - ma, "ci_high": mb - ma,
                "t": math.inf if mb != ma else 0.0, "df": math.inf}
    se = math.sqrt(se2)
    num = se2 * se2
    den = ((va / len(a)) ** 2 / (len(a) - 1)) + ((vb / len(b)) ** 2 / (len(b) - 1))
    df = num / den if den else math.inf
    delta = mb - ma
    tc = tcrit95(df)
    return {"delta": delta, "ci_low": delta - tc * se, "ci_high": delta + tc * se,
            "t": delta / se, "df": df}


def block_deltas(rows, metric):
    groups = defaultdict(lambda: {"A": [], "B": []})
    for r in rows:
        groups[r["block"]][r["arm"]].append(r[metric])
    complete = []
    incomplete = []
    for block in sorted(groups):
        a = groups[block]["A"]
        b = groups[block]["B"]
        if len(a) == len(b) and len(a) > 0:
            complete.append({"block": block, "a_mean": mean(a), "b_mean": mean(b),
                             "delta": mean(b) - mean(a), "n_each": len(a)})
        else:
            incomplete.append({"block": block, "a_n": len(a), "b_n": len(b)})
    return complete, incomplete


def effect_pct(delta, baseline):
    return (delta / baseline * 100.0) if delta is not None and baseline else None


def classify(delta_pct, ci_low_pct, ci_high_pct, min_effect_pct):
    if delta_pct is None or ci_low_pct is None or ci_high_pct is None:
        return "INCONCLUSIVE"
    if delta_pct >= min_effect_pct and ci_low_pct > 0:
        return "PASS"
    if delta_pct <= -min_effect_pct and ci_high_pct < 0:
        return "REGRESSION"
    return "INCONCLUSIVE"


def sequence_checks(rows):
    warnings = []
    by_block = defaultdict(list)
    for r in rows:
        by_block[r["block"]].append(r)
    allowed = {"ABBA", "BAAB"}
    for block, br in sorted(by_block.items()):
        pat = "".join(r["arm"] for r in sorted(br, key=lambda x: x["order"]))
        if pat not in allowed:
            warnings.append(f"block {block}: sequence {pat or '-'} is not ABBA/BAAB")
    arms = Counter(r["arm"] for r in rows)
    if arms["A"] != arms["B"]:
        warnings.append(f"arm counts are unbalanced: A={arms['A']} B={arms['B']}")
    return warnings


def optional_arm_summary(rows, field):
    out = {}
    for arm in ("A", "B"):
        vals = [r[field] for r in rows if r["arm"] == arm and r[field] is not None]
        out[arm] = summary(vals)
    return out


def analyse(rows, min_effect_pct=3.0, temp_warn_c=2.0):
    report = {"runs": len(rows), "warnings": sequence_checks(rows), "metrics": {},
              "environment": {}}

    for metric in SCORE_METRICS:
        arms = {arm: [r[metric] for r in rows if r["arm"] == arm] for arm in ("A", "B")}
        a_sum = summary(arms["A"])
        b_sum = summary(arms["B"])
        blocks, incomplete = block_deltas(rows, metric)
        bd = [x["delta"] for x in blocks]
        paired_mean, paired_lo, paired_hi, paired_df = mean_ci(bd)
        base = a_sum["mean"]
        paired_pct = effect_pct(paired_mean, base)
        paired_lo_pct = effect_pct(paired_lo, base)
        paired_hi_pct = effect_pct(paired_hi, base)
        w = welch(arms["A"], arms["B"])
        w_pct = effect_pct(w["delta"], base)
        w_lo_pct = effect_pct(w["ci_low"], base)
        w_hi_pct = effect_pct(w["ci_high"], base)

        verdict = classify(paired_pct, paired_lo_pct, paired_hi_pct, min_effect_pct)
        if len(blocks) < 2:
            verdict = "INCONCLUSIVE"
            report["warnings"].append(
                f"{metric}: need at least 2 complete balanced blocks for a verdict"
            )
        report["metrics"][metric] = {
            "arm_a": a_sum,
            "arm_b": b_sum,
            "overall_delta_pct": effect_pct(b_sum["mean"] - a_sum["mean"], base),
            "paired_blocks": blocks,
            "incomplete_blocks": incomplete,
            "paired": {
                "n_blocks": len(blocks),
                "delta": paired_mean,
                "delta_pct": paired_pct,
                "ci95_low_pct": paired_lo_pct,
                "ci95_high_pct": paired_hi_pct,
                "df": paired_df,
            },
            "welch": {
                "delta": w["delta"],
                "delta_pct": w_pct,
                "ci95_low_pct": w_lo_pct,
                "ci95_high_pct": w_hi_pct,
                "t": w["t"],
                "df": w["df"],
            },
            "min_effect_pct": min_effect_pct,
            "verdict": verdict,
        }

    for field in OPTIONAL_NUMERIC:
        report["environment"][field] = optional_arm_summary(rows, field)

    temps = report["environment"]["initial_junction_c"]
    if temps["A"]["n"] and temps["B"]["n"]:
        diff = temps["B"]["mean"] - temps["A"]["mean"]
        report["environment"]["initial_temp_delta_c"] = diff
        if abs(diff) > temp_warn_c:
            report["warnings"].append(
                f"initial junction temperature differs by {diff:+.2f} C between arms "
                f"(warn threshold {temp_warn_c:.2f} C)"
            )
    return report


def fmt(v, digits=2):
    return "NA" if v is None else f"{v:.{digits}f}"


def print_text(report):
    print(f"runs: {report['runs']}")
    for metric, m in report["metrics"].items():
        print(f"\n{metric}")
        print(f"  A: n={m['arm_a']['n']} mean={fmt(m['arm_a']['mean'])} "
              f"sd={fmt(m['arm_a']['sd'])} cv={fmt(m['arm_a']['cv_pct'])}%")
        print(f"  B: n={m['arm_b']['n']} mean={fmt(m['arm_b']['mean'])} "
              f"sd={fmt(m['arm_b']['sd'])} cv={fmt(m['arm_b']['cv_pct'])}%")
        p = m["paired"]
        print(f"  paired blocks: n={p['n_blocks']} delta={fmt(p['delta_pct'])}% "
              f"95%CI=[{fmt(p['ci95_low_pct'])}, {fmt(p['ci95_high_pct'])}]%")
        w = m["welch"]
        print(f"  Welch: delta={fmt(w['delta_pct'])}% "
              f"95%CI=[{fmt(w['ci95_low_pct'])}, {fmt(w['ci95_high_pct'])}]% "
              f"t={fmt(w['t'])} df={fmt(w['df'], 1)}")
        print(f"  verdict: {m['verdict']} (minimum effect {m['min_effect_pct']:.2f}%)")
    if report["warnings"]:
        print("\nwarnings:")
        for warning in dict.fromkeys(report["warnings"]):
            print(f"  - {warning}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("csv", help="completed reproducibility CSV")
    p.add_argument("--min-effect-pct", type=float, default=3.0,
                   help="minimum practically meaningful score change (default: 3.0)")
    p.add_argument("--temp-warn-c", type=float, default=2.0,
                   help="warn when arm mean initial temperatures differ by more than this")
    p.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = p.parse_args(argv)
    if args.min_effect_pct < 0:
        p.error("--min-effect-pct must be >= 0")
    try:
        rows = load_rows(args.csv)
        report = analyse(rows, args.min_effect_pct, args.temp_warn_c)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print_text(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
