#!/usr/bin/env python3
"""Evaluate simple burst-detector candidates on pinned S1 observer traces.

This is deliberately an in-sample, descriptive screen. The historical S1 traces
are used to understand workload shape, not to claim detector accuracy. A rule
that separates these captures can still fail on unseen apps, games, thermal
states or scheduler regimes.

The script reports activation rates for each workload and separates three roles:

- interaction_shape: scroll / launch / switch captures;
- synthetic_control: compute / wake mechanism probes;
- diagnostic: uclamp-attribution and any unclassified captures.

No rule is selected for production and no device parameter is changed.
"""

import argparse
import importlib.util
import json
import statistics
import tempfile
from pathlib import Path


def load_tool(filename, name):
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(name, here / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MANIFEST = load_tool("build-observer-manifest-report.py", "observer_manifest")
EXTRACT = load_tool("extract-observer-features.py", "observer_extract_for_candidates")

INTERACTION = {"scroll", "launch", "switch"}
SYNTHETIC = {"compute", "wake"}


def role_for(row):
    if row["label"] in INTERACTION:
        return "interaction_shape"
    if row["label"] in SYNTHETIC:
        return "synthetic_control"
    return "diagnostic"


def active(row):
    return row["total_runtime_ms"] > 0


def between(value, lo=None, hi=None):
    if value is None:
        return False
    if lo is not None and value < lo:
        return False
    if hi is not None and value > hi:
        return False
    return True


def c1_rotation(row):
    return (
        row["busy_threads"] >= 3
        and row["top4_tid_churn_pct"] >= 50.0
    )


def c2_rotation_or_leader(row):
    return (
        row["busy_threads"] >= 3
        and row["equiv_core_busy_pct"] <= 75.0
        and (
            row["top4_tid_churn_pct"] >= 50.0
            or row["leader_changed"] == 1
        )
    )


def c3_runq_rotation(row):
    return (
        row["busy_threads"] >= 3
        and row["runq_wait_per_runtime"] is not None
        and row["runq_wait_per_runtime"] >= 0.02
        and row["top4_tid_churn_pct"] >= 25.0
    )


def c4_interaction_shape(row):
    return (
        row["busy_threads"] >= 3
        and between(row["rank1_share_of_runtime_pct"], 20.0, 85.0)
        and row["top4_share_of_runtime_pct"] is not None
        and row["top4_share_of_runtime_pct"] >= 70.0
        and row["equiv_core_busy_pct"] <= 75.0
    )


def c5_strict_composite(row):
    return (
        row["busy_threads"] >= 3
        and row["rank1_share_of_runtime_pct"] is not None
        and row["rank1_share_of_runtime_pct"] <= 90.0
        and row["top4_tid_churn_pct"] >= 50.0
        and row["runq_wait_per_runtime"] is not None
        and row["runq_wait_per_runtime"] >= 0.01
        and row["equiv_core_busy_pct"] <= 75.0
    )


CANDIDATES = [
    (
        "C1_ROTATION",
        "busy_threads >= 3 and top4_tid_churn_pct >= 50",
        c1_rotation,
    ),
    (
        "C2_ROTATION_OR_LEADER",
        "busy_threads >= 3 and equiv_core_busy_pct <= 75 and "
        "(top4_tid_churn_pct >= 50 or leader_changed)",
        c2_rotation_or_leader,
    ),
    (
        "C3_RUNQ_ROTATION",
        "busy_threads >= 3 and runq_wait_per_runtime >= 0.02 and "
        "top4_tid_churn_pct >= 25",
        c3_runq_rotation,
    ),
    (
        "C4_INTERACTION_SHAPE",
        "busy_threads >= 3 and 20 <= rank1_share_of_runtime_pct <= 85 and "
        "top4_share_of_runtime_pct >= 70 and equiv_core_busy_pct <= 75",
        c4_interaction_shape,
    ),
    (
        "C5_STRICT_COMPOSITE",
        "busy_threads >= 3 and rank1_share_of_runtime_pct <= 90 and "
        "top4_tid_churn_pct >= 50 and runq_wait_per_runtime >= 0.01 and "
        "equiv_core_busy_pct <= 75",
        c5_strict_composite,
    ),
]


def load_feature_sets(manifest_path, repo):
    rows = MANIFEST.read_manifest(manifest_path)
    datasets = []
    with tempfile.TemporaryDirectory(prefix="observer-candidates-") as tmp:
        for source in rows:
            target, resolved_ref, sha, size = MANIFEST.materialise(
                repo, source, tmp
            )
            meta, windows = EXTRACT.parse_trace(target)
            features = [x for x in EXTRACT.extract_features(windows) if active(x)]
            datasets.append({
                "label": source["label"],
                "variant": source["variant"],
                "report_label": MANIFEST.source_label(source),
                "role": role_for(source),
                "resolved_ref": resolved_ref,
                "path": source["path"],
                "blob_sha": sha,
                "size_bytes": size,
                "observer_version": meta.get("version"),
                "active_windows": features,
            })
    return datasets


def pct(hit, total):
    if not total:
        return None
    return 100.0 * hit / total


def macro(values):
    vals = [x for x in values if x is not None]
    return statistics.mean(vals) if vals else None


def evaluate(manifest_path, repo):
    datasets = load_feature_sets(manifest_path, repo)
    results = []
    for name, expression, rule in CANDIDATES:
        workloads = []
        by_role = {"interaction_shape": [], "synthetic_control": [], "diagnostic": []}
        for dataset in datasets:
            features = dataset["active_windows"]
            hits = sum(1 for row in features if rule(row))
            rate = pct(hits, len(features))
            workloads.append({
                "label": dataset["label"],
                "variant": dataset["variant"],
                "report_label": dataset["report_label"],
                "role": dataset["role"],
                "active_windows": len(features),
                "triggered_windows": hits,
                "activation_pct": rate,
            })
            by_role[dataset["role"]].append(rate)
        interaction_macro = macro(by_role["interaction_shape"])
        synthetic_macro = macro(by_role["synthetic_control"])
        interaction_rates = [x for x in by_role["interaction_shape"] if x is not None]
        synthetic_rates = [x for x in by_role["synthetic_control"] if x is not None]
        results.append({
            "candidate": name,
            "expression": expression,
            "workloads": workloads,
            "interaction_macro_activation_pct": interaction_macro,
            "synthetic_macro_activation_pct": synthetic_macro,
            "in_sample_separation_pp": (
                interaction_macro - synthetic_macro
                if interaction_macro is not None and synthetic_macro is not None
                else None
            ),
            "min_interaction_activation_pct": (
                min(interaction_rates) if interaction_rates else None
            ),
            "max_synthetic_activation_pct": (
                max(synthetic_rates) if synthetic_rates else None
            ),
        })
    return {
        "status": "IN_SAMPLE_EXPLORATORY",
        "production_detector_selected": False,
        "ground_truth_latency_labels_available": False,
        "source_manifest": str(manifest_path),
        "roles": {
            "interaction_shape": sorted(INTERACTION),
            "synthetic_control": sorted(SYNTHETIC),
            "diagnostic": "all remaining manifest rows",
        },
        "limitations": [
            "same historical traces are used to shape and screen candidate rules",
            "capture-level workload names are not per-window latency ground truth",
            "250 ms observer features are research descriptors, not a production sampling cadence",
            "observer overhead and unseen apps can change feature distributions",
            "on-device holdout validation is required before any production use",
        ],
        "candidates": results,
    }


def print_summary(report):
    print("Observer detector candidates: IN-SAMPLE EXPLORATORY")
    print("production detector selected: NO")
    print("per-window latency ground truth available: NO")
    for item in report["candidates"]:
        print(
            f"{item['candidate']}: interaction_macro="
            f"{item['interaction_macro_activation_pct']:.1f}% "
            f"synthetic_macro={item['synthetic_macro_activation_pct']:.1f}% "
            f"separation={item['in_sample_separation_pp']:.1f}pp "
            f"min_interaction={item['min_interaction_activation_pct']:.1f}% "
            f"max_synthetic={item['max_synthetic_activation_pct']:.1f}%"
        )
        for w in item["workloads"]:
            print(
                f"  {w['report_label']}: {w['activation_pct']:.1f}% "
                f"({w['triggered_windows']}/{w['active_windows']})"
            )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--manifest",
        default="experiments/adaptive-burst-controller/s1-source-manifest.csv",
    )
    ap.add_argument("--repo", default=".")
    ap.add_argument("-o", "--output")
    ap.add_argument("--summary", action="store_true")
    args = ap.parse_args()
    try:
        report = evaluate(args.manifest, args.repo)
    except ValueError as exc:
        ap.error(str(exc))
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    if args.summary or not args.output:
        print_summary(report)


if __name__ == "__main__":
    main()
