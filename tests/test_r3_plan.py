import csv
import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "r3_plan",
    ROOT / "tools" / "make-r3-run-plan.py",
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


WORKLOADS = [
    {
        "workload_id": "cold_launch",
        "role": "interaction_transition",
        "event_markers_required": "yes",
        "mechanisms": ["active-set", "process"],
        "app_slot": "APP_A",
        "notes": "",
    },
    {
        "workload_id": "steady_renderer",
        "role": "steady_negative",
        "event_markers_required": "no",
        "mechanisms": ["active-set"],
        "app_slot": "APP_C",
        "notes": "",
    },
]


class R3PlanTests(unittest.TestCase):
    def test_even_repeats_required(self):
        with self.assertRaises(ValueError):
            MOD.generate(WORKLOADS, 3, 1)

    def test_plan_is_deterministic(self):
        self.assertEqual(
            MOD.generate(WORKLOADS, 4, 123),
            MOD.generate(WORKLOADS, 4, 123),
        )

    def test_default_uses_only_primary_mechanism(self):
        rows = MOD.generate(WORKLOADS, 4, 123)
        mechanisms = {(r["workload_id"], r["mechanism"]) for r in rows}
        self.assertEqual(
            mechanisms,
            {("cold_launch", "active-set"), ("steady_renderer", "active-set")},
        )

    def test_all_mechanisms_flag_adds_secondary_units(self):
        rows = MOD.generate(WORKLOADS, 4, 123, all_mechanisms=True)
        mechanisms = {(r["workload_id"], r["mechanism"]) for r in rows}
        self.assertEqual(
            mechanisms,
            {
                ("cold_launch", "active-set"),
                ("cold_launch", "process"),
                ("steady_renderer", "active-set"),
            },
        )

    def test_each_unit_gets_both_arms_per_repeat(self):
        rows = MOD.generate(WORKLOADS, 4, 123)
        units = [("cold_launch", "active-set"), ("steady_renderer", "active-set")]
        for repeat in range(1, 5):
            for workload_id, mechanism in units:
                arms = [
                    row["arm"]
                    for row in rows
                    if row["repeat"] == repeat
                    and row["workload_id"] == workload_id
                    and row["mechanism"] == mechanism
                ]
                self.assertEqual(set(arms), {"control", "512"})
                self.assertEqual(len(arms), 2)

    def test_arm_order_balances_across_repeats(self):
        rows = MOD.generate(WORKLOADS, 4, 123)
        first_arm = {}
        for row in rows:
            key = (row["repeat"], row["workload_id"], row["mechanism"])
            first_arm.setdefault(key, row["arm"])
        observed = [
            first_arm[(repeat, "cold_launch", "active-set")] for repeat in range(1, 5)
        ]
        self.assertEqual(observed, ["control", "512", "control", "512"])

    def test_run_count_matches_units_times_repeats_times_two(self):
        rows = MOD.generate(WORKLOADS, 4, 123)
        # 2 units (cold_launch/active-set, steady_renderer/active-set)
        # x 4 repeats x 2 arms, primary mechanism only
        self.assertEqual(len(rows), 2 * 4 * 2)

    def test_unknown_mechanism_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "workloads.csv"
            with path.open("w", newline="") as fh:
                writer = csv.DictWriter(
                    fh,
                    fieldnames=[
                        "workload_id", "role", "event_markers_required",
                        "mechanisms", "default_app_slot", "notes",
                    ],
                )
                writer.writeheader()
                writer.writerow({
                    "workload_id": "x",
                    "role": "interaction_transition",
                    "event_markers_required": "yes",
                    "mechanisms": "thread-level",
                    "default_app_slot": "APP_A",
                    "notes": "",
                })
            with self.assertRaises(ValueError):
                MOD.read_workloads(str(path))


if __name__ == "__main__":
    unittest.main()
