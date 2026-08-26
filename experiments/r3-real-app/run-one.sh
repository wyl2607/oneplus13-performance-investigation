#!/system/bin/sh
# run-one.sh - one R3 real-app pilot run (docs/R3_REAL_APP_PILOT.md).
#
# usage (as root, from /data/local/tmp):
#   sh run-one.sh --run-id ID --workload cold_launch|app_switch|scroll_fling|
#                 steady_renderer|camera_launch --arm control|512
#                 --mechanism process|active-set --package REAL.PACKAGE.NAME
#                 --out LOGFILE
#                 [--activity COMPONENT] [--duration S] [--topk N]
#                 [--swipe X1,Y1,X2,Y2,DURATION_MS]
#
# --package takes the real package name as a runtime argument. It is never
# written to any file that gets committed -- only to --out, which lives
# under experiments/r3-real-app/raw/ (gitignored) and gets sanitized to
# APP_A/APP_B/APP_C by tools/analyze-r3-real-app.py before anything is
# staged (docs/R3_REAL_APP_PILOT.md#app-privacy).
#
# exit codes: 0 ok, 2 usage, 4 app never reached foreground,
#             9 RUN_ABORT_THERMAL_92, 10 SESSION_STOP_THERMAL_95

DIR=$(dirname "$0")
. "$DIR/common.sh"

RUN_ID=""; WORKLOAD=""; ARM=""; MECHANISM=""; PACKAGE=""; ACTIVITY=""
DURATION=8; TOPK=4; SWIPE="540,1500,540,600,300"; OUT=""

while [ $# -gt 0 ]; do
	case "$1" in
		--run-id)     RUN_ID=$2; shift 2 ;;
		--workload)   WORKLOAD=$2; shift 2 ;;
		--arm)        ARM=$2; shift 2 ;;
		--mechanism)  MECHANISM=$2; shift 2 ;;
		--package)    PACKAGE=$2; shift 2 ;;
		--activity)   ACTIVITY=$2; shift 2 ;;
		--duration)   DURATION=$2; shift 2 ;;
		--topk)       TOPK=$2; shift 2 ;;
		--swipe)      SWIPE=$2; shift 2 ;;
		--out)        OUT=$2; shift 2 ;;
		*) say "ERROR: unknown arg $1"; exit 2 ;;
	esac
done
for req in RUN_ID WORKLOAD ARM PACKAGE OUT; do
	eval "v=\$$req"
	[ -n "$v" ] || { say "ERROR: --$(echo $req | tr 'A-Z' 'a-z' | tr '_' '-') is required"; exit 2; }
done
case "$ARM" in
	control) ;;
	512) [ -n "$MECHANISM" ] || { say "ERROR: --mechanism required for arm=512"; exit 2; } ;;
	*) say "ERROR: --arm must be control or 512, got: $ARM"; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { say "ERROR: must run as root"; exit 2; }
command -v uclampset >/dev/null 2>&1 || { say "ERROR: uclampset not on PATH"; exit 2; }

resolve_zones || exit 2
discover_prime

WORKDIR=/data/local/tmp/op13-r3
mkdir -p "$WORKDIR" 2>/dev/null
STOP=$WORKDIR/stop.$RUN_ID
SETFILE=$WORKDIR/activeset.$RUN_ID
: > "$OUT"
rm -f "$STOP" "$SETFILE"

TIS0_BEFORE=$OUT.tis0.before
TIS0_AFTER=$OUT.tis0.after
TIS6_BEFORE=$OUT.tis6.before
TIS6_AFTER=$OUT.tis6.after

SAMPLER_PID=""; CLAMP_PID=""
cleanup() {
	[ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null
	[ -n "$CLAMP_PID" ] && kill "$CLAMP_PID" 2>/dev/null
	_pid=$(pkg_pid "$PACKAGE")
	if [ -n "$_pid" ]; then
		[ "$ARM" = "512" ] && [ "$MECHANISM" = "process" ] && reset_process_clamp "$_pid"
		if [ "$ARM" = "512" ] && [ "$MECHANISM" = "active-set" ] && [ -f "$SETFILE" ]; then
			for _t in $(cat "$SETFILE"); do
				[ -d "/proc/$_pid/task/$_t" ] && uclampset -m 0 -p "$_t" 2>/dev/null
			done
		fi
	fi
	rm -f "$STOP" "$SETFILE"
}
trap 'cleanup; exit 130' INT TERM

# --- preflight ---
say "#META run_id=$RUN_ID workload=$WORKLOAD arm=$ARM mechanism=${MECHANISM:-none}" >> "$OUT"
SCR=$(dumpsys display 2>/dev/null | grep -m1 mScreenState)
say "#META screen=${SCR:-unavailable}" >> "$OUT"
case "$SCR" in
	*ON*|*on*) ;;
	*) say "WARNING: screen does not look ON (METHODOLOGY trap 2)" ;;
esac
check_thermal
if [ "$THERMAL_LEVEL" -ge 1 ]; then
	say "RESULT run_id=$RUN_ID status=THERMAL_ABOVE_SOFT_GATE_AT_START j=$THERMAL_J s=$THERMAL_S"
	exit 9
fi

# --- clamp + sampler background loops ---
if [ "$ARM" = "512" ]; then
	{
		while [ ! -f "$STOP" ]; do
			_pid=$(pkg_pid "$PACKAGE")
			if [ -n "$_pid" ]; then
				if [ "$MECHANISM" = "process" ]; then
					apply_process_clamp "$_pid"
				else
					active_set_tick "$_pid" "$TOPK" "$SETFILE" >> "$OUT.activeset" 2>/dev/null
				fi
			fi
			sleep "$TICK_S"
		done
	} &
	CLAMP_PID=$!
fi

{
	while [ ! -f "$STOP" ]; do
		check_thermal
		snapshot_stat
		_pid=$(pkg_pid "$PACKAGE")
		_nthr=0
		if [ -n "$_pid" ] && [ -d "/proc/$_pid/task" ]; then
			_nthr=$(ls "/proc/$_pid/task" 2>/dev/null | wc -l)
		fi
		_nclamp=0
		[ -f "$SETFILE" ] && _nclamp=$(wc -w < "$SETFILE" 2>/dev/null)
		printf 'S|%s|j=%s|s=%s|all_busy=%s|prime_busy=%s|fg_threads=%s|clamped_threads=%s\n' \
			"$(now_cs)" "$THERMAL_J" "$THERMAL_S" "$ALL_BUSY" "$PRIME_BUSY" "$_nthr" "${_nclamp:-0}" >> "$OUT"
		if [ "$THERMAL_LEVEL" -ge 1 ]; then
			say "$([ "$THERMAL_LEVEL" = 2 ] && echo SESSION_STOP || echo RUN_ABORT)" > "$STOP.thermal"
			: > "$STOP"
			break
		fi
		sleep "$TICK_S"
	done
} &
SAMPLER_PID=$!

cp "$POLICY0_TIS" "$TIS0_BEFORE" 2>/dev/null
cp "$POLICY6_TIS" "$TIS6_BEFORE" 2>/dev/null

# --- run the workload action ---
STATUS=OK
EVENT_MS=""
T_START=$(now_cs)

case "$WORKLOAD" in
	cold_launch)
		am force-stop "$PACKAGE" >/dev/null 2>&1
		sleep 0.5
		_target="$PACKAGE"
		[ -n "$ACTIVITY" ] && _target="$PACKAGE/$ACTIVITY"
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(($(now_cs) * 10))" >> "$OUT"
		AMOUT=$(am start -W -n "$_target" 2>&1)
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(($(now_cs) * 10))" >> "$OUT"
		say "#AM_START $AMOUT" >> "$OUT"
		EVENT_MS=$(printf '%s\n' "$AMOUT" | sed -n 's/^TotalTime: //p')
		[ -n "$EVENT_MS" ] || STATUS=NO_TOTALTIME_PARSED
		sleep "$DURATION"
		;;
	app_switch)
		_target="$PACKAGE"
		[ -n "$ACTIVITY" ] && _target="$PACKAGE/$ACTIVITY"
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(($(now_cs) * 10))" >> "$OUT"
		AMOUT=$(am start -W -n "$_target" 2>&1)
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(($(now_cs) * 10))" >> "$OUT"
		say "#AM_START $AMOUT" >> "$OUT"
		EVENT_MS=$(printf '%s\n' "$AMOUT" | sed -n 's/^TotalTime: //p')
		[ -n "$EVENT_MS" ] || STATUS=NO_TOTALTIME_PARSED
		sleep "$DURATION"
		;;
	scroll_fling)
		dumpsys gfxinfo "$PACKAGE" reset >/dev/null 2>&1
		sleep 0.3
		X1=$(echo "$SWIPE" | cut -d, -f1); Y1=$(echo "$SWIPE" | cut -d, -f2)
		X2=$(echo "$SWIPE" | cut -d, -f3); Y2=$(echo "$SWIPE" | cut -d, -f4)
		SDUR=$(echo "$SWIPE" | cut -d, -f5)
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(($(now_cs) * 10))" >> "$OUT"
		_n=0
		while [ "$_n" -lt "$DURATION" ]; do
			input swipe "$X1" "$Y1" "$X2" "$Y2" "$SDUR" >/dev/null 2>&1
			sleep 0.5
			_n=$((_n + 1))
		done
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(($(now_cs) * 10))" >> "$OUT"
		GFX=$(dumpsys gfxinfo "$PACKAGE" 2>/dev/null)
		say "#GFXINFO_BEGIN" >> "$OUT"
		printf '%s\n' "$GFX" | grep -E 'Total frames rendered|Janky frames|Number Missed Vsync|90th percentile|95th percentile|99th percentile' >> "$OUT"
		say "#GFXINFO_END" >> "$OUT"
		;;
	steady_renderer)
		dumpsys gfxinfo "$PACKAGE" reset >/dev/null 2>&1
		sleep "$DURATION"
		GFX=$(dumpsys gfxinfo "$PACKAGE" 2>/dev/null)
		say "#GFXINFO_BEGIN" >> "$OUT"
		printf '%s\n' "$GFX" | grep -E 'Total frames rendered|Janky frames|Number Missed Vsync|90th percentile|95th percentile|99th percentile' >> "$OUT"
		say "#GFXINFO_END" >> "$OUT"
		;;
	camera_launch)
		am force-stop "$PACKAGE" >/dev/null 2>&1
		sleep 0.5
		_target="$PACKAGE"
		[ -n "$ACTIVITY" ] && _target="$PACKAGE/$ACTIVITY"
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(($(now_cs) * 10))" >> "$OUT"
		AMOUT=$(am start -W -n "$_target" 2>&1)
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(($(now_cs) * 10))" >> "$OUT"
		say "#AM_START $AMOUT" >> "$OUT"
		EVENT_MS=$(printf '%s\n' "$AMOUT" | sed -n 's/^TotalTime: //p')
		[ -n "$EVENT_MS" ] || STATUS=NO_TOTALTIME_PARSED
		sleep "$DURATION"
		;;
	*)
		say "ERROR: unknown workload $WORKLOAD"
		: > "$STOP"; wait "$SAMPLER_PID" 2>/dev/null; [ -n "$CLAMP_PID" ] && wait "$CLAMP_PID" 2>/dev/null
		cleanup
		exit 2
		;;
esac

T_END=$(now_cs)
: > "$STOP"
wait "$SAMPLER_PID" 2>/dev/null
[ -n "$CLAMP_PID" ] && wait "$CLAMP_PID" 2>/dev/null

cp "$POLICY0_TIS" "$TIS0_AFTER" 2>/dev/null
cp "$POLICY6_TIS" "$TIS6_AFTER" 2>/dev/null

THERMAL=$(cat "$STOP.thermal" 2>/dev/null)
[ "$THERMAL" = "SESSION_STOP" ] && STATUS=SESSION_STOP_THERMAL_95
[ "$THERMAL" = "RUN_ABORT" ] && STATUS=RUN_ABORT_THERMAL_92

cleanup
rm -f "$STOP.thermal"

WALL_CS=$((T_END - T_START))
say "RESULT run_id=$RUN_ID workload=$WORKLOAD arm=$ARM mechanism=${MECHANISM:-none} wall_cs=$WALL_CS event_ms=${EVENT_MS:-NA} status=$STATUS out=$OUT tis0_before=$TIS0_BEFORE tis0_after=$TIS0_AFTER tis6_before=$TIS6_BEFORE tis6_after=$TIS6_AFTER"

[ "$STATUS" = "SESSION_STOP_THERMAL_95" ] && exit 10
[ "$STATUS" = "RUN_ABORT_THERMAL_92" ] && exit 9
exit 0
