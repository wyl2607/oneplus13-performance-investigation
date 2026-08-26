#!/usr/bin/env python3
import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_tool(filename, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


SUM = load_tool("summarize-observer-features.py", "observer_summary")


class ObserverSummaryTests(unittest.TestCase):
    def feature_file(self, root, name, runtimes, busy, rank1):
        path = Path(root) / name
        fields = ["total_runtime_ms", "leader_changed"] + SUM.METRICS
        with path.open("w", newline="", encoding="utf-8") as fh:
            writer = csv.DictWriter(fh, fieldnames=fields)
            writer.writeheader()
            for i, runtime in enumerate(runtimes):
                row = {m: 0 for m in SUM.METRICS}
                row.update({
                    "total_runtime_ms": runtime,
                    "leader_changed": int(i > 0),
                    "busy_threads": busy[i],
                    "equiv_core_busy_pct": runtime / 2.5,
                    "rank1_share_of_runtime_pct": rank1[i],
                    "top2_share_of_runtime_pct": min(100, rank1[i] + 20),
                    "top4_share_of_runtime_pct": 100,
                    "captured_runtime_hhi": 0.4,
                    "top4_tid_churn_pct": i * 10,
                    "rank1_runtime_pct_wall": rank1[i] / 4,
                    "runq_wait_per_runtime": 0.1,
                    "rank1_slices_per_ms": 0.2,
                    "rank1_runq_wait_per_runtime": 0.1,
                })
                writer.writerow(row)
        return path

    def test_active_windows_are_separate_from_idle(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.feature_file(td, "scroll.csv", [0, 50, 100], [0, 3, 4], [0, 60, 40])
            report = SUM.analyse([f"scroll={path}"])
            w = report["workloads"][0]
            self.assertEqual(w["windows"], 3)
            self.assertEqual(w["active_windows"], 2)
            self.assertAlmostEqual(w["active_window_pct"], 200 / 3)
            self.assertEqual(
                w["active_windows_only"]["busy_threads"]["p50"], 3.5
            )

    def test_multiple_workloads_remain_separate(self):
        with tempfile.TemporaryDirectory() as td:
            a = self.feature_file(td, "a.csv", [10, 20], [2, 3], [80, 60])
            b = self.feature_file(td, "b.csv", [30, 40], [8, 9], [30, 20])
            report = SUM.analyse([f"launch={a}", f"scroll={b}"])
            labels = [w["label"] for w in report["workloads"]]
            self.assertEqual(labels, ["launch", "scroll"])
            self.assertFalse(report["detector_threshold_selected"])

    def test_duplicate_label_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = self.feature_file(td, "a.csv", [10], [2], [80])
            with self.assertRaisesRegex(ValueError, "duplicate workload label"):
                SUM.analyse([f"x={path}", f"x={path}"])

    def test_bad_input_syntax_rejected(self):
        with self.assertRaisesRegex(ValueError, "LABEL=PATH"):
            SUM.parse_input("scroll.csv")


if __name__ == "__main__":
    unittest.main()
