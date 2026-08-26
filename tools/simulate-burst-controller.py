#!/usr/bin/env python3
"""Replay a bounded adaptive-burst controller against an offline event stream.

This models control-state timing only. It does not predict performance and it
never writes uclamp, cpufreq or thermal state. `burst_signal` is an input from a
future detector; this tool intentionally does not invent that detector before
real foreground traces establish one.
"""

import argparse
import csv
import json
from pathlib import Path


REQUIRED = {"t_ms", "burst_signal", "junction_c"}


def load_samples(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        missing = REQUIRED - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"missing required columns: {', '.join(sorted(missing))}")
        rows = []
        last_t = None
        for lineno, raw in enumerate(reader, start=2):
            try:
                t = float(raw["t_ms"])
                signal = int(raw["burst_signal"])
                temp = float(raw["junction_c"])
                foreground = int(raw.get("foreground") or 1)
                screen_on = int(raw.get("screen_on") or 1)
            except ValueError as exc:
                raise ValueError(f"line {lineno}: invalid sample value") from exc
            if signal not in (0, 1) or foreground not in (0, 1) or screen_on not in (0, 1):
                raise ValueError(f"line {lineno}: flags must be 0 or 1")
            if last_t is not None and t <= last_t:
                raise ValueError(f"line {lineno}: t_ms must be strictly increasing")
            last_t = t
            rows.append({
                "t_ms": t,
                "burst_signal": signal,
                "junction_c": temp,
                "foreground": foreground,
                "screen_on": screen_on,
            })
    if not rows:
        raise ValueError("empty sample stream")
    return rows


def replay(
    samples,
    trigger_samples,
    min_hold_ms,
    max_boost_ms,
    cooldown_ms,
    thermal_gate_c,
):
    if trigger_samples < 1:
        raise ValueError("trigger_samples must be >= 1")
    for name, value in (
        ("min_hold_ms", min_hold_ms),
        ("max_boost_ms", max_boost_ms),
        ("cooldown_ms", cooldown_ms),
    ):
        if value < 0:
            raise ValueError(f"{name} must be >= 0")
    if max_boost_ms < min_hold_ms:
        raise ValueError("max_boost_ms must be >= min_hold_ms")

    state = "IDLE"
    signal_run = 0
    boost_start = None
    cooldown_until = None
    timeline = []
    transitions = []
    aborted_thermal = 0
    blocked_ineligible = 0

    def transition(t, new_state, reason):
        nonlocal state
        if new_state != state:
            transitions.append({
                "t_ms": t,
                "from": state,
                "to": new_state,
                "reason": reason,
            })
            state = new_state

    for sample in samples:
        t = sample["t_ms"]
        eligible = bool(sample["foreground"] and sample["screen_on"])
        thermal_ok = sample["junction_c"] < thermal_gate_c

        if state == "COOLDOWN" and t >= cooldown_until:
            transition(t, "IDLE", "cooldown_expired")
            signal_run = 0

        if state == "BOOST":
            elapsed = t - boost_start
            if not eligible:
                blocked_ineligible += 1
                transition(t, "COOLDOWN", "lost_foreground_or_screen")
                cooldown_until = t + cooldown_ms
                signal_run = 0
            elif not thermal_ok:
                aborted_thermal += 1
                transition(t, "COOLDOWN", "thermal_gate")
                cooldown_until = t + cooldown_ms
                signal_run = 0
            elif elapsed >= max_boost_ms:
                transition(t, "COOLDOWN", "max_boost")
                cooldown_until = t + cooldown_ms
                signal_run = 0
            elif elapsed >= min_hold_ms and not sample["burst_signal"]:
                transition(t, "COOLDOWN", "signal_cleared_after_hold")
                cooldown_until = t + cooldown_ms
                signal_run = 0

        if state == "IDLE":
            if eligible and thermal_ok and sample["burst_signal"]:
                signal_run += 1
            else:
                if sample["burst_signal"] and not eligible:
                    blocked_ineligible += 1
                signal_run = 0
            if signal_run >= trigger_samples:
                transition(t, "BOOST", "burst_trigger")
                boost_start = t
                signal_run = 0

        timeline.append({
            **sample,
            "state": state,
            "boost_active": state == "BOOST",
        })

    boost_samples = sum(1 for x in timeline if x["boost_active"])
    return {
        "status": "OFFLINE_CONTROL_REPLAY",
        "performance_effect_validated": False,
        "parameters": {
            "trigger_samples": trigger_samples,
            "min_hold_ms": min_hold_ms,
            "max_boost_ms": max_boost_ms,
            "cooldown_ms": cooldown_ms,
            "thermal_gate_c": thermal_gate_c,
        },
        "summary": {
            "samples": len(timeline),
            "boost_samples": boost_samples,
            "boost_sample_share_pct": 100.0 * boost_samples / len(timeline),
            "boost_entries": sum(1 for x in transitions if x["to"] == "BOOST"),
            "thermal_aborts": aborted_thermal,
            "ineligible_blocks_or_aborts": blocked_ineligible,
        },
        "transitions": transitions,
        "timeline": timeline,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--trigger-samples", type=int, required=True)
    ap.add_argument("--min-hold-ms", type=float, required=True)
    ap.add_argument("--max-boost-ms", type=float, required=True)
    ap.add_argument("--cooldown-ms", type=float, required=True)
    ap.add_argument("--thermal-gate-c", type=float, required=True)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    try:
        report = replay(
            load_samples(args.csv),
            args.trigger_samples,
            args.min_hold_ms,
            args.max_boost_ms,
            args.cooldown_ms,
            args.thermal_gate_c,
        )
    except ValueError as exc:
        ap.error(str(exc))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return
    s = report["summary"]
    print("Adaptive burst controller: OFFLINE CONTROL REPLAY")
    print("  performance effect validated: NO")
    print(f"  boost entries: {s['boost_entries']}")
    print(f"  boost sample share: {s['boost_sample_share_pct']:.1f}%")
    print(f"  thermal aborts: {s['thermal_aborts']}")
    for tr in report["transitions"]:
        print(
            f"  {tr['t_ms']:g} ms: {tr['from']} -> {tr['to']} ({tr['reason']})"
        )


if __name__ == "__main__":
    main()
