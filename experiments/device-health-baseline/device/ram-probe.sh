#!/system/bin/sh
set -eu

kv() { printf '%s=%s\n' "$1" "$2"; }
mem() { awk -v key="$1" '$1 == key":" {print $2}' /proc/meminfo 2>/dev/null; }

kv mem_total_kb "$(mem MemTotal)"
kv mem_available_kb "$(mem MemAvailable)"
kv active_kb "$(mem Active)"
kv inactive_kb "$(mem Inactive)"
kv swap_total_kb "$(mem SwapTotal)"
kv swap_free_kb "$(mem SwapFree)"
kv dirty_kb "$(mem Dirty)"
kv writeback_kb "$(mem Writeback)"

for kind in cpu memory io; do
  if [ -r "/proc/pressure/$kind" ]; then
    SOME="$(grep '^some ' "/proc/pressure/$kind" 2>/dev/null | tr ' ' ';' || true)"
    FULL="$(grep '^full ' "/proc/pressure/$kind" 2>/dev/null | tr ' ' ';' || true)"
    kv "psi_${kind}_some" "${SOME:-UNKNOWN}"
    kv "psi_${kind}_full" "${FULL:-UNKNOWN}"
  else
    kv "psi_${kind}_some" UNKNOWN
    kv "psi_${kind}_full" UNKNOWN
  fi
done

ZRAM="$(awk '$1 ~ /zram/ {print $1}' /proc/swaps 2>/dev/null | head -n1 || true)"
if [ -n "$ZRAM" ]; then
  kv zram_present true
  ZNAME="${ZRAM##*/}"
  kv zram_disksize_bytes "$(cat "/sys/block/$ZNAME/disksize" 2>/dev/null || printf 'UNKNOWN')"
  kv zram_mem_used_total "$(awk '{print $3}' "/sys/block/$ZNAME/mm_stat" 2>/dev/null || printf 'UNKNOWN')"
else
  kv zram_present false
fi

LMKD="$(logcat -d -b system -t 2000 2>/dev/null | grep -ciE 'lmkd|lowmemorykiller' || true)"
kv recent_lmkd_log_markers "$LMKD"
kv privacy "no_process_names_or_package_names_emitted"
