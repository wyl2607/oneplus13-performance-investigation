#!/system/bin/sh
set -eu

OUT="${1:-/data/local/tmp/op13-health-30m.csv}"
DURATION="${DURATION_SECONDS:-1800}"
INTERVAL="${INTERVAL_SECONDS:-5}"

case "$DURATION" in *[!0-9]*) echo "invalid DURATION_SECONDS" >&2; exit 2;; esac
case "$INTERVAL" in *[!0-9]*) echo "invalid INTERVAL_SECONDS" >&2; exit 2;; esac
[ "$DURATION" -gt 0 ] || exit 2
[ "$INTERVAL" -gt 0 ] || exit 2

readf() { [ -r "$1" ] && cat "$1" 2>/dev/null || printf ''; }

printf 'elapsed_s,battery_pct,battery_temp_tenths_c,charge_counter_uah,policy0_cur_khz,policy0_max_khz,policy6_cur_khz,policy6_max_khz,thermal_status\n' > "$OUT"

START="$(date +%s)"
END=$((START + DURATION))

while :; do
  NOW="$(date +%s)"
  [ "$NOW" -le "$END" ] || break
  ELAPSED=$((NOW - START))
  BATTERY="$(dumpsys battery 2>/dev/null || true)"
  LEVEL="$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*level: //p' | head -n1)"
  TEMP="$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*temperature: //p' | head -n1)"
  CHARGE="$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*Charge counter: //p' | head -n1)"
  P0CUR="$(readf /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq)"
  P0MAX="$(readf /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)"
  P6CUR="$(readf /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq)"
  P6MAX="$(readf /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)"
  THERM="$(dumpsys thermalservice 2>/dev/null | grep -m1 -E 'Status|Thermal Status|mStatus' | tr ',' ';' | tr -s ' ' || true)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$ELAPSED" "$LEVEL" "$TEMP" "$CHARGE" "$P0CUR" "$P0MAX" "$P6CUR" "$P6MAX" "$THERM" >> "$OUT"

  case "$TEMP" in
    ''|*[!0-9-]*) ;;
    *)
      if [ "$TEMP" -ge 480 ]; then
        echo "THERMAL_ABORT: battery >=48C at ${ELAPSED}s" >&2
        exit 3
      fi
      ;;
  esac
  sleep "$INTERVAL"
done

echo "TELEMETRY_COMPLETE: $OUT"
