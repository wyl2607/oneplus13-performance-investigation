#!/usr/bin/env python3
"""Turn one S2b run's raw scheduler-event-tracer trace into CSV rows matching
tools/analyze-s2b.py's schema (run_id, block, arm, cycle_id, ...).

Cycle reconstruction (wake -> first run) reuses the approach in
tools/analyze-wake-cycles.py (PR #13), extended to also decode the
--uclamp-offsets kprobe (kprobes:s2a_uclamp) so requested/effective uclamp.min
can be read at the moment closest to placement, instead of trusting the
`uclampset -p` readback taken before the tracer started. The two can diverge:
that divergence is exactly what CLAMP_NOT_SEPARATED is checking for.

usage:
  s2b-trace-to-csv.py TRACE --run-id ID --block N --arm A|B
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
    "run_id", "block", "arm", "cycle_id",
    "requested_min", "effective_min", "pred_demand",
    "start_cpu", "candidate_mask", "misfit",
    "selected_cpu", "first_run_cpu", "wake_latency_us",
    "initial_junction_c", "peak_junction_c",
]


def i(d, k, default=None):
    """int() of a trace field; ftrace zero-pads (target_cpu=002) so base-0
    parsing misreads it as octal. See analyze-wake-cycles.py's own note."""
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
    """value:11 bucket_id:5 active:1 user_defined:1, per tools/btf-offsets.py."""
    if raw is None:
        return None
    return raw & 0x7FF


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
    """One cycle: sched_waking -> the switch-out that puts the thread to
    sleep. Mirrors analyze-wake-cycles.py's build_cycles, plus tracks every
    kprobe s2a_uclamp hit seen while the cycle is open and keeps the LAST one
    before first_run_ts as the placement-time clamp reading."""
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
            if "first_run_ts" not in cur:
                cur["last_req_min_raw"] = i(f, "req_min")
                cur["last_eff_min_raw"] = i(f, "eff_min")
        elif ev == "sched_task_util":
            cur.setdefault("start_cpu", i(f, "start_cpu"))
            cur.setdefault("candidate_mask", i(f, "candidates"))
        elif ev == "sched_find_best_target":
            cur.setdefault("start_cpu", i(f, "start_cpu"))
            cur.setdefault("candidate_mask", i(f, "candidates"))
        elif ev == "sched_enq_deq_task":
            cur.setdefault("pred_demand", i(f, "pred_demand_scaled"))
            cur.setdefault("misfit", i(f, "misfit"))
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--block", type=int, required=True)
    ap.add_argument("--arm", required=True, choices=["A", "B"])
    ap.add_argument("--requested-min", type=int, required=True)
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
        eff = decode_uclamp_se(c.get("last_eff_min_raw"))
        req = decode_uclamp_se(c.get("last_req_min_raw"))
        w.writerow([
            args.run_id, args.block, args.arm, f"{args.run_id}-{idx}",
            req if req is not None else "", eff if eff is not None else "",
            c.get("pred_demand", ""),
            c.get("start_cpu", ""), c.get("candidate_mask", ""),
            c.get("misfit", ""),
            c.get("selected_cpu", ""), c.get("first_run_cpu", ""),
            round((c["first_run_ts"] - c["wake_ts"]) * 1e6, 1),
            args.initial_junction_c, args.peak_junction_c,
        ])
    print(
        f"# {args.trace}: {len(cycles)} cycles, {len(complete)} complete, tid={tid}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
