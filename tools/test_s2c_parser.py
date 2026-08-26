#!/usr/bin/env python3
"""Parser tests for s2c-trace-to-csv.py: cycle boundaries, uclamp bitfield
decode, and the null/no-forward-fill contract for fields that don't fire in a
given cycle. Run: python3 tools/test_s2c_parser.py"""

import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "s2c", Path(__file__).parent / "s2c-trace-to-csv.py"
)
s2c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s2c)

TID = 25133

# Cycle 1: full pipeline, prime-selected (start_cpu=6 from the first
# find_best_target call, before enqueue/misfit is even evaluated).
# Cycle 2: waking + switch only, no find_best_target/task_util/enqueue at all
# -- must NOT inherit cycle 1's start_cpu/prev_cpu/etc.
TRACE = """\
# scheduler-event-tracer
# tid=25133 comm=w-wake comm_glob= alive_at_end=yes
# loss=none
          <idle>-0       [006] d.h3. 100.000100: sched_waking: comm=w-wake pid=25133 prio=120 target_cpu=006
          <idle>-0       [006] d.h3. 100.000101: s2a_uclamp: (uclamp_eff_value+0x0/0x134) tpid=25133 req_min=0x25200 req_max=0x9c00 eff_min=0x25200 eff_max=0x9c00
          <idle>-0       [006] d.h3. 100.000102: sched_find_best_target: pid=25133 comm=w-wake start_cpu=6 candidates=0x40 most_spare_cap=-1 order_index=1 end_index=0 skip=-1 running=0 min_util=512 spare_rq_cpu=-1 min_runnable=4294967295
          <idle>-0       [006] d.h3. 100.000103: sched_task_util: pid=25133 comm=w-wake util=158 prev_cpu=6 candidates=0x40 best_energy_cpu=6 sync=0 need_idle=0 fastpath=2 placement_boost=0 latency=10468 stune_boosted=0 is_rtg=0 rtg_skip_min=0 start_cpu=6 unfilter=100000000 affinity=ff task_boost=0 low_latency=0 iowaited=0 load_boost=0 sync_state=1 pipeline_cpu=-1 yield_cnt=0
          <idle>-0       [006] d.h4. 100.000104: s2a_uclamp: (uclamp_eff_value+0x0/0x134) tpid=25133 req_min=0x25200 req_max=0x9c00 eff_min=0x35200 eff_max=0x39c00
          <idle>-0       [006] d.h4. 100.000105: sched_enq_deq_task: cpu=6 enqueue comm=w-wake pid=25133 prio=120 nr_running=0 rt_nr_running=0 affine=ff demand=2475743 pred_demand_scaled=158 is_compat_t=0 mvp=0 misfit=0
          <idle>-0       [006] dNh4. 100.000106: sched_wakeup: comm=w-wake pid=25133 prio=120 target_cpu=006
          <idle>-0       [006] d..2. 100.000110: sched_switch: prev_comm=swapper/6 prev_pid=0 prev_prio=120 prev_state=R ==> next_comm=w-wake next_pid=25133 next_prio=120
          w-wake-25133   [006] d..2. 100.000200: sched_switch: prev_comm=w-wake prev_pid=25133 prev_prio=120 prev_state=S ==> next_comm=swapper/6 next_pid=0 next_prio=120
          <idle>-0       [006] d.h3. 100.100100: sched_waking: comm=w-wake pid=25133 prio=120 target_cpu=006
          <idle>-0       [006] d..2. 100.100110: sched_switch: prev_comm=swapper/6 prev_pid=0 prev_prio=120 prev_state=R ==> next_comm=w-wake next_pid=25133 next_prio=120
          w-wake-25133   [006] d..2. 100.100200: sched_switch: prev_comm=w-wake prev_pid=25133 prev_prio=120 prev_state=S ==> next_comm=swapper/6 next_pid=0 next_prio=120
"""


def _parse_text(text):
    lines = [ln for ln in text.splitlines()]
    events = []
    for ln in lines:
        if ln.startswith("#") or not ln.strip():
            continue
        m = s2c.LINE.match(ln)
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
            sm = s2c.SWITCH.search(rest)
            if sm:
                ev.update(
                    prev_pid=int(sm.group("prev_pid")),
                    next_pid=int(sm.group("next_pid")),
                    prev_state=sm.group("prev_state"),
                )
        else:
            ev["f"] = dict(s2c.KV.findall(rest))
        events.append(ev)
    return events


def main():
    events = _parse_text(TRACE)
    cycles = s2c.build_cycles(TID, events)
    assert len(cycles) == 2, f"expected 2 cycles, got {len(cycles)}"

    c1, c2 = cycles
    assert "first_run_ts" in c1, "cycle 1 should be complete"
    assert c1["start_cpu"] == 6
    assert c1["candidate_mask"] == 0x40
    assert c1["prev_cpu"] == 6
    assert c1["selected_cpu"] == 6
    assert c1["first_run_cpu"] == 6
    assert c1["misfit"] == 0
    assert c1["order_index"] == 1
    assert c1["min_util"] == 512

    eff_w, buck_w, act_w = s2c.decode_uclamp_se(c1["eff_min_at_wake_raw"])
    assert eff_w == 512, f"eff_min_at_wake should decode to 512, got {eff_w}"
    assert act_w == 0, "uclamp should not be 'active' yet at the wake reading"

    eff_p, buck_p, act_p = s2c.decode_uclamp_se(c1["eff_min_at_place_raw"])
    assert eff_p == 512, f"eff_min_at_place should decode to 512, got {eff_p}"
    assert act_p == 1, "uclamp should be 'active' by the placement reading"

    # cycle 2 has NO find_best_target/task_util/enqueue at all -- these fields
    # must be absent (None), never inherited from cycle 1.
    assert "first_run_ts" in c2, "cycle 2 should still be complete (has a switch-in)"
    for key in ("start_cpu", "candidate_mask", "prev_cpu", "min_util",
                "demand_raw", "pred_demand", "misfit", "fastpath"):
        assert key not in c2, f"cycle 2 must not inherit '{key}' from cycle 1 (got {c2.get(key)!r})"

    row = s2c.row_for("t01", 1, "B", 512, 0, c1, 40.0, 41.0)
    idx = s2c.FIELDS.index("start_cpu")
    assert row[idx] == 6
    idx2 = s2c.FIELDS.index("start_cpu")

    row2 = s2c.row_for("t01", 1, "B", 512, 1, c2, 40.0, 41.0)
    idx3 = s2c.FIELDS.index("start_cpu")
    assert row2[idx3] == "", f"missing field must serialize as '', got {row2[idx3]!r}"

    print("OK: 8 assertions passed (cycle boundaries, bitfield decode, no-forward-fill)")


if __name__ == "__main__":
    main()
