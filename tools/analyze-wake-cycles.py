#!/usr/bin/env python3
"""Reconstruct wake cycles from a scheduler-event-tracer trace.

S1 could only see the result of a placement. This turns the raw ftrace lines
back into the thing that actually has a causal shape:

    WAKE -> runnable -> selected CPU -> switch-in -> execution -> sleep/block

and reports, per cycle, where the scheduler put the thread and when.

The tracer filters in the kernel, so every line here already belongs to the
target thread. Nothing is matched by name.

Traces may be plain or gzipped; the large sweep captures are committed as .gz
because an ftrace text dump of a ten-second run is over a megabyte and this
repository's whole history is smaller than that.

usage:
    analyze-wake-cycles.py TRACE[.gz] [TRACE ...] [--cycles] [--json]
"""

import argparse
import gzip
import json
import re
import sys
from collections import Counter

PRIME = {6, 7}

LINE = re.compile(
    r"^\s*(?P<curr>.+?)-(?P<currpid>\d+)\s+\[(?P<cpu>\d+)\]\s+(?P<flags>\S+)\s+"
    r"(?P<ts>\d+\.\d+):\s+(?P<ev>[\w]+):\s*(?P<rest>.*)$"
)
SWITCH = re.compile(
    r"prev_comm=(?P<prev_comm>.*?)\s+prev_pid=(?P<prev_pid>\d+)\s+prev_prio=\d+\s+"
    r"prev_state=(?P<prev_state>\S+)\s+==>\s+next_comm=(?P<next_comm>.*?)\s+"
    r"next_pid=(?P<next_pid>\d+)\s+next_prio=\d+"
)
KV = re.compile(r"(\w+)=(0x[0-9a-fA-F]+|-?\d+|\S+)")


def parse_header(lines):
    meta = {}
    for ln in lines:
        if not ln.startswith("#"):
            continue
        body = ln[1:].strip()
        for k, v in re.findall(r"(\w+)=([^\s]+)", body):
            meta.setdefault(k, v)
    return meta


def parse(path):
    events = []
    op = gzip.open if path.endswith(".gz") else open
    raw = op(path, "rt", encoding="utf-8", errors="replace").read().splitlines()
    meta = parse_header(raw)
    for ln in raw:
        if ln.startswith("#") or not ln.strip():
            continue
        m = LINE.match(ln)
        if not m:
            continue
        ev = {
            "ts": float(m.group("ts")),
            "cpu": int(m.group("cpu")),
            "ev": m.group("ev"),
            "curr_pid": int(m.group("currpid")),
            "curr": m.group("curr").strip(),
        }
        rest = m.group("rest")
        if ev["ev"] == "sched_switch":
            s = SWITCH.search(rest)
            if s:
                ev.update(
                    prev_pid=int(s.group("prev_pid")),
                    next_pid=int(s.group("next_pid")),
                    prev_state=s.group("prev_state"),
                )
        else:
            ev["f"] = dict(KV.findall(rest))
            if ev["ev"] == "sched_enq_deq_task":
                ev["op"] = "enqueue" if " enqueue " in f" {rest} " else "dequeue"
        events.append(ev)
    return meta, events


DEC = re.compile(r"-?\d+$")


def i(d, k, default=None):
    """int() of a trace field.

    ftrace prints target_cpu zero-padded ("target_cpu=002"), and int("002", 0)
    raises -- base 0 reads a leading zero as an octal prefix. Using base 0 here
    silently dropped every selected CPU except 000, which turned "the scheduler
    selects a spread of CPUs" into "the scheduler always selects CPU 0".
    Decimal is parsed as decimal; only an explicit 0x is hex.
    """
    v = d.get(k)
    if v is None:
        return default
    if DEC.match(v):
        return int(v, 10)
    try:
        return int(v, 16) if v.lower().startswith("0x") else default
    except ValueError:
        return default


def build_cycles(tid, events):
    """One cycle spans sched_waking -> the switch-out that puts the thread to sleep."""
    cycles = []
    cur = None
    inversions = 0
    last_ts = None

    def close(c, end_ts, reason):
        c["sleep_ts"] = end_ts
        c["end_reason"] = reason
        cycles.append(c)

    for e in events:
        if last_ts is not None and e["ts"] < last_ts:
            inversions += 1
        last_ts = e["ts"]
        ev = e["ev"]

        if ev == "sched_waking" and i(e.get("f", {}), "pid") == tid:
            if cur is not None:
                close(cur, e["ts"], "next_wake_without_sleep")
            cur = {
                "wake_ts": e["ts"],
                "waker": e["curr"],
                "waker_pid": e["curr_pid"],
                "waker_cpu": e["cpu"],
                "waking_target_cpu": i(e.get("f", {}), "target_cpu"),
                "migrations": [],
                "runs": [],
                "stat_wait_ns": [],
            }
            continue
        if cur is None:
            continue
        f = e.get("f", {})

        if ev == "sched_task_util":
            cur.setdefault("util", i(f, "util"))
            cur.setdefault("prev_cpu", i(f, "prev_cpu"))
            cur.setdefault("best_energy_cpu", i(f, "best_energy_cpu"))
            cur.setdefault("candidates", f.get("candidates"))
            cur.setdefault("fastpath", i(f, "fastpath"))
            cur.setdefault("start_cpu", i(f, "start_cpu"))
            cur.setdefault("need_idle", i(f, "need_idle"))
            cur.setdefault("placement_boost", i(f, "placement_boost"))
            cur.setdefault("task_boost", i(f, "task_boost"))
            cur.setdefault("low_latency", i(f, "low_latency"))
            cur.setdefault("stune_boosted", i(f, "stune_boosted"))
            cur.setdefault("affinity", f.get("affinity"))
            cur.setdefault("task_util_ts", e["ts"])
        elif ev == "sched_find_best_target":
            cur.setdefault("fbt_start_cpu", i(f, "start_cpu"))
            cur.setdefault("fbt_candidates", f.get("candidates"))
            cur.setdefault("fbt_order_index", i(f, "order_index"))
            cur.setdefault("fbt_min_util", i(f, "min_util"))
        elif ev == "sched_enq_deq_task" and e.get("op") == "enqueue":
            cur.setdefault("enqueue_cpu", i(f, "cpu"))
            cur.setdefault("enqueue_ts", e["ts"])
            cur.setdefault("demand", i(f, "demand"))
            cur.setdefault("nr_running_at_enqueue", i(f, "nr_running"))
        elif ev == "sched_wakeup":
            cur.setdefault("wakeup_ts", e["ts"])
            cur.setdefault("selected_cpu", i(f, "target_cpu"))
        elif ev == "sched_migrate_task":
            cur["migrations"].append(
                {"ts": e["ts"], "orig": i(f, "orig_cpu"), "dest": i(f, "dest_cpu")}
            )
        elif ev == "sched_stat_wait":
            cur["stat_wait_ns"].append(i(f, "delay"))
        elif ev == "sched_switch":
            if e.get("next_pid") == tid:
                cur["runs"].append({"in": e["ts"], "cpu": e["cpu"], "out": None})
                if "first_run_ts" not in cur:
                    cur["first_run_ts"] = e["ts"]
                    cur["first_run_cpu"] = e["cpu"]
            elif e.get("prev_pid") == tid:
                if cur["runs"] and cur["runs"][-1]["out"] is None:
                    cur["runs"][-1]["out"] = e["ts"]
                st = e.get("prev_state", "?")
                if st.startswith("S") or st.startswith("D") or st.startswith("I"):
                    close(cur, e["ts"], "sleep_" + st)
                    cur = None
        elif ev == "sched_process_exit":
            close(cur, e["ts"], "exit")
            cur = None

    if cur is not None:
        close(cur, cur.get("first_run_ts", cur["wake_ts"]), "truncated_at_end")
    return cycles, inversions


def infer_tid(events):
    """A --comm capture has no tid in the header. Take the busiest pid seen.

    Reported as tid_source=inferred, and tids_seen lists everything the glob
    matched, so a glob that caught more than the intended thread is visible
    rather than silently averaged in.
    """
    c = Counter()
    for e in events:
        v = i(e.get("f", {}), "pid")
        if v:
            c[v] += 1
        if e["ev"] == "sched_switch":
            for k in ("prev_pid", "next_pid"):
                if e.get(k):
                    c[e[k]] += 1
    return c.most_common(1)[0][0] if c else None


def tids_seen(events):
    c = Counter()
    for e in events:
        v = i(e.get("f", {}), "pid")
        if v:
            c[v] += 1
    return dict(c.most_common(8))


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def summarise(meta, cycles, inversions, span_s, events):
    complete = [c for c in cycles if "first_run_ts" in c]
    w2r = sorted((c["first_run_ts"] - c["wake_ts"]) * 1e6 for c in complete)
    runtime = []
    for c in complete:
        tot = sum((r["out"] - r["in"]) for r in c["runs"] if r["out"] is not None)
        c["run_duration_us"] = tot * 1e6
        runtime.append(tot)
    first_cpu = Counter(c["first_run_cpu"] for c in complete)
    sel_cpu = Counter(c.get("selected_cpu") for c in complete)
    prime_first = sum(n for cpu, n in first_cpu.items() if cpu in PRIME)
    prime_sel = sum(n for cpu, n in sel_cpu.items() if cpu in PRIME)
    mig_before = sum(
        1
        for c in complete
        if any(m["ts"] < c["first_run_ts"] for m in c["migrations"])
    )
    sel_eq_run = sum(
        1 for c in complete if c.get("selected_cpu") == c.get("first_run_cpu")
    )
    stat_waits = sorted(
        w / 1000.0 for c in cycles for w in c["stat_wait_ns"] if w is not None
    )
    enq_cpu = Counter(
        i(e.get("f", {}), "cpu")
        for e in events
        if e["ev"] == "sched_enq_deq_task" and e.get("op") == "enqueue"
    )
    demands = sorted(
        v for v in (i(e.get("f", {}), "demand") for e in events
                    if e["ev"] == "sched_enq_deq_task") if v is not None
    )
    preds = sorted(
        v for v in (i(e.get("f", {}), "pred_demand_scaled") for e in events
                    if e["ev"] == "sched_enq_deq_task") if v is not None
    )
    misfit = Counter(
        e.get("f", {}).get("misfit") for e in events if e["ev"] == "sched_enq_deq_task"
    )
    return {
        "label": meta.get("label", ""),
        "tid": i(meta, "tid"),
        "tid_source": meta.get("tid_source", "header"),
        "tids_seen": tids_seen(events),
        "events_by_type": dict(Counter(e["ev"] for e in events).most_common()),
        "enqueue_cpu_all": dict(sorted(k for k in enq_cpu.items())) if enq_cpu else {},
        "enqueue_prime_share_pct": round(
            100.0 * sum(n for c, n in enq_cpu.items() if c in PRIME) / sum(enq_cpu.values()), 2
        ) if enq_cpu else None,
        "walt_demand_ns": {"p50": pct(demands, 50), "p95": pct(demands, 95)},
        "pred_demand_scaled": {"p50": pct(preds, 50), "p95": pct(preds, 95)},
        "misfit": dict(misfit),
        "comm": meta.get("comm"),
        "loss": meta.get("loss"),
        "entries": i(meta, "entries"),
        "overrun": i(meta, "overrun"),
        "dropped": i(meta, "dropped"),
        "trace_clock": meta.get("trace_clock"),
        "span_s": round(span_s, 4),
        "ts_inversions": inversions,
        "cycles": len(cycles),
        "cycles_complete": len(complete),
        "wake_rate_hz": round(len(cycles) / span_s, 1) if span_s else None,
        "duty_pct": round(100.0 * sum(runtime) / span_s, 2) if span_s else None,
        "wake_to_run_us": {
            "p50": round(pct(w2r, 50), 1) if w2r else None,
            "p90": round(pct(w2r, 90), 1) if w2r else None,
            "p95": round(pct(w2r, 95), 1) if w2r else None,
            "p99": round(pct(w2r, 99), 1) if w2r else None,
            "max": round(w2r[-1], 1) if w2r else None,
        },
        "run_duration_us": {
            "p50": round(pct(sorted(x * 1e6 for x in runtime), 50), 1) if runtime else None,
            "p95": round(pct(sorted(x * 1e6 for x in runtime), 95), 1) if runtime else None,
        },
        "first_run_cpu": dict(sorted(first_cpu.items())),
        "selected_cpu": dict(sorted((k, v) for k, v in sel_cpu.items() if k is not None)),
        "prime_share_first_run_pct": round(100.0 * prime_first / len(complete), 2) if complete else None,
        "prime_share_selected_pct": round(100.0 * prime_sel / len(complete), 2) if complete else None,
        "selected_cpu_equals_first_run_pct": round(100.0 * sel_eq_run / len(complete), 2) if complete else None,
        "migration_before_first_run_pct": round(100.0 * mig_before / len(complete), 2) if complete else None,
        "migrations_per_cycle_mean": round(
            sum(len(c["migrations"]) for c in complete) / len(complete), 3
        ) if complete else None,
        "fastpath": dict(Counter(c.get("fastpath") for c in complete)),
        "start_cpu": dict(Counter(c.get("start_cpu") for c in complete)),
        "candidates": dict(Counter(c.get("candidates") for c in complete).most_common(6)),
        "util_p50": pct(sorted(c["util"] for c in complete if c.get("util") is not None), 50),
        "task_boost": dict(Counter(c.get("task_boost") for c in complete)),
        "low_latency": dict(Counter(c.get("low_latency") for c in complete)),
        "stune_boosted": dict(Counter(c.get("stune_boosted") for c in complete)),
        "end_reason": dict(Counter(c["end_reason"] for c in cycles)),
        "sched_stat_wait_us": {
            "n": len(stat_waits),
            "p50": round(pct(stat_waits, 50), 1) if stat_waits else None,
            "p95": round(pct(stat_waits, 95), 1) if stat_waits else None,
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("traces", nargs="+")
    ap.add_argument("--cycles", action="store_true", help="print every cycle")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--tid", type=int, help="override the header's tid")
    a = ap.parse_args()

    out = []
    for path in a.traces:
        meta, events = parse(path)
        tid = a.tid or i(meta, "tid")
        if tid is None:
            tid = infer_tid(events)
            if tid is None:
                print(f"{path}: no tid in header and none inferable", file=sys.stderr)
                continue
            meta["tid"] = str(tid)
            meta["tid_source"] = "inferred"
        cycles, inversions = build_cycles(tid, events)
        span = (events[-1]["ts"] - events[0]["ts"]) if len(events) > 1 else 0.0
        s = summarise(meta, cycles, inversions, span, events)
        s["file"] = path
        out.append(s)
        if a.cycles and not a.json:
            print(f"=== {path} cycles ===")
            hdr = ("wake_ts wake_to_run_us sel_cpu first_cpu prime mig_before "
                   "migs run_us fastpath util cands end")
            print(hdr)
            for c in cycles:
                w2r = ((c["first_run_ts"] - c["wake_ts"]) * 1e6) if "first_run_ts" in c else float("nan")
                mb = any(m["ts"] < c.get("first_run_ts", 0) for m in c["migrations"])
                print(f'{c["wake_ts"]:.6f} {w2r:9.1f} {c.get("selected_cpu")} '
                      f'{c.get("first_run_cpu")} {c.get("first_run_cpu") in PRIME} {mb} '
                      f'{len(c["migrations"])} {c.get("run_duration_us", 0):9.1f} '
                      f'{c.get("fastpath")} {c.get("util")} {c.get("candidates")} {c["end_reason"]}')
    if a.json:
        print(json.dumps(out, indent=2))
    else:
        for s in out:
            print(f"=== {s['file']}  [{s['label']}] ===")
            for k, v in s.items():
                if k in ("file", "label"):
                    continue
                print(f"  {k:38s} {v}")
            print()


if __name__ == "__main__":
    main()
