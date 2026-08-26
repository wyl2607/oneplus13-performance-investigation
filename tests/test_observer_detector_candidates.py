import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "observer_candidates",
    ROOT / "tools" / "evaluate-observer-detector-candidates.py",
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


def row(**overrides):
    base = {
        "total_runtime_ms": 10.0,
        "busy_threads": 5,
        "equiv_core_busy_pct": 10.0,
        "rank1_share_of_runtime_pct": 55.0,
        "top4_share_of_runtime_pct": 95.0,
        "top4_tid_churn_pct": 75.0,
        "runq_wait_per_runtime": 0.05,
        "leader_changed": 1,
    }
    base.update(overrides)
    return base


class DetectorCandidateTests(unittest.TestCase):
    def test_single_thread_synthetic_is_rejected(self):
        synthetic = row(
            busy_threads=1,
            equiv_core_busy_pct=40.0,
            rank1_share_of_runtime_pct=100.0,
            top4_share_of_runtime_pct=100.0,
            top4_tid_churn_pct=0.0,
            runq_wait_per_runtime=0.004,
            leader_changed=0,
        )
        self.assertFalse(MOD.c2_rotation_or_leader(synthetic))
        self.assertFalse(MOD.c4_interaction_shape(synthetic))

    def test_rotating_multithread_interaction_matches_both_families(self):
        interaction = row()
        self.assertTrue(MOD.c2_rotation_or_leader(interaction))
        self.assertTrue(MOD.c4_interaction_shape(interaction))

    def test_steady_multithread_renderer_exposes_shape_only_risk(self):
        steady = row(
            busy_threads=21,
            equiv_core_busy_pct=60.0,
            rank1_share_of_runtime_pct=23.0,
            top4_share_of_runtime_pct=75.0,
            top4_tid_churn_pct=0.0,
            runq_wait_per_runtime=0.01,
            leader_changed=0,
        )
        self.assertFalse(MOD.c2_rotation_or_leader(steady))
        self.assertTrue(MOD.c4_interaction_shape(steady))

    def test_high_sustained_compute_rejected_by_temporal_candidate(self):
        sustained = row(
            busy_threads=8,
            equiv_core_busy_pct=650.0,
            rank1_share_of_runtime_pct=20.0,
            top4_share_of_runtime_pct=70.0,
            top4_tid_churn_pct=80.0,
            leader_changed=1,
        )
        self.assertFalse(MOD.c2_rotation_or_leader(sustained))
        self.assertFalse(MOD.c4_interaction_shape(sustained))


if __name__ == "__main__":
    unittest.main()
