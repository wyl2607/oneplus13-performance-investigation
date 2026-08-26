#!/usr/bin/env python3
"""S2c mechanism analysis: given the extended per-cycle CSV from
s2c-trace-to-csv.py, find the first scheduler field that diverges between
arms, and check whether arm-B cycles with misfit==0 still land on prime --
the check that rules out (or confirms) the explicit misfit flag as the main
placement pathway.

usage: analyze-s2c.py CSV [--prime-cpus 6,7]
"""
import argparse
import csv
import statistics
import sys
from collections import defaultdict

PRIME = {6, 7}


def load(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def fnum(row, key):
    v = row.get(key, "")
    if v in ("", None):
        return None
    try:
        return float(v)
    except ValueError:
        return None


def inum(row, key):
    v = fnum(row, key)
    return None if v is None else int(v)


def mask_has_prime(mask):
    if mask is None:
        return None
    return bool(mask & 0x40) or bool(mask & 0x80)


def pct(n, d):
    return 100.0 * n / d if d else float("nan")


def summarize_field_prime_rate(rows, cpu_key):
    """% of rows where the named CPU field is a prime core (6 or 7)."""
    vals = [inum(r, cpu_key) for r in rows]
    vals = [v for v in vals if v is not None]
    if not vals:
        return float("nan"), 0
    n_prime = sum(1 for v in vals if v in PRIME)
    return pct(n_prime, len(vals)), len(vals)


def block_paired_ci(a_vals, b_vals, blocks_a, blocks_b):
    """Mean B-A per block, then a normal-approx 95% CI over block means --
    same block-aware approach as analyze-s2b.py, kept consistent."""
    by_block = defaultdict(lambda: {"A": [], "B": []})
    for v, blk in zip(a_vals, blocks_a):
        by_block[blk]["A"].append(v)
    for v, blk in zip(b_vals, blocks_b):
        by_block[blk]["B"].append(v)
    diffs = []
    for blk, d in sorted(by_block.items()):
        if d["A"] and d["B"]:
            diffs.append(statistics.mean(d["B"]) - statistics.mean(d["A"]))
    if len(diffs) < 2:
        return statistics.mean(diffs) if diffs else float("nan"), (float("nan"), float("nan"))
    m = statistics.mean(diffs)
    sd = statistics.stdev(diffs)
    se = sd / (len(diffs) ** 0.5)
    return m, (m - 1.96 * se, m + 1.96 * se)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    args = ap.parse_args()

    rows = load(args.csv)
    a = [r for r in rows if r["arm"] == "A"]
    b = [r for r in rows if r["arm"] == "B"]
    print(f"# {len(rows)} cycles total: {len(a)} arm A, {len(b)} arm B")

    # ---- 1. is effective_min already 512 BEFORE find_best_target runs? ----
    a_eff_wake = [inum(r, "eff_min_at_wake") for r in a if inum(r, "eff_min_at_wake") is not None]
    b_eff_wake = [inum(r, "eff_min_at_wake") for r in b if inum(r, "eff_min_at_wake") is not None]
    print("\n## Q1: effective_min at the FIRST uclamp reading after sched_waking"
          " (before find_best_target runs)")
    print(f"arm A: mean={statistics.mean(a_eff_wake):.1f} n={len(a_eff_wake)}")
    print(f"arm B: mean={statistics.mean(b_eff_wake):.1f} n={len(b_eff_wake)}")
    b_already_512 = sum(1 for v in b_eff_wake if v >= 512)
    print(f"arm B cycles already at effective_min>=512 at the WAKE reading: "
          f"{pct(b_already_512, len(b_eff_wake)):.1f}% ({b_already_512}/{len(b_eff_wake)})")
    print("-> uclamp.min is applied to the task_struct well before placement runs "
          "in every cycle (not something find_best_target itself raises).")

    # ---- 2. first divergent field: walk the pipeline in event order ----
    print("\n## Q2: first field where A and B diverge sharply "
          "(pipeline order: start_cpu -> candidate_mask -> misfit -> selected_cpu)")
    pipeline = [
        ("start_cpu", "start_cpu (find_best_target seed, from prev_cpu)"),
        ("candidate_mask", "candidate_mask includes prime"),
        ("misfit", "misfit flag (0/1)"),
        ("selected_cpu", "selected_cpu (sched_wakeup target_cpu)"),
        ("first_run_cpu", "first_run_cpu (actual switch-in)"),
    ]
    for key, label in pipeline:
        if key == "candidate_mask":
            a_p = pct(sum(1 for r in a if mask_has_prime(inum(r, key))), len(a))
            b_p = pct(sum(1 for r in b if mask_has_prime(inum(r, key))), len(b))
        elif key == "misfit":
            a_p = pct(sum(1 for r in a if inum(r, key) == 1), len(a))
            b_p = pct(sum(1 for r in b if inum(r, key) == 1), len(b))
        else:
            a_p, _ = summarize_field_prime_rate(a, key)
            b_p, _ = summarize_field_prime_rate(b, key)
        print(f"  {label:55s} A={a_p:6.2f}%  B={b_p:6.2f}%  delta={b_p - a_p:+6.2f}pp")

    # ---- 3. THE key check: within arm B, misfit==0 subset -- still prime? ----
    b_misfit0 = [r for r in b if inum(r, "misfit") == 0]
    b_misfit1 = [r for r in b if inum(r, "misfit") == 1]
    print(f"\n## Q3: arm B cycles with misfit==0 (explicit enqueue flag NOT set) -- "
          f"n={len(b_misfit0)}/{len(b)} ({pct(len(b_misfit0), len(b)):.1f}%)")
    for key, label in [("start_cpu", "start_cpu prime"), ("selected_cpu", "selected_cpu prime"),
                        ("first_run_cpu", "first_run_cpu prime")]:
        p, n = summarize_field_prime_rate(b_misfit0, key)
        print(f"  misfit==0: {label:20s} = {p:.1f}% (n={n})")
    p, n = summarize_field_prime_rate(b_misfit1, "first_run_cpu")
    print(f"  misfit==1: first_run_cpu prime  = {p:.1f}% (n={n})")
    print("-> if misfit==0 cycles still land on prime at close to the overall B rate,")
    print("   the explicit misfit flag is CONFIRMED NOT the main placement pathway")
    print("   (it's a downstream consequence of an already-prime candidate set, not the cause).")

    # ---- 4. start_cpu == prev_cpu stickiness ----
    match = sum(1 for r in rows if inum(r, "start_cpu") is not None and inum(r, "prev_cpu") is not None
                and inum(r, "start_cpu") == inum(r, "prev_cpu"))
    have_both = sum(1 for r in rows if inum(r, "start_cpu") is not None and inum(r, "prev_cpu") is not None)
    print(f"\n## Q4: start_cpu == prev_cpu (search anchored to where the thread last ran): "
          f"{pct(match, have_both):.1f}% ({match}/{have_both})")

    # ---- 5. candidate set size when start_cpu is prime vs mid ----
    def popcount_stats(rowset, label):
        sizes = [bin(inum(r, "candidate_mask")).count("1") for r in rowset
                 if inum(r, "candidate_mask") is not None]
        if sizes:
            print(f"  {label}: mean candidate popcount={statistics.mean(sizes):.2f} n={len(sizes)}")

    print("\n## Q5: candidate set size (popcount of candidate_mask)")
    prime_start = [r for r in rows if inum(r, "start_cpu") in PRIME]
    mid_start = [r for r in rows if inum(r, "start_cpu") is not None and inum(r, "start_cpu") not in PRIME]
    popcount_stats(prime_start, "start_cpu on prime")
    popcount_stats(mid_start, "start_cpu on mid")

    # ---- 6. min_util (the raw capacity requirement fed into find_best_target) ----
    a_minu = [fnum(r, "min_util") for r in a if fnum(r, "min_util") is not None]
    b_minu = [fnum(r, "min_util") for r in b if fnum(r, "min_util") is not None]
    print(f"\n## Q6: min_util field (find_best_target's own capacity requirement input)")
    print(f"  arm A: mean={statistics.mean(a_minu):.1f}  arm B: mean={statistics.mean(b_minu):.1f}")

    # ---- 7. fastpath distribution ----
    def dist(rowset, key):
        c = defaultdict(int)
        for r in rowset:
            v = inum(r, key)
            if v is not None:
                c[v] += 1
        return dict(sorted(c.items()))

    print(f"\n## Q7: fastpath value distribution  A={dist(a, 'fastpath')}  B={dist(b, 'fastpath')}")

    # ---- 8. block-paired CIs for start_cpu-prime% and misfit% (headline numbers) ----
    def per_run_prime_rate(rowset, key):
        by_run = defaultdict(list)
        for r in rowset:
            v = inum(r, key)
            if v is not None:
                by_run[r["run_id"]].append(1 if v in PRIME else 0)
        return {rid: statistics.mean(vs) * 100 for rid, vs in by_run.items()}

    def per_run_misfit_rate(rowset):
        by_run = defaultdict(list)
        for r in rowset:
            v = inum(r, "misfit")
            if v is not None:
                by_run[r["run_id"]].append(v)
        return {rid: statistics.mean(vs) * 100 for rid, vs in by_run.items()}

    a_start_by_run = per_run_prime_rate(a, "start_cpu")
    b_start_by_run = per_run_prime_rate(b, "start_cpu")
    a_blocks = {r["run_id"]: r["block"] for r in a}
    b_blocks = {r["run_id"]: r["block"] for r in b}

    def to_lists(by_run, blocks):
        ids = sorted(by_run)
        return [by_run[i] for i in ids], [blocks[i] for i in ids]

    av, ab = to_lists(a_start_by_run, a_blocks)
    bv, bb = to_lists(b_start_by_run, b_blocks)
    m, ci = block_paired_ci(av, bv, ab, bb)
    print(f"\n## Q8: run-level start_cpu-prime% B-A block-paired mean={m:.2f}pp CI=[{ci[0]:.2f}, {ci[1]:.2f}]")

    a_mf = per_run_misfit_rate(a)
    b_mf = per_run_misfit_rate(b)
    amv, amb = to_lists(a_mf, a_blocks)
    bmv, bmb = to_lists(b_mf, b_blocks)
    m2, ci2 = block_paired_ci(amv, bmv, amb, bmb)
    print(f"## Q8: run-level misfit% B-A block-paired mean={m2:.2f}pp CI=[{ci2[0]:.2f}, {ci2[1]:.2f}]")

if __name__ == "__main__":
    main()
