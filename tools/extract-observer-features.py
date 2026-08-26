#!/usr/bin/env python3
"""Extract window-level features from dominant-thread-observer v2 text captures.

This is a feature layer only. It does not label a window as latency-critical and
it does not emit a production `burst_signal`. The purpose is to turn the already
measured S1 observer format into compact rows that can be compared across real
workloads without replaying shell parsing logic.
"""

import argparse
import csv
import json
from pathlib import Path


def parse_kv(parts):
    out = {}
    for item in parts:
        if "=" not in item:
            continue
        key, value = item.split("=", 1)
        out[key] = value
    return out


def parse_trace(path):
    meta = {}
    thread_fields = None
    windows = []
    current = None

    with Path(path).open(encoding="utf-8", errors="replace") as fh:
        for lineno, raw in enumerate(fh, start=1):
            line = raw.rstrip("\n")
            if not line:
                continue
            parts = line.split("|")
            kind = parts[0]
            if kind == "META":
                meta.update(parse_kv(parts[1:]))
            elif kind == "FIELDS" and len(parts) >= 3 and parts[1] == "THREAD":
                thread_fields = parts[2:]
            elif kind == "WINDOW":
                if current is not None:
                    windows.append(current)
                kv = parse_kv(parts[1:])
                try:
                    current = {
                        "seq": int(kv["seq"]),
                        "t_cs": int(kv["t_cs"]),
                        "wall_ms": float(kv["wall_ms"]),
                        "busy_threads": int(kv["busy_threads"]),
                        "total_runtime_ms": float(kv["total_runtime_ms"]),
                        "total_runq_wait_ms": float(kv["total_runq_wait_ms"]),
                        "threads": [],
                    }
                except (KeyError, ValueError) as exc:
                    raise ValueError(f"line {lineno}: malformed WINDOW") from exc
            elif kind == "THREAD":
                if current is None:
                    raise ValueError(f"line {lineno}: THREAD before WINDOW")
                if thread_fields is None:
                    raise ValueError(f"line {lineno}: THREAD fields not declared")
                values = parts[1:]
                if len(values) != len(thread_fields):
                    raise ValueError(
                        f"line {lineno}: THREAD has {len(values)} values; "
                        f"expected {len(thread_fields)}"
                    )
                row = dict(zip(thread_fields, values))
                try:
                    if int(row["seq"]) != current["seq"]:
                        raise ValueError(
                            f"line {lineno}: THREAD seq {row['seq']} "
                            f"does not match WINDOW {current['seq']}"
                        )
                    current["threads"].append({
                        "rank": int(row["rank"]),
                        "tgid": int(row["tgid"]),
                        "tid": int(row["tid"]),
                        "runtime_ms": float(row["runtime_ms"]),
                        "runtime_pct": float(row["runtime_pct"]),
                        "runq_wait_ms": float(row["runq_wait_ms"]),
                        "slices": int(row["slices"]),
                        "cpu_start": int(row["cpu_start"]),
                        "cpu_end": int(row["cpu_end"]),
                    })
                except (KeyError, ValueError) as exc:
                    if isinstance(exc, ValueError) and str(exc).startswith("line "):
                        raise
                    raise ValueError(f"line {lineno}: malformed THREAD") from exc

    if current is not None:
        windows.append(current)
    if not windows:
        raise ValueError("no WINDOW records")
    return meta, windows


def safe_ratio(num, den, scale=1.0):
    if den <= 0:
        return None
    return scale * num / den


def top_runtime_share(threads, total_runtime_ms, n):
    top = sorted(threads, key=lambda x: x["rank"])[:n]
    return safe_ratio(sum(t["runtime_ms"] for t in top), total_runtime_ms, 100.0)


def jaccard_churn(previous, current):
    a, b = set(previous), set(current)
    union = a | b
    if not union:
        return 0.0
    return 100.0 * (1.0 - len(a & b) / len(union))


def extract_features(windows):
    rows = []
    prev_leader = None
    prev_top4 = []
    for w in windows:
        threads = sorted(w["threads"], key=lambda x: x["rank"])
        leader = threads[0] if threads else None
        top4_tids = [t["tid"] for t in threads[:4] if t["runtime_ms"] > 0]
        captured_runtime = sum(t["runtime_ms"] for t in threads)
        shares = []
        if captured_runtime > 0:
            shares = [t["runtime_ms"] / captured_runtime for t in threads if t["runtime_ms"] > 0]
        hhi = sum(s * s for s in shares) if shares else None

        row = {
            "seq": w["seq"],
            "t_cs": w["t_cs"],
            "wall_ms": w["wall_ms"],
            "busy_threads": w["busy_threads"],
            "total_runtime_ms": w["total_runtime_ms"],
            "total_runq_wait_ms": w["total_runq_wait_ms"],
            "equiv_core_busy_pct": safe_ratio(w["total_runtime_ms"], w["wall_ms"], 100.0),
            "runq_wait_per_runtime": safe_ratio(
                w["total_runq_wait_ms"], w["total_runtime_ms"], 1.0
            ),
            "rank1_runtime_pct_wall": leader["runtime_pct"] if leader else None,
            "rank1_share_of_runtime_pct": (
                safe_ratio(leader["runtime_ms"], w["total_runtime_ms"], 100.0)
                if leader else None
            ),
            "top2_share_of_runtime_pct": top_runtime_share(
                threads, w["total_runtime_ms"], 2
            ),
            "top4_share_of_runtime_pct": top_runtime_share(
                threads, w["total_runtime_ms"], 4
            ),
            "captured_runtime_hhi": hhi,
            "leader_tid": leader["tid"] if leader else None,
            "leader_changed": (
                int(prev_leader is not None and leader is not None and leader["tid"] != prev_leader)
            ),
            "top4_tid_churn_pct": jaccard_churn(prev_top4, top4_tids) if rows else 0.0,
            "rank1_slices_per_ms": (
                safe_ratio(leader["slices"], leader["runtime_ms"], 1.0)
                if leader else None
            ),
            "rank1_runq_wait_per_runtime": (
                safe_ratio(leader["runq_wait_ms"], leader["runtime_ms"], 1.0)
                if leader else None
            ),
            "rank1_started_prime": (
                int(leader["cpu_start"] in (6, 7)) if leader else None
            ),
            "rank1_ended_prime": (
                int(leader["cpu_end"] in (6, 7)) if leader else None
            ),
        }
        rows.append(row)
        prev_leader = leader["tid"] if leader else prev_leader
        prev_top4 = top4_tids
    return rows


FIELDS = [
    "seq", "t_cs", "wall_ms", "busy_threads", "total_runtime_ms",
    "total_runq_wait_ms", "equiv_core_busy_pct", "runq_wait_per_runtime",
    "rank1_runtime_pct_wall", "rank1_share_of_runtime_pct",
    "top2_share_of_runtime_pct", "top4_share_of_runtime_pct",
    "captured_runtime_hhi", "leader_tid", "leader_changed",
    "top4_tid_churn_pct", "rank1_slices_per_ms",
    "rank1_runq_wait_per_runtime", "rank1_started_prime", "rank1_ended_prime",
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("-o", "--output")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    try:
        meta, windows = parse_trace(args.trace)
        rows = extract_features(windows)
    except ValueError as exc:
        ap.error(str(exc))
    if args.json:
        payload = {"meta": meta, "windows": rows}
        text = json.dumps(payload, indent=2, sort_keys=True)
        if args.output:
            Path(args.output).write_text(text + "\n", encoding="utf-8")
        else:
            print(text)
        return
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
