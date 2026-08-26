#!/usr/bin/env python3
"""R3 real-app uclamp pilot analysis (docs/R3_REAL_APP_PILOT.md).

Reads the run plan CSV (tools/make-r3-run-plan.py output) and, for each run,
its raw log (experiments/r3-real-app/run-schema.md) under --raw-dir named
`<run_id>.log`. Raw logs carry the real package name in `#META`/`#AM_START`
lines; this script never echoes those lines. Only structured, already
anonymous fields (run_id, workload, arm, mechanism, numeric measurements)
reach stdout, which is the only R3 analysis output meant to be committed.

Reuses tools/s2d-tis-delta.py's time_in_state reader unmodified rather than
re-parsing the format a third time.

Statistical unit is the RUN (same convention as analyze-s2d.py).
"""
import argparse
import csv
import importlib.util
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("s2d_tis_delta", ROOT / "s2d-tis-delta.py")
_s2d_tis = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_s2d_tis)
read_tis = _s2d_tis.read_tis

RESULT_RE = re.compile(
    r"^RESULT run_id=(?P<run_id>\S+) workload=(?P<workload>\S+) arm=(?P<arm>\S+) "
    r"mechanism=(?P<mechanism>\S+) wall_cs=(?P<wall_cs>\d+) event_ms=(?P<event_ms>\S+) "
    r"status=(?P<status>\S+) out=(?P<out>\S+) "
    r"tis0_before=(?P<tis0_before>\S+) tis0_after=(?P<tis0_after>\S+) "
    r"tis6_before=(?P<tis6_before>\S+) tis6_after=(?P<tis6_after>\S+)"
)
SAMPLE_RE = re.compile(
    r"^S\|(?P<t>[\d.]+)\|j=(?P<j>\S+)\|s=(?P<s>\S+)\|all_busy=(?P<all_busy>\d+)"
    r"\|prime_busy=(?P<prime_busy>\d+)\|fg_threads=(?P<fg>\d+)\|clamped_threads=(?P<cl>\d+)"
)


def fnum(v):
    if v in ("", None, "NA"):
        return None
    try:
        return float(v)
    except ValueError:
        return None


def percentile(vals, p):
    if not vals:
        return float("nan")
    s = sorted(vals)
    k = (len(s) - 1) * p
    f, c = int(k), min(int(k) + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def mean_sd(vals):
    vals = [v for v in vals if v is not None and v == v]
    if not vals:
        return float("nan"), float("nan"), float("nan"), 0
    m = statistics.mean(vals)
    md = statistics.median(vals)
    sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
    return m, md, sd, len(vals)


def tis_weighted_freq(before_path, after_path):
    before = read_tis(before_path)
    after = read_tis(after_path)
    if before is None or after is None:
        return None
    freqs = sorted(set(before) | set(after))
    total = 0
    weighted = 0
    for freq in freqs:
        b = before.get(freq, 0)
        a = after.get(freq, b)
        delta = max(0, a - b)
        total += delta
        weighted += freq * delta
    if total <= 0:
        return None
    return weighted / total


def parse_run_log(path):
    """Returns (result_fields, prime_residency_pct, j_peak, s_peak, fg_thread_peak,
    clamped_thread_peak, clamp_ticks, total_ticks) or None if unreadable."""
    result = None
    j_peak = None
    s_peak = None
    fg_peak = 0
    cl_peak = 0
    clamp_ticks = 0
    total_ticks = 0
    prime_busy_first = prime_busy_last = None
    all_busy_first = all_busy_last = None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line.startswith("RESULT "):
                    m = RESULT_RE.match(line)
                    if m:
                        result = m.groupdict()
                    continue
                m = SAMPLE_RE.match(line)
                if not m:
                    continue
                total_ticks += 1
                j = fnum(m.group("j"))
                s = fnum(m.group("s"))
                if j is not None:
                    j_peak = j if j_peak is None else max(j_peak, j)
                if s is not None:
                    s_peak = s if s_peak is None else max(s_peak, s)
                fg = int(m.group("fg"))
                cl = int(m.group("cl"))
                fg_peak = max(fg_peak, fg)
                cl_peak = max(cl_peak, cl)
                if cl > 0:
                    clamp_ticks += 1
                ab = int(m.group("all_busy"))
                pb = int(m.group("prime_busy"))
                if all_busy_first is None:
                    all_busy_first, prime_busy_first = ab, pb
                all_busy_last, prime_busy_last = ab, pb
    except FileNotFoundError:
        return None
    if result is None:
        return None
    prime_pct = None
    if all_busy_first is not None and all_busy_last is not None:
        d_all = all_busy_last - all_busy_first
        d_prime = prime_busy_last - prime_busy_first
        if d_all > 0:
            prime_pct = 100.0 * d_prime / d_all
    return {
        "result": result,
        "prime_residency_pct": prime_pct,
        "j_peak": j_peak,
        "s_peak": s_peak,
        "fg_thread_peak": fg_peak,
        "clamped_thread_peak": cl_peak,
        "clamp_ticks": clamp_ticks,
        "total_ticks": total_ticks,
    }


def load_plan(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def build_rows(plan, raw_dir):
    rows = []
    for entry in plan:
        run_id = entry["run_id"]
        log_path = Path(raw_dir) / f"{run_id}.log"
        parsed = parse_run_log(log_path)
        if parsed is None:
            print(f"WARN: no readable log for {run_id} ({log_path}), excluding", file=sys.stderr)
            continue
        r = parsed["result"]
        if r["status"] not in ("OK",):
            print(f"WARN: {run_id} status={r['status']}, excluding from summary "
                  f"(kept in --include-non-ok output only)", file=sys.stderr)
            if "--include-non-ok" not in sys.argv:
                continue
        mid_freq = tis_weighted_freq(r["tis0_before"], r["tis0_after"])
        prime_freq = tis_weighted_freq(r["tis6_before"], r["tis6_after"])
        clamp_frac = (parsed["clamp_ticks"] / parsed["total_ticks"]
                      if parsed["total_ticks"] else None)
        rows.append({
            "run_id": run_id,
            "workload_id": entry["workload_id"],
            "mechanism": entry.get("mechanism", r.get("mechanism", "none")),
            "arm": entry["arm"],
            "app_slot": entry.get("app_slot", "NA"),
            "status": r["status"],
            "event_ms": fnum(r["event_ms"]),
            "prime_residency_pct": parsed["prime_residency_pct"],
            "mid_weighted_freq": mid_freq,
            "prime_weighted_freq": prime_freq,
            "j_peak": parsed["j_peak"],
            "s_peak": parsed["s_peak"],
            "fg_thread_peak": parsed["fg_thread_peak"],
            "clamped_thread_peak": parsed["clamped_thread_peak"],
            "clamp_fraction": clamp_frac,
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan_csv")
    ap.add_argument("--raw-dir", default="experiments/r3-real-app/raw")
    ap.add_argument("--include-non-ok", action="store_true",
                     help="include non-OK-status runs in the summary tables")
    args = ap.parse_args()

    plan = load_plan(args.plan_csv)
    rows = build_rows(plan, args.raw_dir)
    print(f"# {len(rows)} runs loaded from {args.raw_dir}")

    by_workload_arm = defaultdict(list)
    for row in rows:
        by_workload_arm[(row["workload_id"], row["mechanism"], row["arm"])].append(row)

    workloads = sorted({(r["workload_id"], r["mechanism"]) for r in rows})
    metrics = ["event_ms", "prime_residency_pct", "mid_weighted_freq",
               "prime_weighted_freq", "j_peak", "clamp_fraction"]

    print("\n## Per-workload/mechanism control vs 512 (mean, run-level)")
    for workload_id, mechanism in workloads:
        control = by_workload_arm.get((workload_id, mechanism, "control"), [])
        arm512 = by_workload_arm.get((workload_id, mechanism, "512"), [])
        print(f"\n--- {workload_id} / {mechanism}  n_control={len(control)} n_512={len(arm512)} ---")
        for m in metrics:
            c_mean, c_med, c_sd, c_n = mean_sd([r[m] for r in control])
            a_mean, a_med, a_sd, a_n = mean_sd([r[m] for r in arm512])
            delta = (a_mean - c_mean) if (c_mean == c_mean and a_mean == a_mean) else float("nan")
            print(f"  {m:22s} control_mean={c_mean:10.2f} (n={c_n})  "
                  f"512_mean={a_mean:10.2f} (n={a_n})  delta={delta:+8.2f}")

    print("\n## Run-level table")
    hdr = ["run_id", "workload_id", "mechanism", "arm", "status", "event_ms",
           "prime_residency_pct", "mid_weighted_freq", "prime_weighted_freq",
           "j_peak", "clamp_fraction"]
    print(",".join(hdr))
    for row in sorted(rows, key=lambda r: r["run_id"]):
        print(",".join(
            f"{row[h]:.2f}" if isinstance(row[h], float) else ("NA" if row[h] is None else str(row[h]))
            for h in hdr
        ))


if __name__ == "__main__":
    main()
