#!/system/bin/sh
set -eu

kv() { printf '%s=%s\n' "$1" "$2"; }

kv location_mode "$(settings get secure location_mode 2>/dev/null || printf 'UNKNOWN')"

if cmd location is-location-enabled >/dev/null 2>&1; then
  kv location_enabled "$(cmd location is-location-enabled 2>/dev/null | tr -d '\r\n')"
else
  kv location_enabled UNKNOWN
fi

DUMP="$(dumpsys location 2>/dev/null || true)"
if [ -n "$DUMP" ]; then
  if printf '%s\n' "$DUMP" | grep -qiE 'gps|gnss'; then
    kv gnss_provider_present true
  else
    kv gnss_provider_present false
  fi
  if printf '%s\n' "$DUMP" | grep -qiE 'provider.*gps.*enabled|gps.*enabled=true|gps.*enabled'; then
    kv gnss_provider_enabled_marker true
  else
    kv gnss_provider_enabled_marker UNKNOWN
  fi
else
  kv gnss_provider_present UNKNOWN
  kv gnss_provider_enabled_marker UNKNOWN
fi

kv note "TTFF_accuracy_and_drift_require_an_active_location_test; this probe intentionally emits no coordinates"
kv privacy "no_coordinates_or_raw_location_dump_emitted"
