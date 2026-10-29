#!/bin/bash
# Scroll frame-pacing A/B, driven from the host.
#
# Arms: control (no uclamp.min) vs 512 (uclamp.min=512 on the foreground active
# set), using the R3 harness unchanged apart from its gfxinfo-capture fix.
#
# The package is a RUNTIME argument and is never written to anything committed
# (docs/R3_REAL_APP_PILOT.md#app-privacy) -- only the arm labels and the numbers
# are kept.
#
# Every run must produce framestats. A run that does not is FAILED loudly rather
# than recorded as a blank, because that is exactly how the 512 arm of the smoke
# pair silently lost its data before the harness fix.
#
# usage: run-scroll-ab.sh <plan.csv> <package> <outdir>
set -u

PLAN="$1"; PKG="$2"; OUT="$3"
mkdir -p "$OUT"
RESULTS="$OUT/results.csv"
LOG="$OUT/run.log"
RDIR=/data/local/tmp/op13-r3
SWIPE="720,2400,720,1000,300"
SWIPES=25
SETTLE_S=20

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
dev() { adb shell "su -M -c \"sh -c \\\"$1\\\"\"" </dev/null; }

echo "run_id,block,order,arm,frames,janky_pct,p90_ms,p95_ms,p99_ms,missed_vsync,junc_c,shell_c" > "$RESULTS"

say "=== scroll A/B start ==="
PLAN_ROWS=()
while IFS= read -r _l; do [ -n "$_l" ] && PLAN_ROWS[${#PLAN_ROWS[@]}]="$_l"; done < <(tail -n +2 "$PLAN")
say "plan holds ${#PLAN_ROWS[@]} runs"
[ "${#PLAN_ROWS[@]}" -gt 0 ] || { say "!! empty plan"; exit 7; }

for _row in "${PLAN_ROWS[@]}"; do
	IFS=, read -r run_id block order arm label <<<"$_row"
	case "$arm" in
		A) ARGS="--arm control" ;;
		B) ARGS="--arm 512 --mechanism active-set" ;;
		*) say "unknown arm $arm"; exit 2 ;;
	esac
	say "--- $run_id (block $block, order $order) arm=$arm $label"

	# bring the app forward and let the timeline settle; no force-stop, because a
	# cold X reloads the whole timeline and that is a bigger confound than warmth
	adb shell 'input keyevent KEYCODE_WAKEUP' >/dev/null 2>&1 </dev/null
	adb shell "monkey -p $PKG -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1 </dev/null
	sleep "$SETTLE_S"

	dev "cd $RDIR && sh run-one.sh --run-id $run_id --workload scroll_fling $ARGS --package $PKG --duration $SWIPES --swipe $SWIPE --out $RDIR/$run_id.log" >/dev/null 2>&1

	adb pull "$RDIR/$run_id.log" "$OUT/" >/dev/null 2>&1
	F=$(python3 - "$OUT/$run_id.log" <<'PY'
import re, sys
try:
    t = open(sys.argv[1], errors="replace").read()
except OSError:
    print("NONE"); raise SystemExit
m = re.search(r"#GFXINFO_BEGIN(.*?)#GFXINFO_END", t, re.S)
if not m: print("NONE"); raise SystemExit
b = m.group(1)
def g(p, d=""):
    x = re.search(p, b)
    return x.group(1) if x else d
frames = g(r"Total frames rendered:\s*(\d+)")
janky  = g(r"Janky frames:\s*\d+\s*\(([\d.]+)%\)")
p90    = g(r"90th percentile:\s*(\d+)ms")
p95    = g(r"95th percentile:\s*(\d+)ms")
p99    = g(r"99th percentile:\s*(\d+)ms")
miss   = g(r"Number Missed Vsync:\s*(\d+)")
print("NONE" if not frames else f"{frames},{janky},{p90},{p95},{p99},{miss}")
PY
)
	if [ "$F" = "NONE" ] || [ -z "$F" ]; then
		say "  !! $run_id produced no framestats - STOPPING rather than recording a blank"
		exit 6
	fi
	J=$(adb shell 'cat /sys/class/thermal/thermal_zone28/temp' </dev/null | tr -d '\r')
	S=$(adb shell 'for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type); [ "$t" = shell_front ] && cat $z/temp; done' </dev/null | tr -d '\r' | head -1)
	CLEAN=$(grep -c CLEANUP_VERIFY_FAILED "$OUT/$run_id.log" 2>/dev/null || true)
	[ "${CLEAN:-0}" != "0" ] && say "  !! BOOST NOT CLEANED UP on $run_id"

	say "  $F   junction $((J/1000))C shell $((S/1000))C"
	echo "$run_id,$block,$order,$arm,$F,$((J/1000)),$((S/1000))" >> "$RESULTS"
done

say "=== done, $(( $(wc -l < "$RESULTS") - 1 ))/${#PLAN_ROWS[@]} runs recorded ==="
cat "$RESULTS"
