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


def test_wifi_ping_requires_explicit_wifi_connection_and_is_interface_scoped() -> None:
    text = (DEVICE / "wifi-probe.sh").read_text(encoding="utf-8")
    assert 'if [ "$CONNECTED" = "true" ]; then' in text
    assert "ping -I wlan0" in text
    assert "SKIPPED_WIFI_NOT_CONNECTED" in text
    assert "kv ping_target NOT_TESTED" in text


def test_ram_probe_does_not_turn_unreadable_proc_swaps_into_no_zram() -> None:
    text = (DEVICE / "ram-probe.sh").read_text(encoding="utf-8")
    assert "zram_device_present" in text
    assert "proc_swaps_readable" in text
    assert "kv zram_present UNKNOWN" in text
    assert "/sys/block/zram*" in text


def test_bluetooth_probe_keeps_adapter_state_separate_from_active_device_validation() -> None:
    text = (DEVICE / "bluetooth-probe.sh").read_text(encoding="utf-8")
    assert "bluetooth_setting_state" in text
    assert "bluetooth_manager_state" in text
    assert "active_connection_and_reconnect_testing_required" in text


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
