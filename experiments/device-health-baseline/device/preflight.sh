#!/system/bin/sh
set -eu

fail() { echo "PREFLIGHT_FAIL: $*"; exit 1; }
warn() { echo "PREFLIGHT_WARN: $*"; }

command -v getprop >/dev/null 2>&1 || fail "getprop unavailable"
command -v dumpsys >/dev/null 2>&1 || fail "dumpsys unavailable"

MODEL="$(getprop ro.product.model 2>/dev/null || true)"
DEVICE="$(getprop ro.product.device 2>/dev/null || true)"
BUILD="$(getprop ro.build.fingerprint 2>/dev/null || true)"
SDK="$(getprop ro.build.version.sdk 2>/dev/null || true)"

[ -n "$MODEL" ] || warn "model unavailable"
[ -n "$BUILD" ] || warn "build fingerprint unavailable"

BATTERY="$(dumpsys battery 2>/dev/null || true)"
LEVEL="$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*level: //p' | head -n1)"
TEMP_TENTHS="$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*temperature: //p' | head -n1)"
STATUS="$(printf '%s\n' "$BATTERY" | sed -n 's/^[[:space:]]*status: //p' | head -n1)"

printf 'model=%s\n' "$MODEL"
printf 'device=%s\n' "$DEVICE"
printf 'sdk=%s\n' "$SDK"
printf 'battery_level_pct=%s\n' "${LEVEL:-UNKNOWN}"
printf 'battery_temp_tenths_c=%s\n' "${TEMP_TENTHS:-UNKNOWN}"
printf 'battery_status=%s\n' "${STATUS:-UNKNOWN}"
printf 'build_fingerprint=%s\n' "${BUILD:-UNKNOWN}"

if [ -n "$TEMP_TENTHS" ]; then
  case "$TEMP_TENTHS" in
    *[!0-9-]*) warn "unparseable battery temperature: $TEMP_TENTHS" ;;
    *)
      if [ "$TEMP_TENTHS" -ge 450 ]; then
        fail "battery temperature >=45C; cool device before baseline"
      fi
      ;;
  esac
fi

if [ -n "$LEVEL" ]; then
  case "$LEVEL" in
    *[!0-9]*) warn "unparseable battery level: $LEVEL" ;;
    *)
      if [ "$LEVEL" -lt 30 ]; then
        warn "battery below 30%; sustained/standby comparisons should start higher"
      fi
      ;;
  esac
fi

printf 'PREFLIGHT_PASS\n'
