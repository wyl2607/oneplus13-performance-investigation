import importlib.util
import pathlib
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "r4_holdout_analysis",
    ROOT / "tools" / "analyze-r4-holdout.py",
)
MOD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MOD
SPEC.loader.exec_module(MOD)


THREAD_FIELDS = (
    "seq|rank|tgid|tid|uid|comm|runtime_ms|runtime_pct|runq_wait_ms|slices|"
    "cpu_start|cpu_end|allowed|uclamp_min|uclamp_max|uclamp_max_eff|"
    "migrations_total|vol_ctx_total|nonvol_ctx_total"
)


def thread_line(seq, rank, tgid, tid, runtime_ms):
    return (
        f"THREAD|{seq}|{rank}|{tgid}|{tid}|10123|worker|{runtime_ms}.0|10.0|"
        f"0.0|5|6|7|0-7|0|1024|1024|0|0|0"
    )


def build_active_trace():
    """Two windows: window 1 (t_cs=1000, t_ms=10000) fires C4 only (leader
    share 40%, top4 share 100%, no churn/leader-change yet since it's the
    first window); window 2 (t_cs=1100, t_ms=11000) fires C2 only (entirely
    different tids -> 100% churn and a leader change, but leader share 93%
    is outside C4's 20-85 band)."""
    lines = [
        "META|version=2|duration_s=30|interval_ms=250|top_n=5|kernel=NA|read_only=yes",
        f"FIELDS|THREAD|{THREAD_FIELDS}",
        "WINDOW|seq=1|t_cs=1000|wall_ms=250|threads=4|busy_threads=4|total_runtime_ms=100.0|total_runq_wait_ms=5.0|tgids=1234",
        thread_line(1, 1, 1234, 101, 40),
        thread_line(1, 2, 1234, 102, 30),
        thread_line(1, 3, 1234, 103, 20),
        thread_line(1, 4, 1234, 104, 10),
        "WINDOW|seq=2|t_cs=1100|wall_ms=250|threads=4|busy_threads=4|total_runtime_ms=150.0|total_runq_wait_ms=5.0|tgids=1234",
        thread_line(2, 1, 1234, 201, 140),
        thread_line(2, 2, 1234, 202, 5),
        thread_line(2, 3, 1234, 203, 3),
        thread_line(2, 4, 1234, 204, 2),
        "END|windows=2|elapsed_s=1",
    ]
    return "\n".join(lines) + "\n"


def build_quiet_trace():
    """A single low-thread window that should not fire either candidate
    (busy_threads=1 fails the busy_threads>=3 precondition of both)."""
    lines = [
        "META|version=2|duration_s=30|interval_ms=250|top_n=5|kernel=NA|read_only=yes",
        f"FIELDS|THREAD|{THREAD_FIELDS}",
        "WINDOW|seq=1|t_cs=1000|wall_ms=250|threads=1|busy_threads=1|total_runtime_ms=50.0|total_runq_wait_ms=0.0|tgids=1234",
        thread_line(1, 1, 1234, 101, 50),
        "END|windows=1|elapsed_s=1",
    ]
    return "\n".join(lines) + "\n"


def build_manifest(run_id, workload, module_state, events=True):
    lines = [f"#META run_id={run_id} workload={workload} module_state={module_state}"]
    if events:
        lines += [
            f"EVENT|event_id={run_id}|phase=start|t_ms=9500",
            f"EVENT|event_id={run_id}|phase=end|t_ms=10500",
        ]
    lines.append(f"RESULT run_id={run_id} workload={workload} module_state={module_state} status=OK")
    return "\n".join(lines) + "\n"


class AnalyzeRunTests(unittest.TestCase):
    def test_c4_fires_in_event_window_c2_fires_outside_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = pathlib.Path(tmp) / "H001.log"
            observer_path = pathlib.Path(tmp) / "H001.observer.log"
            manifest_path.write_text(build_manifest("H001", "app_switch", "module_on"), encoding="utf-8")
            observer_path.write_text(build_active_trace(), encoding="utf-8")

            result = MOD.analyze_run(manifest_path, observer_path)
            self.assertTrue(result["has_events"])
            w1, w2 = result["windows"]
            self.assertEqual(w1["t_ms"], 10000)
            self.assertTrue(w1["in_event"])
            self.assertTrue(w1["C4_INTERACTION_SHAPE"])
            self.assertFalse(w1["C2_ROTATION_OR_LEADER"])

            self.assertEqual(w2["t_ms"], 11000)
            self.assertFalse(w2["in_event"])
            self.assertTrue(w2["C2_ROTATION_OR_LEADER"])
            self.assertFalse(w2["C4_INTERACTION_SHAPE"])

    def test_quiet_workload_never_activates_either_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = pathlib.Path(tmp) / "H002.log"
            observer_path = pathlib.Path(tmp) / "H002.observer.log"
            manifest_path.write_text(build_manifest("H002", "synthetic_compute", "module_off", events=False), encoding="utf-8")
            observer_path.write_text(build_quiet_trace(), encoding="utf-8")

            result = MOD.analyze_run(manifest_path, observer_path)
            self.assertFalse(result["has_events"])
            self.assertEqual(len(result["windows"]), 1)
            w = result["windows"][0]
            self.assertIsNone(w["in_event"])
            self.assertFalse(w["C2_ROTATION_OR_LEADER"])
            self.assertFalse(w["C4_INTERACTION_SHAPE"])


class UtilityLabelTests(unittest.TestCase):
    def test_known_prior_carries_shape_similarity_caveat(self):
        label = MOD.utility_label("browser_scroll")
        self.assertEqual(label["label"], "BENEFIT_POSITIVE")
        self.assertEqual(label["basis"], "SHAPE_SIMILARITY_ONLY")

    def test_exact_match_workload_is_flagged_as_such(self):
        label = MOD.utility_label("app_switch")
        self.assertEqual(label["basis"], "EXACT_MATCH")

    def test_unmeasured_workload_defaults_unknown(self):
        for wl in ("camera_launch", "steady_gameplay", "video_playback",
                   "background_download", "synthetic_compute", "synthetic_wake"):
            label = MOD.utility_label(wl)
            self.assertEqual(label["label"], "UNKNOWN", wl)
            self.assertEqual(label["basis"], "NOT_MEASURED", wl)


class BuildReportTests(unittest.TestCase):
    def test_frozen_synthetic_fixture_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw_dir = pathlib.Path(tmp)
            on_manifest = raw_dir / "H001.log"
            on_observer = raw_dir / "H001.observer.log"
            on_manifest.write_text(build_manifest("H001", "app_switch", "module_on"), encoding="utf-8")
            on_observer.write_text(build_active_trace(), encoding="utf-8")

            off_manifest = raw_dir / "H002.log"
            off_observer = raw_dir / "H002.observer.log"
            off_manifest.write_text(build_manifest("H002", "app_switch", "module_off", events=False), encoding="utf-8")
            off_observer.write_text(build_quiet_trace(), encoding="utf-8")

            excluded_manifest = raw_dir / "H003.log"
            excluded_observer = raw_dir / "H003.observer.log"
            excluded_manifest.write_text(build_manifest("H003", "app_switch", "module_on"), encoding="utf-8")
            excluded_observer.write_text(build_active_trace(), encoding="utf-8")

            session_state = {
                "completed": {
                    "H001": {"status": "OK", "out": str(on_manifest), "observer_out": str(on_observer),
                              "module_state": "module_on", "workload_id": "app_switch", "role": "interaction_transition"},
                    "H002": {"status": "OK", "out": str(off_manifest), "observer_out": str(off_observer),
                              "module_state": "module_off", "workload_id": "app_switch", "role": "interaction_transition"},
                    "H003": {"status": "CLEANUP_VERIFY_FAILED", "out": str(excluded_manifest),
                              "observer_out": str(excluded_observer), "module_state": "module_on",
                              "workload_id": "app_switch", "role": "interaction_transition"},
                }
            }

            report = MOD.build_report(session_state, raw_dir)

            self.assertEqual(report["frozen_candidates"], ["C2_ROTATION_OR_LEADER", "C4_INTERACTION_SHAPE"])
            self.assertEqual(len(report["legacy_detector_analysis"]), 1)
            entry = report["legacy_detector_analysis"][0]
            self.assertEqual(entry["workload_id"], "app_switch")

            # H003 was CLEANUP_VERIFY_FAILED and must not silently double the
            # module_on window count contributed by H001.
            self.assertEqual(entry["module_on"]["C4_INTERACTION_SHAPE_active_windows"], 2)

            # module_on has one C2 hit (window 2) and one C4 hit (window 1)
            # out of 2 active windows each; module_off has zero of one.
            self.assertAlmostEqual(entry["module_on"]["C2_ROTATION_OR_LEADER_activation_pct"], 50.0)
            self.assertAlmostEqual(entry["module_on"]["C4_INTERACTION_SHAPE_activation_pct"], 50.0)
            self.assertEqual(entry["module_off"]["C2_ROTATION_OR_LEADER_activation_pct"], 0.0)

            self.assertAlmostEqual(entry["C2_ROTATION_OR_LEADER_module_state_delta_pp"], 50.0)

            util_row = report["utility_matrix"][0]
            self.assertEqual(util_row["utility_label"], "BENEFIT_NEGATIVE")
            self.assertEqual(util_row["utility_basis"], "EXACT_MATCH")

            self.assertIsNone(report["final_verdict_template"]["verdict"])
            self.assertIn("C2_SURVIVES", report["allowed_verdicts"])
            self.assertEqual(report["parse_errors"], [])

    def test_unparseable_trace_is_excluded_and_reported_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw_dir = pathlib.Path(tmp)
            manifest = raw_dir / "H001.log"
            observer = raw_dir / "H001.observer.log"
            manifest.write_text(build_manifest("H001", "app_switch", "module_on"), encoding="utf-8")
            observer.write_text("META|version=2\n", encoding="utf-8")  # no WINDOW records

            session_state = {
                "completed": {
                    "H001": {"status": "OK", "out": str(manifest), "observer_out": str(observer),
                              "module_state": "module_on", "workload_id": "app_switch",
                              "role": "interaction_transition"},
                },
            }
            report = MOD.build_report(session_state, raw_dir)
            self.assertEqual(report["legacy_detector_analysis"], [])
            self.assertEqual(len(report["parse_errors"]), 1)
            self.assertEqual(report["parse_errors"][0]["run_id"], "H001")


if __name__ == "__main__":
    unittest.main()
