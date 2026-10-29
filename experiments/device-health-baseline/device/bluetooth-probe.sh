#!/system/bin/sh
set -eu

kv() { printf '%s=%s\n' "$1" "$2"; }

ENABLED="$(settings get global bluetooth_on 2>/dev/null || printf 'UNKNOWN')"
kv bluetooth_enabled "$ENABLED"

DUMP="$(dumpsys bluetooth_manager 2>/dev/null || true)"
if [ -n "$DUMP" ]; then
  if printf '%s\n' "$DUMP" | grep -qiE 'enabled:[[:space:]]*true|mEnabled[=:][[:space:]]*true|mState[=:][[:space:]]*(STATE_)?ON|state[=:][[:space:]]*(STATE_)?ON'; then
    kv bluetooth_manager_state enabled
  elif printf '%s\n' "$DUMP" | grep -qiE 'enabled:[[:space:]]*false|mEnabled[=:][[:space:]]*false|mState[=:][[:space:]]*(STATE_)?OFF|state[=:][[:space:]]*(STATE_)?OFF'; then
    kv bluetooth_manager_state disabled
  else
    kv bluetooth_manager_state UNKNOWN
  fi

  CONNECTED_COUNT="$(printf '%s\n' "$DUMP" | grep -Eci 'state[=: ]+CONNECTED|mConnectionState[=: ]+2|connectionState[=: ]+2' || true)"
  kv bluetooth_connected_markers "$CONNECTED_COUNT"
else
  kv bluetooth_manager_state UNKNOWN
  kv bluetooth_connected_markers UNKNOWN
fi

if [ "$ENABLED" = "1" ]; then
  kv bluetooth_setting_state enabled_requested
elif [ "$ENABLED" = "0" ]; then
  kv bluetooth_setting_state disabled_requested
else
  kv bluetooth_setting_state UNKNOWN
fi

kv note "adapter_on_without_an_active_device_is_not_a_Bluetooth_PASS; active_connection_and_reconnect_testing_required"
kv privacy "no_device_names_addresses_or_raw_bluetooth_dump_emitted"
