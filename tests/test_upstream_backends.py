import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "upstream_backends", ROOT / "tools" / "upstream-backends.py"
)
mod = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
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


def test_manifest_schema_and_external_licenses():
    manifest = mod.load_manifest(ROOT / "integrations" / "upstreams.json")
    assert manifest["schema_version"] == 1
    assert manifest["backends"]["fas-rs"]["license"].startswith("GPL-3.0")
    assert manifest["backends"]["yumi"]["integration"] == "external-module"
    assert manifest["backends"]["thread-opt"]["module_id"] == "thread_opt"


def test_preflight_accepts_zero_or_one_runtime_backend():
    assert mod.conflict_report([])["clean_single_backend"] is True
    assert mod.conflict_report([state("yumi", True)])["clean_single_backend"] is True


def test_preflight_rejects_controller_overlap():
    report = mod.conflict_report([state("op13perf", True), state("yumi", True)])
    assert report["clean_single_backend"] is False
    assert report["active_runtime_backends"] == ["op13perf", "yumi"]
    assert "contaminated" in report["reason"]


def test_disabled_backend_does_not_conflict():
    report = mod.conflict_report([state("op13perf", True), state("fas-rs", False)])
    assert report["clean_single_backend"] is True
