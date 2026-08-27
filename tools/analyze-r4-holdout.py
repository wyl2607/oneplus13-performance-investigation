#!/usr/bin/env python3
"""Analyze R4 burst-detector holdout captures
(experiments/burst-detector-holdout/README.md).

Reads the session-state.json produced by tools/run-r4-holdout.py, and for
every run recorded there with a status safe to include (README's "do not
collapse the result to one accuracy number" -- non-OK statuses are excluded
from the default summary the same way tools/analyze-r3-real-app.py excludes
them, not silently blended in), pairs its manifest log (RESULT/EVENT/#META
lines) with its dominant-thread-observer trace and reports two SEPARATE
things, per the README's "Two separate R4 questions":

  A. legacy detector analysis  -- does frozen C2/C4 fire on the originally
     intended interaction-transition shape, using `role` as a shape label?
  B. controller-utility matrix -- would triggering the module look useful on
     this workload, using ONLY measured evidence, defaulting UNKNOWN?

C2/C4's expressions themselves are imported unchanged from
evaluate-observer-detector-candidates.py: this file must never redefine or
retune them (docs/METHODOLOGY.md, "Frozen means frozen" in the README).

No verdict is chosen here. The "Final R4 verdict" section of the README asks
for a human answer to whether either detector is credible; this tool reports
the sixteen input numbers, not the fifteenth conclusion.
"""

import argparse
import importlib.util
import json
import statistics
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def load_tool(filename, name):
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(name, here / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


EXTRACT = load_tool("extract-observer-features.py", "r4_observer_extract")
CANDIDATES_MOD = load_tool("evaluate-observer-detector-candidates.py", "r4_candidates")

# Frozen, unchanged (README "Frozen candidates" / "Frozen means frozen").
C2 = ("C2_ROTATION_OR_LEADER", CANDIDATES_MOD.c2_rotation_or_leader)
C4 = ("C4_INTERACTION_SHAPE", CANDIDATES_MOD.c4_interaction_shape)
CANDIDATES = [C2, C4]

CONTINUE_STATUSES = {"OK", "NO_TOTALTIME_PARSED"}

# README "Controller-utility analysis": carried over from R3 by inferred
# shape similarity only, never this plan's own measured evidence yet. Do not
# add a row here from a workload name or role -- only from an explicit,
# cited paired measurement. Kept as data, not logic, so a future real R4
# measurement replaces a row without touching the analysis code.
UTILITY_PRIORS = {
    "browser_scroll": {
        "label": "BENEFIT_POSITIVE",
        "basis": "SHAPE_SIMILARITY_ONLY",
        "evidence": "R3 scroll_fling: p95 9.8ms -> 5.2ms, jank 0.4%->0.2%",
    },
    "steady_game_title": {
        "label": "BENEFIT_POSITIVE",
        "basis": "SHAPE_SIMILARITY_ONLY",
        "evidence": "R3 steady_renderer: p95 14.0ms -> 9.2ms, jank 2.5%->0.0%, no placement shift",
    },
    "app_launch_cold": {
        "label": "BENEFIT_NEGATIVE",
        "basis": "SHAPE_SIMILARITY_ONLY",
        "evidence": "R3 cold_launch: +9.5ms delta, SD 33-48ms, not distinguishable from noise (n=4 pairs)",
    },
    "app_launch_warm": {
        "label": "BENEFIT_NEGATIVE",
        "basis": "SHAPE_SIMILARITY_ONLY",
        "evidence": "R3 cold_launch: +9.5ms delta, SD 33-48ms, not distinguishable from noise (n=4 pairs)",
    },
    "app_switch": {
        "label": "BENEFIT_NEGATIVE",
        "basis": "EXACT_MATCH",
        "evidence": "R3 app_switch: -0.75ms delta, negligible",
    },
    # Everything else (camera_launch, steady_gameplay, video_playback,
    # background_download, synthetic_compute, synthetic_wake) stays UNKNOWN
    # by omission -- README: "Default for anything not explicitly measured.
    # Do not infer a label from workload name or role."
}


def utility_label(workload_id):
    prior = UTILITY_PRIORS.get(workload_id)
    if prior is None:
        return {"label": "UNKNOWN", "basis": "NOT_MEASURED", "evidence": None}
    return prior


def parse_manifest(path):
    """Pull #META/EVENT/RESULT lines out of a run-r4-one.sh manifest log."""
    meta = {}
    events = []
    result = {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("#META "):
            for tok in line[len("#META "):].split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    meta[k] = v
        elif line.startswith("EVENT|"):
            parts = dict(p.split("=", 1) for p in line.split("|")[1:] if "=" in p)
            events.append(parts)
        elif line.startswith("RESULT "):
            for tok in line[len("RESULT "):].split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    result[k] = v
    return {"meta": meta, "events": events, "result": result}


def event_windows_ms(events):
    """[(start_ms, end_ms), ...] pairs keyed only by phase order -- one
    start/end pair per run in this protocol (README's marker stream)."""
    starts = [int(e["t_ms"]) for e in events if e.get("phase") == "start"]
    ends = [int(e["t_ms"]) for e in events if e.get("phase") == "end"]
    return list(zip(starts, ends))


def window_in_event(window_t_ms, windows):
    return any(start <= window_t_ms <= end for start, end in windows)


def analyze_run(manifest_path, observer_path):
    manifest = parse_manifest(manifest_path)
    _obs_meta, windows = EXTRACT.parse_trace(observer_path)
    features = EXTRACT.extract_features(windows)
    active = [f for f in features if f["total_runtime_ms"] > 0]

    ev_windows = event_windows_ms(manifest["events"])
    has_events = bool(ev_windows)

    rows = []
    for f in active:
        t_ms = f["t_cs"] * 10
        rows.append({
            "t_ms": t_ms,
            "in_event": window_in_event(t_ms, ev_windows) if has_events else None,
            "top4_tid_churn_pct": f["top4_tid_churn_pct"],
            **{name: rule(f) for name, rule in CANDIDATES},
        })
    return {"manifest": manifest, "has_events": has_events, "windows": rows}


def pct(hit, total):
    return 100.0 * hit / total if total else None


def summarize_workload(run_analyses, workload_id, role):
    """run_analyses: list of analyze_run() outputs for one workload_id,
    already split by module_state by the caller."""
    out = {"workload_id": workload_id, "role": role}
    for name, _ in CANDIDATES:
        all_hits = sum(1 for r in run_analyses for w in r["windows"] if w[name])
        all_total = sum(len(r["windows"]) for r in run_analyses)
        out[f"{name}_activation_pct"] = pct(all_hits, all_total)
        out[f"{name}_active_windows"] = all_total

        event_hits = sum(1 for r in run_analyses for w in r["windows"] if w["in_event"] and w[name])
        event_total = sum(1 for r in run_analyses for w in r["windows"] if w["in_event"])
        non_event_hits = sum(1 for r in run_analyses for w in r["windows"] if w["in_event"] is False and w[name])
        non_event_total = sum(1 for r in run_analyses for w in r["windows"] if w["in_event"] is False)
        out[f"{name}_event_window_activation_pct"] = pct(event_hits, event_total)
        out[f"{name}_non_event_window_activation_pct"] = pct(non_event_hits, non_event_total)

    churns = [w["top4_tid_churn_pct"] for r in run_analyses for w in r["windows"]]
    out["mean_top4_tid_churn_pct"] = statistics.mean(churns) if churns else None
    out["n_runs"] = len(run_analyses)
    return out


def module_state_delta(off_summary, on_summary, candidate_name):
    off = off_summary.get(f"{candidate_name}_activation_pct")
    on = on_summary.get(f"{candidate_name}_activation_pct")
    if off is None or on is None:
        return None
    return on - off


NEGATIVE_ROLES = {"steady_negative", "background_negative", "synthetic_control"}


def build_report(session_state, raw_dir):
    raw_dir = Path(raw_dir)
    completed = session_state["completed"]

    by_workload = {}
    parse_errors = []
    for run_id, record in completed.items():
        if record["status"] not in CONTINUE_STATUSES:
            continue
        manifest_path = Path(record["out"])
        observer_path = Path(record["observer_out"])
        if not manifest_path.exists() or not observer_path.exists():
            parse_errors.append({"run_id": run_id, "reason": "missing manifest or observer file"})
            continue
        try:
            analysis = analyze_run(manifest_path, observer_path)
        except ValueError as exc:
            # A trace that failed to parse (e.g. no WINDOW records at all --
            # can happen for a run cut short) is excluded and reported, the
            # same "excluded with a note, not silently folded in" discipline
            # as a non-OK status, not a reason to abort the whole report.
            parse_errors.append({"run_id": run_id, "reason": str(exc)})
            continue
        key = (record["workload_id"], record["module_state"])
        by_workload.setdefault(key, []).append(analysis)

    roles = {}
    for run_id, record in completed.items():
        roles.setdefault(record["workload_id"], record.get("role"))

    workloads = sorted({wl for wl, _ in by_workload})
    legacy = []
    utility_matrix = []
    for wl in workloads:
        role = roles.get(wl)
        off_runs = by_workload.get((wl, "module_off"), [])
        on_runs = by_workload.get((wl, "module_on"), [])
        off_summary = summarize_workload(off_runs, wl, role) if off_runs else None
        on_summary = summarize_workload(on_runs, wl, role) if on_runs else None

        entry = {"workload_id": wl, "role": role, "module_off": off_summary, "module_on": on_summary}
        for name, _ in CANDIDATES:
            if off_summary and on_summary:
                entry[f"{name}_module_state_delta_pp"] = module_state_delta(off_summary, on_summary, name)
        entry["is_negative_control"] = role in NEGATIVE_ROLES
        legacy.append(entry)

        util = utility_label(wl)
        utility_matrix.append({
            "workload_id": wl,
            "C2_activation_pct": (off_summary or on_summary or {}).get("C2_ROTATION_OR_LEADER_activation_pct"),
            "C4_activation_pct": (off_summary or on_summary or {}).get("C4_INTERACTION_SHAPE_activation_pct"),
            "utility_label": util["label"],
            "utility_basis": util["basis"],
            "utility_evidence": util["evidence"],
        })

    return {
        "status": "R4_HOLDOUT_ANALYSIS",
        "frozen_candidates": [name for name, _ in CANDIDATES],
        "excluded_statuses_note": (
            "runs with a status outside " + repr(sorted(CONTINUE_STATUSES)) +
            " are excluded from these tables, not silently folded in"
        ),
        "parse_errors": parse_errors,
        "legacy_detector_analysis": legacy,
        "utility_matrix": utility_matrix,
        "final_verdict_template": {
            "c2_activation_by_workload": "see legacy_detector_analysis",
            "c4_activation_by_workload": "see legacy_detector_analysis",
            "event_vs_non_event_discrimination": "see *_event_window_activation_pct / *_non_event_window_activation_pct",
            "steady_rendering_behavior": "see legacy_detector_analysis for steady_negative rows",
            "gameplay_video_download_behavior": "see legacy_detector_analysis for steady_negative/background_negative rows",
            "false_positive_regimes": "see legacy_detector_analysis rows where is_negative_control is true",
            "detector_overhead": "NOT computed here -- see Phase 7 overhead-validation report",
            "either_detector_credible": None,
            "neither_detector_survives": None,
            "controller_utility_alignment": "see utility_matrix",
            "rendering_pressure_vs_transition_semantics": None,
            "device_clean": None,
            "commit_sha": git_head_sha(),
            "pr_url": None,
            "verdict": None,
        },
        "allowed_verdicts": ["C2_SURVIVES", "C4_SURVIVES", "BOTH_SURVIVE", "NEITHER_SURVIVES", "INCONCLUSIVE"],
    }


def git_head_sha():
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, capture_output=True,
                              text=True, check=True, timeout=10)
        return out.stdout.strip()
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--session-state",
                     default=str(REPO_ROOT / "experiments/burst-detector-holdout/raw/session-state.json"))
    ap.add_argument("--raw-dir", default=str(REPO_ROOT / "experiments/burst-detector-holdout/raw"))
    ap.add_argument("-o", "--output")
    args = ap.parse_args()

    session_state = json.loads(Path(args.session_state).read_text(encoding="utf-8"))
    report = build_report(session_state, args.raw_dir)
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        print(text)


if __name__ == "__main__":
    main()
