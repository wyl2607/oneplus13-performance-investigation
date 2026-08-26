#!/usr/bin/env python3
"""Diff two cpufreq stats/time_in_state snapshots (before/after a run) for
policy0 (mid cluster) and policy6 (prime cluster) and print CSV rows:
run_id,uclamp_min,cluster,freq_khz,jiffies_before,jiffies_after,jiffies_delta

time_in_state format is one "freq_khz jiffies" line per supported frequency,
cumulative since boot (or since stats/reset) -- so a before/after delta
isolates exactly the jiffies spent at each frequency during the run, with
zero tracing overhead (two sysfs reads, no kernel tracepoint involved).
"""
import argparse
import csv
import sys


def read_tis(path):
    table = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                freq, jiffies = line.split()
                table[int(freq)] = int(jiffies)
    except FileNotFoundError:
        return None
    return table


def diff_cluster(run_id, umin, cluster, before_path, after_path, writer):
    before = read_tis(before_path)
    after = read_tis(after_path)
    if before is None or after is None:
        print(f"WARN: missing time_in_state snapshot for {cluster} "
              f"({before_path} / {after_path})", file=sys.stderr)
        return
    freqs = sorted(set(before) | set(after))
    for freq in freqs:
        b = before.get(freq, 0)
        a = after.get(freq, b)
        delta = a - b
        writer.writerow([run_id, umin, cluster, freq, b, a, delta])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--uclamp-min", required=True, type=int)
    ap.add_argument("--policy0-before", required=True)
    ap.add_argument("--policy0-after", required=True)
    ap.add_argument("--policy6-before", required=True)
    ap.add_argument("--policy6-after", required=True)
    args = ap.parse_args()

    writer = csv.writer(sys.stdout)
    diff_cluster(args.run_id, args.uclamp_min, "policy0_mid",
                 args.policy0_before, args.policy0_after, writer)
    diff_cluster(args.run_id, args.uclamp_min, "policy6_prime",
                 args.policy6_before, args.policy6_after, writer)


if __name__ == "__main__":
    main()
