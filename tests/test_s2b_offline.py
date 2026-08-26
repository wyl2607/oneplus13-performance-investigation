#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_tool(filename, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


S2B = load_tool("analyze-s2b.py", "s2b")
FIT = load_tool("fit-prime-admission.py", "fit")
SIM = load_tool("simulate-burst-policy.py", "sim")


class S2bAnalysisTests(unittest.TestCase):
    def rows(self, separated=True, prime_effect=True):
        rows = []
        for block in (1, 2):
            for arm in ("A", "B"):
                run_id = f"b{block}{arm}"
                for i in range(40):
                    b = arm == "B"
                    eff = 512 if (b and separated) else 0
                    prime = b and prime_effect and i < (28 + block)
                    cpu = 7 if prime else 4
                    rows.append({
                        "run_id": run_id,
                        "block": block,
                        "arm": arm,
                        "cycle_id": str(i),
                        "requested_min": 512 if b else 0,
                        "effective_min": eff,
                        "pred_demand": 560 if b else 220,
                        "start_cpu": 6 if prime else 0,
                        "candidate_mask": 0x80 if prime else 0x10,
                        "misfit": 0,
                        "selected_cpu": cpu,
                        "first_run_cpu": cpu,
                        "wake_latency_us": 55 if prime else 32,
                        "initial_junction_c": 30 + 0.2 * block,
                        "peak_junction_c": 45 + block,
                    })
        return rows

    def test_detects_placement_effect(self):
        report = S2B.analyse(self.rows(), min_prime_delta_pp=10)
        self.assertEqual(report["mechanism_gate"]["verdict"], "PLACEMENT_EFFECT")

    def test_refuses_causal_result_when_effective_clamp_not_separated(self):
        report = S2B.analyse(self.rows(separated=False), min_prime_delta_pp=10)
        self.assertEqual(report["mechanism_gate"]["verdict"], "CLAMP_NOT_SEPARATED")


class PrimeAdmissionModelTests(unittest.TestCase):
    def setUp(self):
        self.points = [
            {"demand": 158, "share": 0.0, "weight": 176},
            {"demand": 215, "share": 0.7, "weight": 138},
            {"demand": 256, "share": 1.8, "weight": 114},
            {"demand": 401, "share": 7.8, "weight": 115},
            {"demand": 424, "share": 15.2, "weight": 99},
            {"demand": 499, "share": 43.3, "weight": 97},
            {"demand": 616, "share": 82.5, "weight": 103},
        ]

    def test_thresholds_follow_measured_crossover(self):
        model = FIT.fit(self.points)
        self.assertGreater(model["thresholds"]["demand_at_50pct"], 499)
        self.assertLess(model["thresholds"]["demand_at_50pct"], 616)
        self.assertGreater(model["thresholds"]["demand_at_80pct"], 499)
        self.assertLessEqual(model["thresholds"]["demand_at_80pct"], 616)

    def test_pava_enforces_monotonicity(self):
        noisy = [
            {"demand": 100, "share": 10, "weight": 10},
            {"demand": 200, "share": 8, "weight": 10},
            {"demand": 300, "share": 30, "weight": 10},
        ]
        fitted = FIT.pava(noisy)
        vals = [p["fitted_prime_share_pct"] for p in fitted]
        self.assertEqual(vals, sorted(vals))

    def test_model_refuses_extrapolation(self):
        model = FIT.fit(self.points)
        with self.assertRaisesRegex(ValueError, "outside measured model domain"):
            FIT.interpolate(model["points"], 640)

    def test_simulator_requires_explicit_unmeasured_assumption(self):
        model = FIT.fit(self.points)
        workload = [(200, 1), (400, 1)]
        with self.assertRaisesRegex(ValueError, "counterfactual refused"):
            SIM.simulate(model, workload, [512], assume=False)

    def test_simulated_prime_share_is_monotone_inside_domain(self):
        model = FIT.fit(self.points)
        workload = [(200, 1), (400, 2), (500, 1)]
        result = SIM.simulate(model, workload, [384, 512, 616], assume=True)
        ok = [x for x in result["arms"] if x["status"] == "OK"]
        shares = [x["predicted_prime_share_pct"] for x in ok]
        self.assertEqual(shares, sorted(shares))
        self.assertEqual(result["status"], "HYPOTHESIS_ONLY")

    def test_simulator_marks_640_out_of_domain(self):
        model = FIT.fit(self.points)
        workload = [(200, 1), (400, 1)]
        result = SIM.simulate(model, workload, [640], assume=True)
        self.assertEqual(result["arms"][0]["status"], "OUT_OF_MODEL_DOMAIN")
        self.assertIsNone(result["arms"][0]["predicted_prime_share_pct"])


if __name__ == "__main__":
    unittest.main()
