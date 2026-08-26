#!/usr/bin/env python3
"""Materialise observer traces from a git source manifest and build a report.

The manifest pins each historical capture by ref, repository path, git blob SHA
and byte size. This tool resolves the source inside the local git repository,
verifies those provenance fields, materialises the exact bytes into a temporary
directory, and then reuses build-observer-workload-report.py.

It does not select a detector threshold and does not require a phone.
"""

import argparse
import csv
import importlib.util
import json
import subprocess
import tempfile
from pathlib import Path


def load_tool(filename, name):
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(name, here / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


REPORT = load_tool("build-observer-workload-report.py", "observer_report")

REQUIRED = {
    "label",
    "variant",
    "source_ref",
    "path",
    "blob_sha",
    "size_bytes",
}


def git(repo, *args, binary=False):
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=not binary,
    )
    return result.stdout


def read_manifest(path):
    with Path(path).open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fields = set(reader.fieldnames or [])
        missing = REQUIRED - fields
        if missing:
            raise ValueError(
                "manifest missing columns: " + ", ".join(sorted(missing))
            )
        rows = []
        seen = set()
        for lineno, row in enumerate(reader, start=2):
            key = (row["label"].strip(), row["variant"].strip())
            if not all(key):
                raise ValueError(f"manifest line {lineno}: empty label/variant")
            if key in seen:
                raise ValueError(
                    f"manifest line {lineno}: duplicate label/variant {key}"
                )
            seen.add(key)
            try:
                size = int(row["size_bytes"])
            except ValueError as exc:
                raise ValueError(
                    f"manifest line {lineno}: invalid size_bytes"
                ) from exc
            rows.append({
                "label": key[0],
                "variant": key[1],
                "source_ref": row["source_ref"].strip(),
                "path": row["path"].strip(),
                "blob_sha": row["blob_sha"].strip().lower(),
                "size_bytes": size,
            })
    if not rows:
        raise ValueError("manifest has no sources")
    return rows


def resolve_ref(repo, source_ref):
    candidates = [source_ref, f"origin/{source_ref}"]
    for candidate in candidates:
        try:
            git(repo, "rev-parse", "--verify", f"{candidate}^{{commit}}")
            return candidate
        except subprocess.CalledProcessError:
            continue
    raise ValueError(
        f"source ref {source_ref!r} is not available locally; fetch it first"
    )


def source_label(row):
    return f"{row['label']}__{row['variant']}"


def materialise(repo, row, out_dir):
    ref = resolve_ref(repo, row["source_ref"])
    spec = f"{ref}:{row['path']}"
    try:
        actual_sha = git(repo, "rev-parse", spec).strip().lower()
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"cannot resolve source {spec}") from exc
    if actual_sha != row["blob_sha"]:
        raise ValueError(
            f"{spec}: blob SHA mismatch: expected {row['blob_sha']}, got {actual_sha}"
        )
    try:
        actual_size = int(git(repo, "cat-file", "-s", actual_sha).strip())
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"cannot read blob size for {spec}") from exc
    if actual_size != row["size_bytes"]:
        raise ValueError(
            f"{spec}: size mismatch: expected {row['size_bytes']}, got {actual_size}"
        )
    try:
        payload = git(repo, "show", spec, binary=True)
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"cannot materialise source {spec}") from exc
    if len(payload) != actual_size:
        raise ValueError(
            f"{spec}: materialised byte size {len(payload)} != git size {actual_size}"
        )
    target = Path(out_dir) / f"{source_label(row)}.txt"
    target.write_bytes(payload)
    return target, ref, actual_sha, actual_size


def build_from_manifest(manifest, repo):
    rows = read_manifest(manifest)
    inputs = []
    provenance = []
    with tempfile.TemporaryDirectory(prefix="observer-manifest-") as tmp:
        for row in rows:
            target, resolved_ref, sha, size = materialise(repo, row, tmp)
            label = source_label(row)
            inputs.append(f"{label}={target}")
            provenance.append({
                "label": row["label"],
                "variant": row["variant"],
                "report_label": label,
                "source_ref": row["source_ref"],
                "resolved_ref": resolved_ref,
                "path": row["path"],
                "blob_sha": sha,
                "size_bytes": size,
                "verified": True,
            })
        report = REPORT.build(inputs)
    report["source_manifest"] = str(manifest)
    report["source_provenance"] = provenance
    report["all_sources_verified"] = all(x["verified"] for x in provenance)
    return report


def print_summary(report):
    print("S1 real-workload observer report: DESCRIPTIVE ONLY")
    print(f"all sources verified: {report['all_sources_verified']}")
    print("detector threshold selected: NO")
    for workload in report["workloads"]:
        active = workload["active_windows_only"]
        def p50(metric):
            value = active[metric]["p50"]
            return "NA" if value is None else f"{value:.2f}"
        print(
            f"{workload['label']}: windows={workload['windows']} "
            f"active={workload['active_windows']} "
            f"busy_threads_p50={p50('busy_threads')} "
            f"equiv_core_busy_p50={p50('equiv_core_busy_pct')} "
            f"rank1_share_p50={p50('rank1_share_of_runtime_pct')} "
            f"top4_share_p50={p50('top4_share_of_runtime_pct')} "
            f"top4_churn_p50={p50('top4_tid_churn_pct')} "
            f"runq_ratio_p50={p50('runq_wait_per_runtime')}"
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
        report = build_from_manifest(args.manifest, args.repo)
    except (ValueError, subprocess.CalledProcessError) as exc:
        ap.error(str(exc))
    if args.output:
        Path(args.output).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    if args.summary or not args.output:
        print_summary(report)


if __name__ == "__main__":
    main()
