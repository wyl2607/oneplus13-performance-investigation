#!/system/bin/sh
set -eu

kv() { printf '%s=%s\n' "$1" "$2"; }

ENABLED="$(settings get global bluetooth_on 2>/dev/null || printf 'UNKNOWN')"
kv bluetooth_enabled "$ENABLED"

DUMP="$(dumpsys bluetooth_manager 2>/dev/null || true)"
if [ -n "$DUMP" ]; then
  if printf '%s\n' "$DUMP" | grep -q 'enabled: true'; then
    kv bluetooth_manager_state enabled
  elif printf '%s\n' "$DUMP" | grep -q 'enabled: false'; then
    kv bluetooth_manager_state disabled
  else
    kv bluetooth_manager_state UNKNOWN
  fi

  CONNECTED_COUNT="$(printf '%s\n' "$DUMP" | grep -Ec 'state[=: ]+CONNECTED|mConnectionState[=: ]+2' || true)"
  kv bluetooth_connected_markers "$CONNECTED_COUNT"
else
  kv bluetooth_manager_state UNKNOWN
  kv bluetooth_connected_markers UNKNOWN
fi

kv privacy "no_device_names_addresses_or_raw_bluetooth_dump_emitted"
