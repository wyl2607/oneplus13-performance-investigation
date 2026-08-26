#!/usr/bin/env python3
"""Turn one S2c run's raw scheduler-event-tracer trace into an extended
per-cycle CSV, for mechanism refinement (which field first diverges between
uclamp.min arms, ahead of the explicit `misfit` flag).

Reuses tools/s2b-trace-to-csv.py's line/cycle-boundary parsing (same tracer,
same event set -- schedwalt/sched_task_util and schedwalt/sched_find_best_target
already carry every field this needs; no new kprobe or tracepoint was added).
Extends the per-cycle dict with:

  - prev_cpu, best_energy_cpu, fastpath, util (raw)      [sched_task_util]
  - order_index, end_index, skip, most_spare_cap, min_util [sched_find_best_target]
  - demand (raw, alongside pred_demand_scaled)            [sched_enq_deq_task]
  - effective/requested min+max, decoded INCLUDING the active bit, taken at
    TWO points: the first uclamp reading after sched_waking (before
    find_best_target runs -- "was it already 512 before placement?") and the
    last one before the thread is switched in (matches S2b's effective_min).

Event-order discipline: every field is taken with setdefault() at FIRST
occurrence within the cycle's own [wake_ts, close) window. A field with no
occurrence in that window is left as None/"" in the CSV -- never forward-filled
from a neighboring cycle. This matches analyze-s2b.py's existing contract and
the task's explicit "null not forward-fill" requirement.

usage:
  s2c-trace-to-csv.py TRACE --run-id ID --block N --arm A|B --uclamp-min N
      --initial-junction-c C --peak-junction-c C [--header]
"""

import argparse
import csv
import gzip
import re
import sys

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
DEC = re.compile(r"-?\d+$")

FIELDS = [
    "run_id", "block", "arm", "uclamp_min_arm", "cycle_id",
    # uclamp, at wake (before find_best_target) and at placement (last before switch)
    "req_min_at_wake", "eff_min_at_wake", "eff_active_at_wake", "eff_bucket_at_wake",
    "req_min_at_place", "eff_min_at_place", "eff_active_at_place", "eff_bucket_at_place",
    "eff_max_at_place",
    # sched_find_best_target (first occurrence in cycle)
    "start_cpu", "candidate_mask", "min_util", "most_spare_cap",
    "order_index", "end_index", "skip",
    # sched_task_util (first occurrence in cycle)
    "prev_cpu", "util_raw", "best_energy_cpu", "fastpath",
    # sched_enq_deq_task (first occurrence in cycle)
    "demand_raw", "pred_demand", "misfit",
    # outcome
    "selected_cpu", "first_run_cpu", "wake_latency_us",
    "initial_junction_c", "peak_junction_c",
]

PRIME_CPUS = {6, 7}


def i(d, k, default=None):
    """int() of a trace field; ftrace zero-pads (target_cpu=002) so base-0
    parsing misreads it as octal."""
    v = d.get(k)
    if v is None:
        return default
    if DEC.match(v):
        return int(v, 10)
    try:
        return int(v, 16) if v.lower().startswith("0x") else default
    except ValueError:
        return default


def decode_uclamp_se(raw):
    """value:11 bucket_id:5 active:1 user_defined:1 (kernel/sched/core.c
    uclamp_se). Returns (value, bucket_id, active) or (None, None, None)."""
    if raw is None:
        return None, None, None
    value = raw & 0x7FF
    bucket = (raw >> 11) & 0x1F
    active = (raw >> 16) & 0x1
    return value, bucket, active


def parse(path):
    op = gzip.open if path.endswith(".gz") else open
    raw = op(path, "rt", encoding="utf-8", errors="replace").read().splitlines()
    events = []
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
        events.append(ev)
    return events


def tid_from_header(path):
    op = gzip.open if path.endswith(".gz") else open
    for ln in op(path, "rt", encoding="utf-8", errors="replace"):
        if ln.startswith("# tid="):
            m = re.search(r"tid=(\d+)", ln)
            if m:
                return int(m.group(1))
        if not ln.startswith("#"):
            break
    return None


def build_cycles(tid, events):
    """One cycle: sched_waking -> the switch-out that puts the thread back to
    sleep. Every extra field is captured with setdefault() at first occurrence
    -- i.e. the value nearest sched_waking, upstream of any later re-check
    within the same cycle -- and never carried over from a previous cycle."""
    cycles = []
    cur = None

    def close(c):
        cycles.append(c)

    for e in events:
        ev = e["ev"]
        f = e.get("f", {})

        if ev == "sched_waking" and i(f, "pid") == tid:
            if cur is not None:
                close(cur)
            cur = {"wake_ts": e["ts"], "runs": []}
            continue
        if cur is None:
            continue

        if ev == "s2a_uclamp" and i(f, "tpid") == tid:
            if "req_min_at_wake_raw" not in cur:
                cur["req_min_at_wake_raw"] = i(f, "req_min")
                cur["eff_min_at_wake_raw"] = i(f, "eff_min")
            if "first_run_ts" not in cur:
                cur["req_min_at_place_raw"] = i(f, "req_min")
                cur["eff_min_at_place_raw"] = i(f, "eff_min")
                cur["eff_max_at_place_raw"] = i(f, "eff_max")
        elif ev == "sched_find_best_target":
            cur.setdefault("start_cpu", i(f, "start_cpu"))
            cur.setdefault("candidate_mask", i(f, "candidates"))
            cur.setdefault("min_util", i(f, "min_util"))
            cur.setdefault("most_spare_cap", i(f, "most_spare_cap"))
            cur.setdefault("order_index", i(f, "order_index"))
            cur.setdefault("end_index", i(f, "end_index"))
            cur.setdefault("skip", i(f, "skip"))
        elif ev == "sched_task_util":
            cur.setdefault("prev_cpu", i(f, "prev_cpu"))
            cur.setdefault("util_raw", i(f, "util"))
            cur.setdefault("best_energy_cpu", i(f, "best_energy_cpu"))
            cur.setdefault("fastpath", i(f, "fastpath"))
            # keep start_cpu/candidate_mask fallback in case find_best_target
            # itself didn't fire this cycle (fastpath may skip it)
            cur.setdefault("start_cpu", i(f, "start_cpu"))
            cur.setdefault("candidate_mask", i(f, "candidates"))
        elif ev == "sched_enq_deq_task" and f.get("cpu") is not None:
            if "demand_raw" not in cur:
                cur["demand_raw"] = i(f, "demand")
                cur["pred_demand"] = i(f, "pred_demand_scaled")
                cur["misfit"] = i(f, "misfit")
        elif ev == "sched_wakeup":
            cur.setdefault("selected_cpu", i(f, "target_cpu"))
        elif ev == "sched_switch":
            if e.get("next_pid") == tid and "first_run_ts" not in cur:
                cur["first_run_ts"] = e["ts"]
                cur["first_run_cpu"] = e["cpu"]
            elif e.get("prev_pid") == tid:
                st = e.get("prev_state", "?")
                if st.startswith("S") or st.startswith("D") or st.startswith("I"):
                    close(cur)
                    cur = None

    if cur is not None and "first_run_ts" in cur:
        close(cur)
    return cycles


def row_for(run_id, block, arm, uclamp_min_arm, idx, c, initial_j, peak_j):
    req_w, _, _ = decode_uclamp_se(c.get("req_min_at_wake_raw"))
    eff_w, buck_w, act_w = decode_uclamp_se(c.get("eff_min_at_wake_raw"))
    req_p, _, _ = decode_uclamp_se(c.get("req_min_at_place_raw"))
    eff_p, buck_p, act_p = decode_uclamp_se(c.get("eff_min_at_place_raw"))
    eff_max_p, _, _ = decode_uclamp_se(c.get("eff_max_at_place_raw"))

    def n(v):
        return "" if v is None else v

    return [
        run_id, block, arm, uclamp_min_arm, f"{run_id}-{idx}",
        n(req_w), n(eff_w), n(act_w), n(buck_w),
        n(req_p), n(eff_p), n(act_p), n(buck_p),
        n(eff_max_p),
        n(c.get("start_cpu")), n(c.get("candidate_mask")), n(c.get("min_util")),
        n(c.get("most_spare_cap")), n(c.get("order_index")), n(c.get("end_index")),
        n(c.get("skip")),
        n(c.get("prev_cpu")), n(c.get("util_raw")), n(c.get("best_energy_cpu")),
        n(c.get("fastpath")),
        n(c.get("demand_raw")), n(c.get("pred_demand")), n(c.get("misfit")),
        n(c.get("selected_cpu")), n(c.get("first_run_cpu")),
        round((c["first_run_ts"] - c["wake_ts"]) * 1e6, 1),
        initial_j, peak_j,
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--block", type=int, required=True)
    ap.add_argument("--arm", required=True)
    ap.add_argument("--uclamp-min", type=int, required=True,
                     help="the requested uclamp.min for this arm (0/256/384/448/512/...)")
    ap.add_argument("--initial-junction-c", type=float, required=True)
    ap.add_argument("--peak-junction-c", type=float, required=True)
    ap.add_argument("--header", action="store_true")
    args = ap.parse_args()

    tid = tid_from_header(args.trace)
    if tid is None:
        print(f"ERROR: no tid in {args.trace} header", file=sys.stderr)
        sys.exit(2)
    events = parse(args.trace)
    cycles = build_cycles(tid, events)
    complete = [c for c in cycles if "first_run_ts" in c]

    w = csv.writer(sys.stdout)
    if args.header:
        w.writerow(FIELDS)
    for idx, c in enumerate(complete):
        w.writerow(row_for(args.run_id, args.block, args.arm, args.uclamp_min,
                            idx, c, args.initial_junction_c, args.peak_junction_c))
    print(
        f"# {args.trace}: {len(cycles)} cycles, {len(complete)} complete, tid={tid}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
