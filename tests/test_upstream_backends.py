import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "upstream_backends", ROOT / "tools" / "upstream-backends.py"
)
assert SPEC and SPEC.loader
mod = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = mod
SPEC.loader.exec_module(mod)


def state(name: str, enabled: bool):
    return mod.BackendState(
        name=name,
        module_id=name.replace("-", "_"),
        installed=True,
        enabled=enabled,
        remove_pending=False,
        module_path=f"/data/adb/modules/{name}",
    )


class UpstreamBackendsTest(unittest.TestCase):
    def test_manifest_schema_and_external_licenses(self):
        manifest = mod.load_manifest(ROOT / "integrations" / "upstreams.json")
        self.assertEqual(manifest["schema_version"], 1)
        self.assertTrue(manifest["backends"]["fas-rs"]["license"].startswith("GPL-3.0"))
        self.assertEqual(manifest["backends"]["yumi"]["integration"], "external-module")
        self.assertEqual(manifest["backends"]["thread-opt"]["module_id"], "thread_opt")

    def test_preflight_accepts_zero_or_one_runtime_backend(self):
        self.assertTrue(mod.conflict_report([])["clean_single_backend"])
        self.assertTrue(mod.conflict_report([state("yumi", True)])["clean_single_backend"])

    def test_preflight_rejects_controller_overlap(self):
        report = mod.conflict_report([state("op13perf", True), state("yumi", True)])
        self.assertFalse(report["clean_single_backend"])
        self.assertEqual(report["active_runtime_backends"], ["op13perf", "yumi"])
        self.assertIn("contaminated", report["reason"])

    def test_disabled_backend_does_not_conflict(self):
        report = mod.conflict_report([state("op13perf", True), state("fas-rs", False)])
        self.assertTrue(report["clean_single_backend"])


if __name__ == "__main__":
    unittest.main()
