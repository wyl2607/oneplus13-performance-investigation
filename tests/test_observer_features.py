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


EX = load_tool("extract-observer-features.py", "observer_features")


TRACE = """\
META|version=2|duration_s=1|interval_ms=250|read_only=yes
FIELDS|THREAD|seq|rank|tgid|tid|uid|comm|runtime_ms|runtime_pct|runq_wait_ms|slices|cpu_start|cpu_end|allowed|uclamp_min|uclamp_max|uclamp_max_eff|migrations_total|vol_ctx_total|nonvol_ctx_total
WINDOW|seq=1|t_cs=100|wall_ms=250|threads=4|busy_threads=2|total_runtime_ms=100|total_runq_wait_ms=10
THREAD|1|1|10|101|10001|a|60|24|6|12|0|5|0-7|0|1024|1024|0|0|0
THREAD|1|2|10|102|10001|b|40|16|4|4|5|5|0-7|0|1024|1024|0|0|0
WINDOW|seq=2|t_cs=125|wall_ms=250|threads=4|busy_threads=2|total_runtime_ms=80|total_runq_wait_ms=8
THREAD|2|1|10|102|10001|b|50|20|5|10|5|6|0-7|0|1024|1024|0|0|0
THREAD|2|2|10|103|10001|c|30|12|3|3|6|6|0-7|0|1024|1024|0|0|0
"""


class ObserverFeatureTests(unittest.TestCase):
    def parsed(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "trace.txt"
            path.write_text(TRACE, encoding="utf-8")
            return EX.parse_trace(path)

    def test_extracts_runtime_concentration_and_leader_churn(self):
        meta, windows = self.parsed()
        rows = EX.extract_features(windows)
        self.assertEqual(meta["version"], "2")
        self.assertAlmostEqual(rows[0]["rank1_share_of_runtime_pct"], 60.0)
        self.assertAlmostEqual(rows[0]["top2_share_of_runtime_pct"], 100.0)
        self.assertEqual(rows[0]["leader_changed"], 0)
        self.assertEqual(rows[1]["leader_changed"], 1)
        self.assertGreater(rows[1]["top4_tid_churn_pct"], 0)

    def test_equivalent_core_busy_and_runq_ratio(self):
        _, windows = self.parsed()
        row = EX.extract_features(windows)[0]
        self.assertAlmostEqual(row["equiv_core_busy_pct"], 40.0)
        self.assertAlmostEqual(row["runq_wait_per_runtime"], 0.1)
        self.assertAlmostEqual(row["rank1_slices_per_ms"], 0.2)

    def test_prime_fields_only_describe_window_endpoints(self):
        _, windows = self.parsed()
        rows = EX.extract_features(windows)
        self.assertEqual(rows[0]["rank1_started_prime"], 0)
        self.assertEqual(rows[1]["rank1_ended_prime"], 1)

    def test_rejects_thread_window_seq_mismatch(self):
        bad = TRACE.replace("THREAD|2|1", "THREAD|9|1", 1)
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "bad.txt"
            path.write_text(bad, encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "does not match WINDOW"):
                EX.parse_trace(path)


if __name__ == "__main__":
    unittest.main()
