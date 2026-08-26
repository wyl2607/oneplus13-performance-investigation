#!/usr/bin/env python3
"""S2c Phase 2: minimum-effective-clamp ladder analysis.

Reads the run-level CSV (experiments/s2c/run-ladder.sh's *-ladder-runs.csv)
and the cycle-level CSV (tools/s2c-trace-to-csv.py output) for a randomized
complete block design over uclamp.min in {0, 256, 384, 448, 512}, 4 blocks.

Statistical unit is the RUN (per the task's explicit requirement), not the
wake cycle -- cycle-level data is only used to compute per-run summary
statistics (first-run prime%, wake latency percentiles, pred_demand), which
are then aggregated per arm across the 4 blocks (mean/median/SD, n=4).

usage: analyze-s2c-ladder.py RUNS_CSV CYCLES_CSV
"""
import argparse
import csv
import statistics
import sys
from collections import defaultdict

PRIME = {6, 7}
ARMS = [0, 256, 384, 448, 512]


def fnum(v):
    if v in ("", None):
        return None
    try:
        return float(v)
    except ValueError:
        return None


def load_csv(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def pct(n, d):
    return 100.0 * n / d if d else float("nan")


def percentile(vals, p):
    if not vals:
        return float("nan")
    s = sorted(vals)
    k = (len(s) - 1) * p
    f, c = int(k), min(int(k) + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def per_run_stats(cycles_for_run):
    n = len(cycles_for_run)
    if n == 0:
        return None
    start_prime = sum(1 for c in cycles_for_run
                       if fnum(c["start_cpu"]) is not None and int(fnum(c["start_cpu"])) in PRIME)
    cand_prime = sum(1 for c in cycles_for_run
                      if fnum(c["candidate_mask"]) is not None
                      and (int(fnum(c["candidate_mask"])) & 0x40 or int(fnum(c["candidate_mask"])) & 0x80))
    sel_prime = sum(1 for c in cycles_for_run
                     if fnum(c["selected_cpu"]) is not None and int(fnum(c["selected_cpu"])) in PRIME)
    first_prime = sum(1 for c in cycles_for_run
                       if fnum(c["first_run_cpu"]) is not None and int(fnum(c["first_run_cpu"])) in PRIME)
    lat = [fnum(c["wake_latency_us"]) for c in cycles_for_run if fnum(c["wake_latency_us"]) is not None]
    pd = [fnum(c["pred_demand"]) for c in cycles_for_run if fnum(c["pred_demand"]) is not None]
    eff = [fnum(c["eff_min_at_place"]) for c in cycles_for_run if fnum(c["eff_min_at_place"]) is not None]
    return {
        "n_cycles": n,
        "start_prime_pct": pct(start_prime, n),
        "candidate_prime_pct": pct(cand_prime, n),
        "selected_prime_pct": pct(sel_prime, n),
        "first_run_prime_pct": pct(first_prime, n),
        "wake_p50": percentile(lat, 0.50),
        "wake_p95": percentile(lat, 0.95),
        "pred_demand_p50": percentile(pd, 0.50),
        "effective_min_p50": percentile(eff, 0.50),
    }


def mean_sd(vals):
    vals = [v for v in vals if v is not None and v == v]  # drop None/NaN
    if not vals:
        return float("nan"), float("nan"), float("nan"), 0
    m = statistics.mean(vals)
    md = statistics.median(vals)
    sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
    return m, md, sd, len(vals)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs_csv")
    ap.add_argument("cycles_csv")
    args = ap.parse_args()

    runs = [r for r in load_csv(args.runs_csv) if r["status"] == "OK"]
    cycles = load_csv(args.cycles_csv)
    cycles_by_run = defaultdict(list)
    for c in cycles:
        cycles_by_run[c["run_id"]].append(c)

    print(f"# {len(runs)} OK runs loaded")

    per_run_rows = []
    for r in runs:
        stats = per_run_stats(cycles_by_run.get(r["run_id"], []))
        if stats is None:
            print(f"WARN: no cycles for {r['run_id']}, excluding", file=sys.stderr)
            continue
        stats.update(
            run_id=r["run_id"], block=r["block"], uclamp_min=int(r["uclamp_min"]),
            cycles_per_second=fnum(r["cycles_per_second"]),
            peak_temp=fnum(r["peak_temp"]), start_temp=fnum(r["start_temp"]),
        )
        per_run_rows.append(stats)

    print("\n## Run-level table")
    hdr = ["run_id", "block", "uclamp_min", "n_cycles", "start_prime_pct",
           "candidate_prime_pct", "selected_prime_pct", "first_run_prime_pct",
           "wake_p50", "wake_p95", "pred_demand_p50", "cycles_per_second", "peak_temp"]
    print(",".join(hdr))
    for row in sorted(per_run_rows, key=lambda r: (r["block"], r["uclamp_min"])):
        print(",".join(f"{row[h]:.2f}" if isinstance(row[h], float) else str(row[h]) for h in hdr))

    print("\n## Per-arm summary (n=4 blocks each)")
    by_arm = defaultdict(list)
    for row in per_run_rows:
        by_arm[row["uclamp_min"]].append(row)

    metrics = ["first_run_prime_pct", "candidate_prime_pct", "selected_prime_pct",
               "wake_p50", "wake_p95", "pred_demand_p50", "cycles_per_second", "peak_temp"]
    summary = {}
    for arm in ARMS:
        rows = by_arm.get(arm, [])
        summary[arm] = {}
        print(f"\n--- uclamp.min={arm}  n_runs={len(rows)} ---")
        for m in metrics:
            mean, med, sd, n = mean_sd([r[m] for r in rows])
            summary[arm][m] = mean
            print(f"  {m:22s} mean={mean:8.2f}  median={med:8.2f}  sd={sd:6.2f}  n={n}")

    print("\n## Retention vs 512 (first_run_prime_pct)")
    ref = summary[512]["first_run_prime_pct"]
    for arm in ARMS:
        v = summary[arm]["first_run_prime_pct"]
        retention = pct(v, ref) if ref else float("nan")
        print(f"  uclamp.min={arm:4d}: first_run_prime={v:6.2f}%  retention_vs_512={retention:6.1f}%")

    print("\n## Dose-response (mean across 4 blocks)")
    print("  uclamp.min | first_run_prime% | wake_p50(us) | wake_p95(us) | cycles/s")
    for arm in ARMS:
        s = summary[arm]
        print(f"  {arm:10d} | {s['first_run_prime_pct']:16.2f} | {s['wake_p50']:12.2f} | "
              f"{s['wake_p95']:12.2f} | {s['cycles_per_second']:8.2f}")

    print("\n## Monotonicity check (isotonic-ish: is first_run_prime% non-decreasing in uclamp.min?)")
    vals = [summary[a]["first_run_prime_pct"] for a in ARMS]
    monotone = all(vals[i] <= vals[i + 1] + 1e-9 for i in range(len(vals) - 1))
    print(f"  values={['%.1f' % v for v in vals]}  monotone_nondecreasing={monotone}")


if __name__ == "__main__":
    main()
