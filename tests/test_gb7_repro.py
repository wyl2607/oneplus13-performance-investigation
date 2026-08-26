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


PLAN = load_tool("make-gb7-repro-plan.py", "plan")
AN = load_tool("analyze-gb7-repro.py", "analysis")


class PlanTests(unittest.TestCase):
    def test_alternating_blocks(self):
        rows = PLAN.build_plan(3, "control", "candidate")
        self.assertEqual("".join(r["arm"] for r in rows[:4]), "ABBA")
        self.assertEqual("".join(r["arm"] for r in rows[4:8]), "BAAB")
        self.assertEqual("".join(r["arm"] for r in rows[8:12]), "ABBA")
        self.assertEqual([r["order"] for r in rows], list(range(1, 13)))


class AnalysisTests(unittest.TestCase):
    def make_rows(self, a_single, b_single, a_multi=None, b_multi=None):
        a_multi = a_multi or [8000 + i for i in range(len(a_single))]
        b_multi = b_multi or [8400 + i for i in range(len(b_single))]
        pattern = "ABBABAAB"
        ia = ib = 0
        rows = []
        for order, arm in enumerate(pattern, start=1):
            if arm == "A":
                s, m = a_single[ia], a_multi[ia]
                ia += 1
            else:
                s, m = b_single[ib], b_multi[ib]
                ib += 1
            rows.append({
                "run_id": f"r{order}", "block": 1 if order <= 4 else 2,
                "order": order, "arm": arm, "single_score": float(s),
                "multi_score": float(m), "initial_junction_c": 30.0,
                "peak_junction_c": None, "prime_residency_pct": None,
                "walt_demand_p50": None, "wake_p50_us": None,
            })
        return rows

    def test_clear_improvement_passes(self):
        rows = self.make_rows(
            [2000, 2010, 1990, 2005],
            [2200, 2210, 2190, 2205],
            [8000, 8010, 7990, 8005],
            [8500, 8510, 8490, 8505],
        )
        report = AN.analyse(rows, min_effect_pct=3.0)
        self.assertEqual(report["metrics"]["single_score"]["verdict"], "PASS")
        self.assertEqual(report["metrics"]["multi_score"]["verdict"], "PASS")

    def test_small_effect_stays_inconclusive(self):
        rows = self.make_rows(
            [2000, 2050, 1980, 2030],
            [2040, 2010, 2060, 1990],
        )
        report = AN.analyse(rows, min_effect_pct=3.0)
        self.assertEqual(report["metrics"]["single_score"]["verdict"], "INCONCLUSIVE")

    def test_regression(self):
        rows = self.make_rows(
            [2200, 2210, 2190, 2205],
            [2000, 2010, 1990, 2005],
        )
        report = AN.analyse(rows, min_effect_pct=3.0)
        self.assertEqual(report["metrics"]["single_score"]["verdict"], "REGRESSION")

    def test_one_block_never_produces_verdict(self):
        rows = self.make_rows([2000, 2010, 1990, 2005], [2400, 2410, 2390, 2405])[:4]
        report = AN.analyse(rows, min_effect_pct=3.0)
        self.assertEqual(report["metrics"]["single_score"]["verdict"], "INCONCLUSIVE")

    def test_csv_validation_rejects_duplicate_run_id(self):
        fields = ["run_id", "block", "order", "arm", "single_score", "multi_score"]
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "x.csv"
            with path.open("w", newline="", encoding="utf-8") as fh:
                w = csv.DictWriter(fh, fieldnames=fields)
                w.writeheader()
                w.writerow(dict(run_id="x", block=1, order=1, arm="A", single_score=1, multi_score=1))
                w.writerow(dict(run_id="x", block=1, order=2, arm="B", single_score=2, multi_score=2))
            with self.assertRaisesRegex(ValueError, "duplicate run_id"):
                AN.load_rows(path)


if __name__ == "__main__":
    unittest.main()
