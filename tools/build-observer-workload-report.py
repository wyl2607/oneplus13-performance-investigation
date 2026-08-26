#!/usr/bin/env python3
"""Build a cross-workload report directly from observer-v2 trace files.

This composes the existing extractor and summarizer in memory so historical S1
captures can be compared without creating intermediate CSVs. The report remains
descriptive and never selects a detector threshold.
"""

import argparse
import importlib.util
import json
from pathlib import Path


def load_tool(filename, name):
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(name, here / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


EXTRACT = load_tool("extract-observer-features.py", "observer_extract")
SUMMARY = load_tool("summarize-observer-features.py", "observer_summary")


def parse_input(value):
    if "=" not in value:
        raise ValueError("input must be LABEL=TRACE")
    label, path = value.split("=", 1)
    label = label.strip()
    path = path.strip()
    if not label or not path:
        raise ValueError("input must be LABEL=TRACE")
    return label, path


def to_summary_rows(features):
    rows = []
    for feature in features:
        row = {name: feature.get(name) for name in SUMMARY.METRICS}
        row["total_runtime_ms"] = feature["total_runtime_ms"]
        row["leader_changed"] = feature["leader_changed"]
        rows.append(row)
    return rows


def build(inputs):
    seen = set()
    workloads = []
    sources = []
    for value in inputs:
        label, path = parse_input(value)
        if label in seen:
            raise ValueError(f"duplicate workload label: {label}")
        seen.add(label)
        meta, windows = EXTRACT.parse_trace(path)
        features = EXTRACT.extract_features(windows)
        workloads.append(SUMMARY.summarise(label, to_summary_rows(features)))
        sources.append({
            "label": label,
            "path": str(path),
            "observer_version": meta.get("version"),
            "windows": len(features),
        })
    if not workloads:
        raise ValueError("at least one --input is required")
    return {
        "status": "DESCRIPTIVE_ONLY",
        "detector_threshold_selected": False,
        "sources": sources,
        "metrics": SUMMARY.METRICS,
        "workloads": workloads,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--input",
        action="append",
        required=True,
        metavar="LABEL=TRACE",
        help="named observer-v2 trace; repeat for multiple workloads",
    )
    ap.add_argument("-o", "--output")
    args = ap.parse_args()
    try:
        report = build(args.input)
    except ValueError as exc:
        ap.error(str(exc))
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
