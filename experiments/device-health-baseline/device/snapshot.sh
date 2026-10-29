#!/system/bin/sh
set -eu

kv() { printf '%s=%s\n' "$1" "$2"; }
read1() { [ -r "$1" ] && cat "$1" 2>/dev/null || printf 'UNKNOWN'; }

NOW="$(date +%s 2>/dev/null || printf 'UNKNOWN')"
kv timestamp_unix "$NOW"
kv model "$(getprop ro.product.model 2>/dev/null || printf 'UNKNOWN')"
kv build_incremental "$(getprop ro.build.version.incremental 2>/dev/null || printf 'UNKNOWN')"
kv android_release "$(getprop ro.build.version.release 2>/dev/null || printf 'UNKNOWN')"

BATTERY="$(dumpsys battery 2>/dev/null || true)"
kv battery_level_pct "$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*level: //p' | head -n1)"
kv battery_temp_tenths_c "$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*temperature: //p' | head -n1)"
kv battery_status "$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*status: //p' | head -n1)"
kv battery_charge_counter_uah "$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*Charge counter: //p' | head -n1)"

kv wifi_enabled "$(settings get global wifi_on 2>/dev/null || printf 'UNKNOWN')"
kv bluetooth_enabled "$(settings get global bluetooth_on 2>/dev/null || printf 'UNKNOWN')"
kv location_mode "$(settings get secure location_mode 2>/dev/null || printf 'UNKNOWN')"
kv airplane_mode "$(settings get global airplane_mode_on 2>/dev/null || printf 'UNKNOWN')"

MEMTOTAL="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
MEMAVAIL="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
SWAPTOTAL="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
SWAPFREE="$(awk '/^SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
kv mem_total_kb "${MEMTOTAL:-UNKNOWN}"
kv mem_available_kb "${MEMAVAIL:-UNKNOWN}"
kv swap_total_kb "${SWAPTOTAL:-UNKNOWN}"
kv swap_free_kb "${SWAPFREE:-UNKNOWN}"

for kind in cpu memory io; do
  if [ -r "/proc/pressure/$kind" ]; then
    line="$(head -n1 "/proc/pressure/$kind" | tr ' ' ';')"
    kv "psi_${kind}_some" "$line"
  else
    kv "psi_${kind}_some" UNKNOWN
  fi
done

for pol in 0 6; do
  base="/sys/devices/system/cpu/cpufreq/policy$pol"
  [ -d "$base" ] || continue
  kv "policy${pol}_cur_khz" "$(read1 "$base/scaling_cur_freq")"
  kv "policy${pol}_max_khz" "$(read1 "$base/scaling_max_freq")"
  kv "policy${pol}_cpuinfo_max_khz" "$(read1 "$base/cpuinfo_max_freq")"
done

THERM="$(dumpsys thermalservice 2>/dev/null | grep -m1 -E 'Status|Thermal Status|mStatus' | sed 's/[[:space:]]\+/ /g' || true)"
kv thermal_status_summary "${THERM:-UNKNOWN}"

DATA_DF="$(df -k /data 2>/dev/null | tail -n1 || true)"
kv data_df_kb "$(printf '%s' "$DATA_DF" | awk '{print $2 "," $3 "," $4 "," $5}')"

kv snapshot_privacy "sanitized_no_ssid_bssid_mac_gps_or_raw_dumpsys"
