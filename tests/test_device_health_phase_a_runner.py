from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "tools" / "run-device-health-phase-a.py"


def test_phase_a_runner_exists_and_is_fail_closed() -> None:
    text = RUNNER.read_text(encoding="utf-8")
    assert "expected exactly one authorized ADB device" in text
    assert "PREFLIGHT_PASS" in text
    assert "COLLECTED_NOT_YET_CLASSIFIED" in text
    assert "No PASS/FAIL claim is made" in text


def test_phase_a_ufs_is_opt_in() -> None:
    text = RUNNER.read_text(encoding="utf-8")
    assert 'ap.add_argument("--ufs", action="store_true"' in text
    assert "if args.ufs:" in text
