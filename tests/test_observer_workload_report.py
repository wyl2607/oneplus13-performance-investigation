#!/usr/bin/env python3
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


REPORT = load_tool("build-observer-workload-report.py", "observer_report")


TRACE = """\
META|version=2|duration_s=1|interval_ms=250|read_only=yes
FIELDS|THREAD|seq|rank|tgid|tid|uid|comm|runtime_ms|runtime_pct|runq_wait_ms|slices|cpu_start|cpu_end|allowed|uclamp_min|uclamp_max|uclamp_max_eff|migrations_total|vol_ctx_total|nonvol_ctx_total
WINDOW|seq=1|t_cs=100|wall_ms=250|threads=2|busy_threads=2|total_runtime_ms=100|total_runq_wait_ms=10
THREAD|1|1|10|101|10001|a|60|24|6|12|0|5|0-7|0|1024|1024|0|0|0
THREAD|1|2|10|102|10001|b|40|16|4|4|5|5|0-7|0|1024|1024|0|0|0
WINDOW|seq=2|t_cs=125|wall_ms=250|threads=2|busy_threads=1|total_runtime_ms=50|total_runq_wait_ms=5
THREAD|2|1|10|101|10001|a|50|20|5|10|5|6|0-7|0|1024|1024|0|0|0
THREAD|2|2|10|102|10001|b|0|0|0|0|5|5|0-7|0|1024|1024|0|0|0
"""


class WorkloadReportTests(unittest.TestCase):
    def write_trace(self, root, name):
        path = Path(root) / name
        path.write_text(TRACE, encoding="utf-8")
        return path

    def test_builds_named_descriptive_report(self):
        with tempfile.TemporaryDirectory() as td:
            a = self.write_trace(td, "scroll.txt")
            b = self.write_trace(td, "launch.txt")
            report = REPORT.build([f"scroll={a}", f"launch={b}"])
            self.assertEqual(report["status"], "DESCRIPTIVE_ONLY")
            self.assertFalse(report["detector_threshold_selected"])
            self.assertEqual(
                [w["label"] for w in report["workloads"]],
                ["scroll", "launch"],
            )
            self.assertEqual(report["sources"][0]["observer_version"], "2")
            self.assertEqual(report["sources"][0]["windows"], 2)

    def test_duplicate_label_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            a = self.write_trace(td, "scroll.txt")
            with self.assertRaisesRegex(ValueError, "duplicate workload label"):
                REPORT.build([f"scroll={a}", f"scroll={a}"])

    def test_bad_input_syntax_rejected(self):
        with self.assertRaisesRegex(ValueError, "LABEL=TRACE"):
            REPORT.parse_input("scroll.txt")


if __name__ == "__main__":
    unittest.main()
