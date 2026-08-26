#!/usr/bin/env python3
"""S2d: threshold bisection + DVFS/placement separation analysis.

Reads the run-level CSV (experiments/s2d/run-threshold-ladder.sh's
*-threshold-runs.csv), the cycle-level CSV (tools/s2c-trace-to-csv.py
output, reused unmodified), and the time_in_state delta CSV
(tools/s2d-tis-delta.py output) for a randomized complete block design over
uclamp.min in {0, 448, 464, 480, 496, 504, 512}, 4 blocks.

Statistical unit is the RUN (same convention as analyze-s2c-ladder.py), not
the wake cycle or the time_in_state bucket.

usage: analyze-s2d.py RUNS_CSV CYCLES_CSV TIS_CSV
"""
import argparse
import csv
import statistics
import sys
from collections import defaultdict

PRIME = {6, 7}
ARMS = [0, 448, 464, 480, 496, 504, 512]


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
    first_prime = sum(1 for c in cycles_for_run
                       if fnum(c["first_run_cpu"]) is not None and int(fnum(c["first_run_cpu"])) in PRIME)
    cand_prime = sum(1 for c in cycles_for_run
                      if fnum(c["candidate_mask"]) is not None
                      and (int(fnum(c["candidate_mask"])) & 0x40 or int(fnum(c["candidate_mask"])) & 0x80))
    lat = [fnum(c["wake_latency_us"]) for c in cycles_for_run if fnum(c["wake_latency_us"]) is not None]
    pd = [fnum(c["pred_demand"]) for c in cycles_for_run if fnum(c["pred_demand"]) is not None]
    eff = [fnum(c["eff_min_at_place"]) for c in cycles_for_run if fnum(c["eff_min_at_place"]) is not None]
    return {
        "n_cycles": n,
        "first_run_prime_pct": pct(first_prime, n),
        "candidate_prime_pct": pct(cand_prime, n),
        "wake_p50": percentile(lat, 0.50),
        "wake_p95": percentile(lat, 0.95),
        "pred_demand_p50": percentile(pd, 0.50),
        "effective_min_p50": percentile(eff, 0.50),
    }


def mean_sd(vals):
    vals = [v for v in vals if v is not None and v == v]
    if not vals:
        return float("nan"), float("nan"), float("nan"), 0
    m = statistics.mean(vals)
    md = statistics.median(vals)
    sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
    return m, md, sd, len(vals)


def tis_weighted_freq(tis_rows_for_run, cluster):
    rows = [r for r in tis_rows_for_run if r["cluster"] == cluster]
    total_delta = sum(int(r["jiffies_delta"]) for r in rows if int(r["jiffies_delta"]) > 0)
    if total_delta <= 0:
        return None, None
    weighted = sum(int(r["freq_khz"]) * max(0, int(r["jiffies_delta"])) for r in rows) / total_delta
    dominant = max(rows, key=lambda r: int(r["jiffies_delta"]))
    return weighted, int(dominant["freq_khz"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs_csv")
    ap.add_argument("cycles_csv")
    ap.add_argument("tis_csv")
    args = ap.parse_args()

    runs = [r for r in load_csv(args.runs_csv) if r["status"] == "OK"]
    cycles = load_csv(args.cycles_csv)
    tis = load_csv(args.tis_csv)

    cycles_by_run = defaultdict(list)
    for c in cycles:
        cycles_by_run[c["run_id"]].append(c)
    tis_by_run = defaultdict(list)
    for t in tis:
        tis_by_run[t["run_id"]].append(t)

    print(f"# {len(runs)} OK runs loaded")

    per_run_rows = []
    for r in runs:
        stats = per_run_stats(cycles_by_run.get(r["run_id"], []))
        if stats is None:
            print(f"WARN: no cycles for {r['run_id']}, excluding", file=sys.stderr)
            continue
        mid_freq, mid_dom = tis_weighted_freq(tis_by_run.get(r["run_id"], []), "policy0_mid")
        prime_freq, prime_dom = tis_weighted_freq(tis_by_run.get(r["run_id"], []), "policy6_prime")
        stats.update(
            run_id=r["run_id"], block=r["block"], uclamp_min=int(r["uclamp_min"]),
            cycles_per_second=fnum(r["cycles_per_second"]),
            peak_temp=fnum(r["peak_temp"]), start_temp=fnum(r["start_temp"]),
            mid_weighted_freq=mid_freq, mid_dominant_freq=mid_dom,
            prime_weighted_freq=prime_freq, prime_dominant_freq=prime_dom,
        )
        per_run_rows.append(stats)

    print("\n## Run-level table")
    hdr = ["run_id", "block", "uclamp_min", "n_cycles", "first_run_prime_pct",
           "candidate_prime_pct", "wake_p50", "wake_p95", "pred_demand_p50",
           "cycles_per_second", "mid_weighted_freq", "prime_weighted_freq", "peak_temp"]
    print(",".join(hdr))
    for row in sorted(per_run_rows, key=lambda r: (r["block"], r["uclamp_min"])):
        print(",".join(f"{row[h]:.2f}" if isinstance(row[h], float) else str(row[h]) for h in hdr))

    print("\n## Per-arm summary (n=4 blocks each)")
    by_arm = defaultdict(list)
    for row in per_run_rows:
        by_arm[row["uclamp_min"]].append(row)

    metrics = ["first_run_prime_pct", "candidate_prime_pct", "wake_p50", "wake_p95",
               "pred_demand_p50", "cycles_per_second", "mid_weighted_freq",
               "prime_weighted_freq", "peak_temp"]
    summary = {}
    for arm in ARMS:
        rows = by_arm.get(arm, [])
        summary[arm] = {}
        print(f"\n--- uclamp.min={arm}  n_runs={len(rows)} ---")
        for m in metrics:
            mean, med, sd, n = mean_sd([r[m] for r in rows])
            summary[arm][m] = mean
            print(f"  {m:22s} mean={mean:10.2f}  median={med:10.2f}  sd={sd:8.2f}  n={n}")

    print("\n## Threshold bisection (mean across 4 blocks)")
    print("  uclamp.min | first_run_prime% | cycles/s | mid_freq(kHz) | prime_freq(kHz) | wake_p95")
    for arm in ARMS:
        s = summary[arm]
        print(f"  {arm:10d} | {s['first_run_prime_pct']:16.2f} | {s['cycles_per_second']:8.2f} | "
              f"{s['mid_weighted_freq']:13.0f} | {s['prime_weighted_freq']:15.0f} | {s['wake_p95']:8.2f}")

    print("\n## DVFS-vs-placement split")
    base = summary[0]["cycles_per_second"]
    top = summary[512]["cycles_per_second"]
    span = top - base if (top is not None and base is not None) else float("nan")
    for arm in ARMS:
        cps = summary[arm]["cycles_per_second"]
        frac_of_span = pct(cps - base, span) if span else float("nan")
        print(f"  uclamp.min={arm:4d}: cycles/s={cps:6.2f}  pct_of_0to512_span={frac_of_span:6.1f}%  "
              f"first_run_prime={summary[arm]['first_run_prime_pct']:6.2f}%")

    print("\n## Threshold interval search")
    below = [a for a in ARMS if summary[a]["first_run_prime_pct"] < 20]
    above = [a for a in ARMS if summary[a]["first_run_prime_pct"] >= 80]
    hi_inactive = max(below) if below else None
    lo_active = min(above) if above else None
    print(f"  highest reliably inactive (<20% first_run_prime): {hi_inactive}")
    print(f"  lowest reliably active (>=80% first_run_prime): {lo_active}")
    if hi_inactive is not None and lo_active is not None:
        print(f"  THRESHOLD INTERVAL: {hi_inactive} < T <= {lo_active}")
    else:
        print("  THRESHOLD INTERVAL: not resolvable from this ladder's arms")


if __name__ == "__main__":
    main()
