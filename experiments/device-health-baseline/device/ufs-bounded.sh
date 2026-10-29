#!/system/bin/sh
set -eu

TMP="/data/local/tmp/op13-health-ufs.tmp"
SIZE_MB="${SIZE_MB:-256}"

case "$SIZE_MB" in *[!0-9]*) echo "invalid SIZE_MB" >&2; exit 2;; esac
[ "$SIZE_MB" -ge 64 ] || { echo "SIZE_MB must be >=64" >&2; exit 2; }
[ "$SIZE_MB" -le 512 ] || { echo "SIZE_MB must be <=512" >&2; exit 2; }

cleanup() { rm -f "$TMP"; }
trap cleanup EXIT INT TERM

FREE_KB="$(df -k /data 2>/dev/null | tail -n1 | awk '{print $4}')"
NEED_KB=$((SIZE_MB * 1024 + 262144))
case "$FREE_KB" in ''|*[!0-9]*) echo "cannot determine /data free space" >&2; exit 3;; esac
[ "$FREE_KB" -ge "$NEED_KB" ] || { echo "insufficient free space" >&2; exit 3; }

BATTERY="$(dumpsys battery 2>/dev/null || true)"
TEMP="$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*temperature: //p' | head -n1)"
case "$TEMP" in
  ''|*[!0-9-]*) ;;
  *) [ "$TEMP" -lt 430 ] || { echo "thermal gate: battery >=43C" >&2; exit 4; } ;;
esac

echo "ufs_test_size_mb=$SIZE_MB"
echo "ufs_free_before_kb=$FREE_KB"
echo "ufs_write_begin"
(/system/bin/time -p dd if=/dev/zero of="$TMP" bs=1048576 count="$SIZE_MB" conv=fsync) 2>&1
echo "ufs_read_begin"
(/system/bin/time -p dd if="$TMP" of=/dev/null bs=1048576) 2>&1
sync
rm -f "$TMP"
trap - EXIT INT TERM
echo "ufs_cleanup=PASS"
