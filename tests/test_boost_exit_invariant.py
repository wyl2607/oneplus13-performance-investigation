import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "r3_analysis",
    ROOT / "tools" / "analyze-r3-real-app.py",
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


OK_LOG = """#META run_id=R001 workload=cold_launch arm=512 mechanism=active-set
#META screen=mScreenState=ON
S|100.00|j=45000|s=30000|all_busy=1000|prime_busy=50|fg_threads=6|clamped_threads=6
RESULT run_id=R001 workload=cold_launch arm=512 mechanism=active-set wall_cs=90 event_ms=450 status=OK out=/tmp/R001.log tis0_before=/tmp/a tis0_after=/tmp/b tis6_before=/tmp/c tis6_after=/tmp/d
"""

CLEANUP_FAILED_LOG = """#META run_id=R002 workload=cold_launch arm=512 mechanism=active-set
#META screen=mScreenState=ON
S|100.00|j=45000|s=30000|all_busy=1000|prime_busy=50|fg_threads=6|clamped_threads=6
RESULT run_id=R002 workload=cold_launch arm=512 mechanism=active-set wall_cs=90 event_ms=NA status=CLEANUP_VERIFY_FAILED out=/tmp/R002.log tis0_before=/tmp/a tis0_after=/tmp/b tis6_before=/tmp/c tis6_after=/tmp/d
"""

PLAN = [
    {"run_id": "R001", "workload_id": "cold_launch", "arm": "512",
     "mechanism": "active-set", "app_slot": "APP_A"},
    {"run_id": "R002", "workload_id": "cold_launch", "arm": "512",
     "mechanism": "active-set", "app_slot": "APP_A"},
]


class BoostExitInvariantTests(unittest.TestCase):
    """Locks in the downstream half of the boost-exit safety invariant
    (docs/METHODOLOGY.md, "Safety invariant: boost exit must be verified"):
    a run where cleanup's residue check failed closed must never silently
    count as a normal result in the R3 summary tables, the same way any
    other non-OK status is already excluded."""

    def _write_logs(self, raw_dir):
        (pathlib.Path(raw_dir) / "R001.log").write_text(OK_LOG)
        (pathlib.Path(raw_dir) / "R002.log").write_text(CLEANUP_FAILED_LOG)

    def test_cleanup_verify_failed_excluded_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._write_logs(tmp)
            rows = MOD.build_rows(PLAN, tmp)
            self.assertEqual([r["run_id"] for r in rows], ["R001"])

    def test_cleanup_verify_failed_status_is_preserved_verbatim(self):
        # Confirms the status string itself round-trips unmodified, so a
        # human (or a future --include-non-ok run) can tell a boost-exit
        # safety failure apart from every other non-OK status.
        with tempfile.TemporaryDirectory() as tmp:
            self._write_logs(tmp)
            parsed = MOD.parse_run_log(pathlib.Path(tmp) / "R002.log")
            self.assertEqual(parsed["result"]["status"], "CLEANUP_VERIFY_FAILED")


if __name__ == "__main__":
    unittest.main()
