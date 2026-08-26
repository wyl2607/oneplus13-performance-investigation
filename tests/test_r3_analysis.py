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


SAMPLE_LOG = """#META run_id=R001 workload=cold_launch arm=512 mechanism=process
#META screen=mScreenState=ON
S|100.00|j=45000|s=30000|all_busy=1000|prime_busy=50|fg_threads=6|clamped_threads=6
S|100.25|j=46000|s=30500|all_busy=1200|prime_busy=300|fg_threads=7|clamped_threads=7
S|100.50|j=47000|s=31000|all_busy=1400|prime_busy=550|fg_threads=5|clamped_threads=5
EVENT|event_id=R001|phase=start|t_ms=1000000
EVENT|event_id=R001|phase=end|t_ms=1000450
#AM_START Starting: Intent { ... }
TotalTime: 450
#GFXINFO_BEGIN
Total frames rendered: 30
Janky frames: 1 (3.33%)
#GFXINFO_END
RESULT run_id=R001 workload=cold_launch arm=512 mechanism=process wall_cs=90 event_ms=450 status=OK out=/tmp/R001.log tis0_before=/tmp/R001.tis0.before tis0_after=/tmp/R001.tis0.after tis6_before=/tmp/R001.tis6.before tis6_after=/tmp/R001.tis6.after
"""


class R3AnalysisTests(unittest.TestCase):
    def test_parse_run_log_extracts_result_and_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "R001.log"
            path.write_text(SAMPLE_LOG)
            parsed = MOD.parse_run_log(path)
            self.assertIsNotNone(parsed)
            self.assertEqual(parsed["result"]["run_id"], "R001")
            self.assertEqual(parsed["result"]["status"], "OK")
            self.assertEqual(parsed["total_ticks"], 3)
            self.assertEqual(parsed["clamp_ticks"], 3)
            self.assertAlmostEqual(parsed["j_peak"], 47000.0)
            # prime_busy delta (550-50)/all_busy delta (1400-1000) = 500/400 = 125%
            self.assertAlmostEqual(parsed["prime_residency_pct"], 125.0)

    def test_parse_run_log_missing_file_returns_none(self):
        self.assertIsNone(MOD.parse_run_log("/nonexistent/path.log"))

    def test_never_echoes_meta_or_am_start_lines(self):
        # The analyzer must not surface raw #META/#AM_START text (real package
        # names live there) anywhere in the structured fields it returns.
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "R001.log"
            path.write_text(SAMPLE_LOG)
            parsed = MOD.parse_run_log(path)
            flat = str(parsed)
            self.assertNotIn("mScreenState", flat)
            self.assertNotIn("Intent", flat)

    def test_fnum_handles_na(self):
        self.assertIsNone(MOD.fnum("NA"))
        self.assertIsNone(MOD.fnum(""))
        self.assertEqual(MOD.fnum("450"), 450.0)

    def test_mean_sd_empty(self):
        mean, med, sd, n = MOD.mean_sd([])
        self.assertNotEqual(mean, mean)  # NaN
        self.assertEqual(n, 0)


if __name__ == "__main__":
    unittest.main()
