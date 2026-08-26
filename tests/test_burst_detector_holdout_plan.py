import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "holdout_plan",
    ROOT / "tools" / "make-burst-detector-holdout-plan.py",
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


WORKLOADS = [
    {
        "workload_id": "a",
        "role": "interaction_transition",
        "event_markers_required": "yes",
        "notes": "",
    },
    {
        "workload_id": "b",
        "role": "steady_negative",
        "event_markers_required": "no",
        "notes": "",
    },
]


class HoldoutPlanTests(unittest.TestCase):
    def test_even_repeats_required(self):
        with self.assertRaises(ValueError):
            MOD.generate(WORKLOADS, 3, 1)

    def test_plan_is_deterministic(self):
        self.assertEqual(
            MOD.generate(WORKLOADS, 4, 123),
            MOD.generate(WORKLOADS, 4, 123),
        )

    def test_each_workload_gets_both_states_per_repeat(self):
        rows = MOD.generate(WORKLOADS, 4, 123)
        for repeat in range(1, 5):
            for workload in ("a", "b"):
                states = [
                    row["module_state"]
                    for row in rows
                    if row["repeat"] == repeat and row["workload_id"] == workload
                ]
                self.assertEqual(set(states), {"module_on", "module_off"})
                self.assertEqual(len(states), 2)

    def test_state_order_balances_across_repeats(self):
        rows = MOD.generate(WORKLOADS, 4, 123)
        first_states = {}
        for row in rows:
            key = (row["repeat"], row["workload_id"])
            first_states.setdefault(key, row["module_state"])
        for workload in ("a", "b"):
            observed = [first_states[(repeat, workload)] for repeat in range(1, 5)]
            self.assertEqual(
                observed,
                ["module_off", "module_on", "module_off", "module_on"],
            )


if __name__ == "__main__":
    unittest.main()
