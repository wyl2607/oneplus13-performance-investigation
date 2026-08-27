from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "experiments" / "device-health-baseline"
DEVICE = BASE / "device"


def test_baseline_files_exist() -> None:
    expected = {
        BASE / "README.md",
        DEVICE / "preflight.sh",
        DEVICE / "snapshot.sh",
        DEVICE / "telemetry-30m.sh",
        DEVICE / "wifi-probe.sh",
        DEVICE / "bluetooth-probe.sh",
        DEVICE / "gps-probe.sh",
        DEVICE / "ufs-bounded.sh",
        DEVICE / "ram-probe.sh",
        ROOT / "docs" / "DEVICE_HEALTH_BASELINE_V1.md",
        ROOT / "tools" / "analyze-device-health-telemetry.py",
    }
    assert all(path.exists() for path in expected)


def test_device_health_scripts_do_not_touch_dangerous_radio_or_persist_state() -> None:
    forbidden = (
        "settings put",
        "setprop persist.",
        "persist.radio",
        "cmd phone set-allowed-network-types",
        "/dev/block/",
        "qmi",
        "qcn",
        "efs",
        "band lock",
        "nr-only",
    )
    for path in DEVICE.glob("*.sh"):
        text = path.read_text(encoding="utf-8").lower()
        for token in forbidden:
            assert token not in text, f"{path}: forbidden token {token!r}"


def test_probe_output_does_not_emit_known_sensitive_wifi_or_location_fields() -> None:
    wifi = (DEVICE / "wifi-probe.sh").read_text(encoding="utf-8")
    gps = (DEVICE / "gps-probe.sh").read_text(encoding="utf-8")
    bt = (DEVICE / "bluetooth-probe.sh").read_text(encoding="utf-8")

    assert 'printf \'%s\\n\' "$STATUS"' in wifi  # raw status may be parsed in-memory
    assert 'kv privacy "no_ssid_bssid_ip_or_mac_emitted"' in wifi
    assert 'kv privacy "no_coordinates_or_raw_location_dump_emitted"' in gps
    assert 'kv privacy "no_device_names_addresses_or_raw_bluetooth_dump_emitted"' in bt


def test_ufs_probe_is_bounded_and_cleans_up() -> None:
    text = (DEVICE / "ufs-bounded.sh").read_text(encoding="utf-8")
    assert "SIZE_MB:-256" in text
    assert '"$SIZE_MB" -le 512' in text
    assert 'TMP="/data/local/tmp/op13-health-ufs.tmp"' in text
    assert 'trap cleanup EXIT INT TERM' in text
    assert 'rm -f "$TMP"' in text


def test_30m_telemetry_has_thermal_abort() -> None:
    text = (DEVICE / "telemetry-30m.sh").read_text(encoding="utf-8")
    assert "DURATION_SECONDS:-1800" in text
    assert '"$TEMP" -ge 480' in text
    assert "THERMAL_ABORT" in text
