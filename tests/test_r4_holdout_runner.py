import csv
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "r4_holdout_runner",
    ROOT / "tools" / "run-r4-holdout.py",
)
MOD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MOD  # dataclasses' ClassVar/InitVar check needs the
# module registered in sys.modules before exec, or it crashes looking up
# cls.__module__ for any dataclass defined here.
SPEC.loader.exec_module(MOD)


FIELDS = [
    "run_id", "repeat", "pair_index", "workload_id", "role",
    "event_markers_required", "module_state", "state_order",
    "frozen_candidates", "notes",
]


def write_plan(tmp, rows):
    plan_path = pathlib.Path(tmp) / "plan.csv"
    with plan_path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    data = plan_path.read_bytes()
    sha_path = pathlib.Path(tmp) / "plan.sha256"
    sha_path.write_text(MOD.sha256_bytes(data) + "  plan.csv\n", encoding="utf-8")
    return plan_path, sha_path


def make_row(run_id, workload_id="synthetic_compute", module_state="module_off", role="synthetic_control"):
    return {
        "run_id": run_id, "repeat": "1", "pair_index": "1", "workload_id": workload_id,
        "role": role, "event_markers_required": "no", "module_state": module_state,
        "state_order": "OFF_ON", "frozen_candidates": "C2_ROTATION_OR_LEADER;C4_INTERACTION_SHAPE",
        "notes": "",
    }


class PlanIntegrityTests(unittest.TestCase):
    def test_matching_sha256_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan_path, sha_path = write_plan(tmp, [make_row("H001")])
            rows = MOD.load_frozen_plan(plan_path, sha_path)
            self.assertEqual(len(rows), 1)

    def test_mismatched_sha256_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan_path, sha_path = write_plan(tmp, [make_row("H001")])
            sha_path.write_text("0" * 64 + "  plan.csv\n", encoding="utf-8")
            with self.assertRaises(MOD.PlanIntegrityError):
                MOD.load_frozen_plan(plan_path, sha_path)

    def test_real_frozen_plan_is_88_rows_and_matches_its_sha256(self):
        plan_path = ROOT / "experiments/burst-detector-holdout/r4-plan.csv"
        sha_path = ROOT / "experiments/burst-detector-holdout/r4-plan.sha256"
        rows = MOD.load_frozen_plan(plan_path, sha_path)
        self.assertEqual(len(rows), 88)
        workloads = {r["workload_id"] for r in rows}
        self.assertEqual(len(workloads), 11)
        for wl in workloads:
            states = [r["module_state"] for r in rows if r["workload_id"] == wl]
            self.assertEqual(len(states), 8)  # 2 states x 4 repeats
            self.assertEqual(states.count("module_on"), 4)
            self.assertEqual(states.count("module_off"), 4)


class BuildQueueTests(unittest.TestCase):
    def test_completed_rows_are_skipped(self):
        rows = [make_row("H001"), make_row("H002")]
        state = MOD.default_state()
        state["completed"]["H001"] = {"status": "OK"}
        queue = MOD.build_queue(rows, state)
        self.assertEqual([r for r, _ in queue], ["H002"])

    def test_invalid_row_without_replacement_gets_a_new_id(self):
        rows = [make_row("H001")]
        state = MOD.default_state()
        state["invalid"]["H001"] = {"status": "RUN_ABORT_THERMAL_92", "replaced_by": None}
        queue = MOD.build_queue(rows, state)
        self.assertEqual(len(queue), 1)
        new_id, row = queue[0]
        self.assertEqual(new_id, "H001-R1")
        self.assertEqual(row["run_id"], "H001")  # original plan row content unchanged

    def test_invalid_row_with_completed_replacement_is_fully_skipped(self):
        rows = [make_row("H001")]
        state = MOD.default_state()
        state["invalid"]["H001"] = {"status": "RUN_ABORT_THERMAL_92", "replaced_by": "H001-R1"}
        state["completed"]["H001-R1"] = {"status": "OK"}
        queue = MOD.build_queue(rows, state)
        self.assertEqual(queue, [])

    def test_frozen_run_id_is_never_reused_for_a_second_replacement(self):
        state = MOD.default_state()
        state["invalid"]["H001"] = {"status": "x", "replaced_by": None}
        state["invalid"]["H001-R1"] = {"status": "x", "replaced_by": None}
        new_id = MOD.next_replacement_id("H001", state)
        self.assertEqual(new_id, "H001-R2")


class RunOneTests(unittest.TestCase):
    def _cfg(self, tmp, **overrides):
        kwargs = dict(
            raw_dir=pathlib.Path(tmp),
            app_manifest={"APP_A": {"package": "com.example.a", "launch_activity": ""}},
            confirm_fn=lambda prompt="": "",
            sleep_fn=lambda s: None,
        )
        kwargs.update(overrides)
        return MOD.RunnerConfig(**kwargs)

    def test_ok_run_marks_completed(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice()
            state = MOD.default_state()
            row = make_row("H001")
            MOD.run_one("H001", row, device, self._cfg(tmp), state)
            self.assertIn("H001", state["completed"])
            self.assertEqual(state["last_completed_run"], "H001")
            self.assertEqual(state["completed"]["H001"]["status"], "OK")

    def test_cleanup_verify_failed_stops_session_not_a_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice(script={
                "H001": MOD.RunResult(status="CLEANUP_VERIFY_FAILED", exit_code=12,
                                       raw_text="RESULT run_id=H001 status=CLEANUP_VERIFY_FAILED\n"),
            })
            state = MOD.default_state()
            row = make_row("H001")
            with self.assertRaises(MOD.SessionStop) as ctx:
                MOD.run_one("H001", row, device, self._cfg(tmp), state)
            self.assertEqual(ctx.exception.reason, "CLEANUP_VERIFY_FAILED")
            # kept, not deleted, and not silently counted as a normal result
            self.assertIn("H001", state["invalid"])
            self.assertNotIn("H001", state["completed"])

    def test_module_set_failed_stops_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice(script={
                "H001": MOD.RunResult(status="MODULE_SET_FAILED", exit_code=11, raw_text="x"),
            })
            state = MOD.default_state()
            with self.assertRaises(MOD.SessionStop) as ctx:
                MOD.run_one("H001", make_row("H001"), device, self._cfg(tmp), state)
            self.assertEqual(ctx.exception.reason, "MODULE_SET_FAILED")

    def test_run_abort_thermal_92_is_this_run_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice(script={
                "H001": MOD.RunResult(status="RUN_ABORT_THERMAL_92", exit_code=9, raw_text="x"),
            })
            state = MOD.default_state()
            MOD.run_one("H001", make_row("H001"), device, self._cfg(tmp), state)
            self.assertIn("H001", state["invalid"])
            self.assertNotIn("H001", state["completed"])

    def test_session_stop_thermal_95_keeps_the_hot_run_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice(script={
                "H001": MOD.RunResult(status="SESSION_STOP_THERMAL_95", exit_code=10, raw_text="hot run data"),
            })
            state = MOD.default_state()
            with self.assertRaises(MOD.SessionStop):
                MOD.run_one("H001", make_row("H001"), device, self._cfg(tmp), state)
            out_path = pathlib.Path(tmp) / "H001.log"
            self.assertTrue(out_path.exists())
            self.assertEqual(out_path.read_text(encoding="utf-8"), "hot run data")

    def test_thermal_hard_gate_at_preflight_stops_before_running(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice(thermal=(96000, 30000))
            state = MOD.default_state()
            with self.assertRaises(MOD.SessionStop) as ctx:
                MOD.run_one("H001", make_row("H001"), device, self._cfg(tmp), state)
            self.assertEqual(ctx.exception.reason, "THERMAL_HARD_AT_PREFLIGHT")
            self.assertEqual(device.calls, [])  # never actually ran the workload

    def test_thermal_soft_gate_cools_down_then_proceeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            temps = iter([92500, 91000, 60000])
            device = MOD.FakeDevice()
            device.thermal_milli_c = lambda: (next(temps), 30000)
            slept = []
            state = MOD.default_state()
            cfg = self._cfg(tmp, sleep_fn=lambda s: slept.append(s), cooldown_poll_s=10)
            MOD.run_one("H001", make_row("H001"), device, cfg, state)
            self.assertIn("H001", state["completed"])
            self.assertTrue(slept)

    def test_thermal_soft_gate_exceeding_max_wait_marks_invalid_not_session_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice(thermal=(93000, 30000))
            state = MOD.default_state()
            cfg = self._cfg(tmp, cooldown_poll_s=100, cooldown_max_wait_s=150)
            MOD.run_one("H001", make_row("H001"), device, cfg, state)  # must not raise
            self.assertEqual(state["invalid"]["H001"]["status"], "THERMAL_ABOVE_SOFT_GATE_AT_START")

    def test_human_assisted_workload_pauses_for_confirmation(self):
        with tempfile.TemporaryDirectory() as tmp:
            prompts = []
            device = MOD.FakeDevice()
            state = MOD.default_state()
            cfg = self._cfg(tmp, confirm_fn=lambda prompt="": (prompts.append(prompt), "")[1])
            row = make_row("H001", workload_id="steady_gameplay", role="steady_negative")
            MOD.run_one("H001", row, device, cfg, state)
            self.assertTrue(any("PREPARE_WORKLOAD steady_gameplay" in p for p in prompts))
            self.assertIn("H001", state["completed"])

    def test_human_assisted_skip_marks_invalid_and_continues(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice()
            state = MOD.default_state()
            cfg = self._cfg(tmp, confirm_fn=lambda prompt="": "skip")
            row = make_row("H001", workload_id="video_playback", role="steady_negative")
            MOD.run_one("H001", row, device, cfg, state)
            self.assertEqual(state["invalid"]["H001"]["status"], "OPERATOR_SKIPPED")
            self.assertEqual(device.calls, [])

    def test_human_assisted_abort_stops_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice()
            state = MOD.default_state()
            cfg = self._cfg(tmp, confirm_fn=lambda prompt="": "abort")
            row = make_row("H001", workload_id="background_download", role="background_negative")
            with self.assertRaises(MOD.SessionStop) as ctx:
                MOD.run_one("H001", row, device, cfg, state)
            self.assertEqual(ctx.exception.reason, "OPERATOR_ABORT")

    def test_screen_off_blocks_until_confirmed_on(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice(screen_on=False)
            calls = {"n": 0}

            def confirm(prompt=""):
                calls["n"] += 1
                if calls["n"] >= 2:
                    device._screen_on = True
                return ""
            state = MOD.default_state()
            cfg = self._cfg(tmp, confirm_fn=confirm)
            MOD.run_one("H001", make_row("H001"), device, cfg, state)
            self.assertGreaterEqual(calls["n"], 2)
            self.assertIn("H001", state["completed"])

    def test_missing_app_manifest_entry_raises_for_automatable_workload(self):
        with tempfile.TemporaryDirectory() as tmp:
            device = MOD.FakeDevice()
            state = MOD.default_state()
            cfg = self._cfg(tmp, app_manifest={})
            row = make_row("H001", workload_id="app_launch_cold", role="interaction_transition")
            with self.assertRaises(MOD.PlanIntegrityError):
                MOD.run_one("H001", row, device, cfg, state)

    def test_existing_output_file_is_archived_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            stale_path = pathlib.Path(tmp) / "H001.log"
            stale_path.write_text("leftover from an interrupted attempt", encoding="utf-8")
            device = MOD.FakeDevice()
            state = MOD.default_state()
            MOD.run_one("H001", make_row("H001"), device, self._cfg(tmp), state)
            leftovers = list(pathlib.Path(tmp).glob("H001.log.stale-*"))
            self.assertEqual(len(leftovers), 1)
            self.assertEqual(leftovers[0].read_text(encoding="utf-8"), "leftover from an interrupted attempt")


class RunSessionCheckpointResumeTests(unittest.TestCase):
    def test_full_pass_completes_every_row_and_checkpoints(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan_path, sha_path = write_plan(tmp, [make_row("H001"), make_row("H002")])
            state_path = pathlib.Path(tmp) / "session-state.json"
            device = MOD.FakeDevice()
            cfg = MOD.RunnerConfig(raw_dir=pathlib.Path(tmp), confirm_fn=lambda p="": "", sleep_fn=lambda s: None)
            state = MOD.run_session(plan_path, sha_path, state_path, device, cfg)
            self.assertEqual(set(state["completed"]), {"H001", "H002"})
            saved = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(set(saved["completed"]), {"H001", "H002"})

    def test_interrupt_and_resume_continues_from_run_11_equivalent(self):
        with tempfile.TemporaryDirectory() as tmp:
            rows = [make_row(f"H{i:03d}") for i in range(1, 21)]
            plan_path, sha_path = write_plan(tmp, rows)
            state_path = pathlib.Path(tmp) / "session-state.json"
            device = MOD.FakeDevice()
            cfg = MOD.RunnerConfig(raw_dir=pathlib.Path(tmp), confirm_fn=lambda p="": "",
                                    sleep_fn=lambda s: None, max_runs=10)
            state = MOD.run_session(plan_path, sha_path, state_path, device, cfg)
            self.assertEqual(len(state["completed"]), 10)
            self.assertEqual(state["last_completed_run"], "H010")

            # Simulate interruption: a fresh device object, resume from state on disk.
            device2 = MOD.FakeDevice()
            cfg2 = MOD.RunnerConfig(raw_dir=pathlib.Path(tmp), confirm_fn=lambda p="": "", sleep_fn=lambda s: None)
            state2 = MOD.run_session(plan_path, sha_path, state_path, device2, cfg2)
            self.assertEqual(len(state2["completed"]), 20)
            self.assertEqual(sorted(device2.calls), [f"H{i:03d}" for i in range(11, 21)])
            # never re-ran or overwrote the first 10
            self.assertEqual(set(device2.calls) & {f"H{i:03d}" for i in range(1, 11)}, set())

    def test_cleanup_verify_failed_requires_acknowledge_stop_to_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            rows = [make_row("H001"), make_row("H002")]
            plan_path, sha_path = write_plan(tmp, rows)
            state_path = pathlib.Path(tmp) / "session-state.json"
            device = MOD.FakeDevice(script={
                "H001": MOD.RunResult(status="CLEANUP_VERIFY_FAILED", exit_code=12, raw_text="x"),
            })
            cfg = MOD.RunnerConfig(raw_dir=pathlib.Path(tmp), confirm_fn=lambda p="": "", sleep_fn=lambda s: None)
            with self.assertRaises(MOD.SessionStop):
                MOD.run_session(plan_path, sha_path, state_path, device, cfg)

            # Without acknowledging, resuming must refuse outright -- not
            # retry, not skip ahead, not silently continue.
            device2 = MOD.FakeDevice()
            with self.assertRaises(MOD.SessionAlreadyStopped):
                MOD.run_session(plan_path, sha_path, state_path, device2, cfg)
            self.assertEqual(device2.calls, [])

            # Acknowledging clears the stop and resumes with a replacement id
            # for the failed run, never reusing H001 itself.
            device3 = MOD.FakeDevice()
            state3 = MOD.run_session(plan_path, sha_path, state_path, device3, cfg, acknowledge_stop=True)
            self.assertIn("H001-R1", state3["completed"])
            self.assertIn("H002", state3["completed"])
            self.assertEqual(len(state3["stop_history"]), 1)

    def test_device_mismatch_is_rejected_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan_path, sha_path = write_plan(tmp, [make_row("H001")])
            state_path = pathlib.Path(tmp) / "session-state.json"
            cfg = MOD.RunnerConfig(raw_dir=pathlib.Path(tmp), confirm_fn=lambda p="": "", sleep_fn=lambda s: None)
            MOD.run_session(plan_path, sha_path, state_path, MOD.FakeDevice(fingerprint="A"), cfg)
            with self.assertRaises(MOD.DeviceMismatch):
                MOD.run_session(plan_path, sha_path, state_path, MOD.FakeDevice(fingerprint="B"), cfg)

    def test_reshuffled_plan_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            rows = [make_row("H001"), make_row("H002")]
            plan_path, sha_path = write_plan(tmp, rows)
            state_path = pathlib.Path(tmp) / "session-state.json"
            cfg = MOD.RunnerConfig(raw_dir=pathlib.Path(tmp), confirm_fn=lambda p="": "", sleep_fn=lambda s: None)
            MOD.run_session(plan_path, sha_path, state_path, MOD.FakeDevice(), cfg,)

            # Someone regenerates the plan (e.g. reshuffles) without updating
            # the sha256 file's referenced session -- simulate by editing the
            # plan file in place after a session already started against it.
            with plan_path.open("a", encoding="utf-8") as fh:
                fh.write("H099,1,1,synthetic_wake,synthetic_control,no,module_on,OFF_ON,x,\n")
            # sha256 file still matches the NEW content only if regenerated;
            # here it does not, so load_frozen_plan itself already refuses --
            # but even if it didn't, run_session must catch a plan_sha256
            # drift against what the session recorded at creation time.
            with self.assertRaises(MOD.PlanIntegrityError):
                MOD.run_session(plan_path, sha_path, state_path, MOD.FakeDevice(), cfg)


class TestAdbDeviceHostChecks(unittest.TestCase):
    """Regression coverage for the bug the R4 smoke phase found live: a
    multi-word inline script (`for z in ...; do ... done`) passed as a
    `su -c <script>` argv element came back "syntax error: unexpected 'do'"
    from the device, and thermal_milli_c() silently turned that failure into
    (None, None) -- which the caller treats as "no reading, skip the check",
    defeating the host-side thermal preflight with no error surfaced. The
    fix routes both host checks through a pushed script file (the same
    `sh <path>` pattern device.run() already uses), which this locks in by
    asserting the command line is exactly `sh <DEVICE_DIR>/<script>`, never
    an inline multi-word script."""

    def _adb_device(self):
        return MOD.AdbDevice(serial="TESTSERIAL")

    def test_thermal_milli_c_runs_pushed_script_not_inline(self):
        device = self._adb_device()
        completed = mock.Mock(stdout="J:45200\nS:31100\n", stderr="", returncode=0)
        with mock.patch("subprocess.run", return_value=completed) as run:
            j, s = device.thermal_milli_c()
        self.assertEqual((j, s), (45200, 31100))
        args = run.call_args[0][0]
        self.assertEqual(args[-3:], ["su", "-c", f"sh {device.DEVICE_DIR}/host-thermal-check.sh"])

    def test_screen_on_runs_pushed_script_not_inline(self):
        device = self._adb_device()
        completed = mock.Mock(stdout="  mScreenState=ON\n", stderr="", returncode=0)
        with mock.patch("subprocess.run", return_value=completed) as run:
            self.assertTrue(device.screen_on())
        args = run.call_args[0][0]
        self.assertEqual(args[-3:], ["su", "-c", f"sh {device.DEVICE_DIR}/host-screen-check.sh"])

    def test_thermal_milli_c_missing_zone_is_none_not_a_parse_crash(self):
        device = self._adb_device()
        completed = mock.Mock(stdout="", stderr="syntax error\n", returncode=1)
        with mock.patch("subprocess.run", return_value=completed):
            self.assertEqual(device.thermal_milli_c(), (None, None))

    def test_push_scripts_pushes_both_host_check_scripts(self):
        device = self._adb_device()
        with mock.patch("subprocess.run", return_value=mock.Mock(stdout="", stderr="", returncode=0)) as run:
            device.push_scripts()
        pushed = {
            pathlib.Path(c.args[0][-1]).name
            for c in run.call_args_list
            if "push" in c.args[0]
        }
        self.assertIn("host-thermal-check.sh", pushed)
        self.assertIn("host-screen-check.sh", pushed)


if __name__ == "__main__":
    unittest.main()
