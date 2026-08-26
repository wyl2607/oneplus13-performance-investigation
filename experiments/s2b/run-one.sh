#!/system/bin/sh
# run-one.sh - orchestrate a single S2b run: start the wake worker, apply the
# arm's uclamp.min, trace its wake path, and report a thermal-gated summary.
#
# Combines wake-pair-worker.sh (PR #13) and scheduler-event-tracer.sh (PR #13)
# in one su session so worker start, uclamp application, and tracer start
# happen back-to-back without inter-process adb round trips.
#
# usage (as root, from /data/local/tmp):
#   sh run-one.sh --run-id ID --arm A|B --uclamp-min N --duration S
#                 --uclamp-offsets PID,REQ,EFF,SE_SIZE --out TRACE_FILE
#                 [--worker-duration S] [--burst N] [--sleep-s S]
#
# prints one RESULT line to stdout; the trace itself goes to --out.
# exit codes: 0 ok, 2 usage, 4 worker did not start, 5 tracer loss,
#             9 thermal abort (peak >= 92C, run skipped), 10 thermal
#             session-stop (peak >= 95C)

DIR=$(dirname "$0")
RUN_ID=""
ARM=""
UMIN=""
DURATION=10
WORKER_DURATION=""
BURST=1200
SLEEP_S=0.020
OFFSETS=""
OUT=""
UID_=10999
CPUSET=/dev/cpuset/top-app/tasks
TZ_TYPE=cpu-1-1-1
WORKDIR=/data/local/tmp/op13-s2b

while [ $# -gt 0 ]; do
	case "$1" in
		--run-id)          RUN_ID=$2; shift 2 ;;
		--arm)             ARM=$2; shift 2 ;;
		--uclamp-min)      UMIN=$2; shift 2 ;;
		--duration)        DURATION=$2; shift 2 ;;
		--worker-duration) WORKER_DURATION=$2; shift 2 ;;
		--burst)           BURST=$2; shift 2 ;;
		--sleep-s)         SLEEP_S=$2; shift 2 ;;
		--uclamp-offsets)  OFFSETS=$2; shift 2 ;;
		--out)             OUT=$2; shift 2 ;;
		*) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
	esac
done
[ -n "$RUN_ID" ] && [ -n "$ARM" ] && [ -n "$UMIN" ] && [ -n "$OUT" ] || {
	echo "ERROR: --run-id --arm --uclamp-min --out are required" >&2; exit 2
}
[ -n "$WORKER_DURATION" ] || WORKER_DURATION=$((DURATION + 6))
[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 2; }
mkdir -p "$WORKDIR"

ZONE=""
for z in /sys/class/thermal/thermal_zone*; do
	[ "$(cat "$z/type" 2>/dev/null)" = "$TZ_TYPE" ] && ZONE=$z && break
done
[ -n "$ZONE" ] || { echo "ERROR: could not resolve thermal zone '$TZ_TYPE' by name" >&2; exit 2; }
read_temp() { awk '{printf "%.1f", $1/1000}' "$ZONE/temp"; }

WOUT=$WORKDIR/wout.$RUN_ID
STOP=$WORKDIR/stop.$RUN_ID
TEMPLOG=$WORKDIR/temp.$RUN_ID
rm -f "$WOUT" "$STOP" "$TEMPLOG"
: > "$STOP.done"
rm -f "$STOP.done"

WORKER_SHPID=""
TID=""
WATCHPID=""

cleanup() {
	[ -n "$WATCHPID" ] && kill "$WATCHPID" 2>/dev/null
	[ -n "$TID" ] && kill -9 "$TID" 2>/dev/null
	[ -n "$WORKER_SHPID" ] && kill -9 "$WORKER_SHPID" 2>/dev/null
	: > "$STOP.done"
	rm -f "$STOP" "$WOUT" "$TEMPLOG"
}
trap 'cleanup; exit 130' INT TERM

START_TEMP=$(read_temp)
{
	while [ ! -f "$STOP.done" ]; do
		t=$(read_temp)
		echo "$t" >> "$TEMPLOG"
		lvl=$(awk -v t="$t" 'BEGIN{if(t>=95.0)print 2;else if(t>=92.0)print 1;else print 0}')
		if [ "$lvl" = 2 ]; then
			echo SESSION_STOP > "$STOP"
			[ -n "$TID" ] && kill -9 "$TID" 2>/dev/null
			[ -n "$WORKER_SHPID" ] && kill -9 "$WORKER_SHPID" 2>/dev/null
			break
		elif [ "$lvl" = 1 ]; then
			echo RUN_ABORT > "$STOP"
			[ -n "$TID" ] && kill -9 "$TID" 2>/dev/null
			[ -n "$WORKER_SHPID" ] && kill -9 "$WORKER_SHPID" 2>/dev/null
			break
		fi
		sleep 0.25
	done
} &
WATCHPID=$!

sh "$DIR/wake-pair-worker.sh" --mode wake --duration "$WORKER_DURATION" \
	--burst "$BURST" --sleep-s "$SLEEP_S" --uid "$UID_" --cpuset "$CPUSET" \
	> "$WOUT" 2>&1 &
WORKER_SHPID=$!

I=0
while [ $I -lt 50 ]; do
	TID=$(sed -n 's/^WORKER tid=\([0-9]*\).*/\1/p' "$WOUT" | head -1)
	[ -n "$TID" ] && break
	sleep 0.1
	I=$((I + 1))
done
if [ -z "$TID" ]; then
	echo "RESULT run_id=$RUN_ID arm=$ARM status=WORKER_NEVER_STARTED"
	cleanup; exit 4
fi

BEFORE=$(uclampset -p "$TID" 2>&1)
uclampset -m "$UMIN" -p "$TID" >/dev/null 2>&1
AFTER=$(uclampset -p "$TID" 2>&1)
REQ_READBACK=$(echo "$AFTER" | sed -n 's/.*min: \([0-9]*\).*/\1/p')

TRACE_RC=0
if [ -n "$OFFSETS" ]; then
	# OFFSETS is PID_OFFSET,UCLAMP_REQ_OFFSET,UCLAMP_OFFSET,SE_SIZE - fixed
	# byte offsets into task_struct from tools/btf-offsets.py, the SAME for
	# every run on this kernel build. It is NOT the traced TID; the tracer
	# filters on TID separately via --tid.
	sh "$DIR/scheduler-event-tracer.sh" --tid "$TID" --duration "$DURATION" \
		--uclamp-offsets "$OFFSETS" --label "s2b-$RUN_ID-$ARM" \
		--out "$OUT" || TRACE_RC=$?
else
	sh "$DIR/scheduler-event-tracer.sh" --tid "$TID" --duration "$DURATION" \
		--label "s2b-$RUN_ID-$ARM" --out "$OUT" || TRACE_RC=$?
fi

END_TEMP=$(read_temp)
: > "$STOP.done"
wait "$WATCHPID" 2>/dev/null
PEAK_TEMP=$(sort -n "$TEMPLOG" 2>/dev/null | tail -1)
[ -z "$PEAK_TEMP" ] && PEAK_TEMP=$END_TEMP

kill -9 "$TID" 2>/dev/null
kill -9 "$WORKER_SHPID" 2>/dev/null
BURSTS=$(sed -n 's/^BURSTS n=\([0-9]*\).*/\1/p' "$WOUT" | head -1)

THERMAL=$(cat "$STOP" 2>/dev/null)
rm -f "$WOUT" "$STOP" "$TEMPLOG"

STATUS=OK
[ "$TRACE_RC" != 0 ] && STATUS="TRACE_RC_$TRACE_RC"
[ "$THERMAL" = "RUN_ABORT" ] && STATUS=RUN_ABORT_THERMAL_92
[ "$THERMAL" = "SESSION_STOP" ] && STATUS=SESSION_STOP_THERMAL_95

echo "RESULT run_id=$RUN_ID arm=$ARM tid=$TID requested_min=$UMIN req_readback=$REQ_READBACK start_temp=$START_TEMP peak_temp=$PEAK_TEMP end_temp=$END_TEMP bursts=$BURSTS trace_rc=$TRACE_RC status=$STATUS out=$OUT"

[ "$THERMAL" = "SESSION_STOP" ] && exit 10
[ "$THERMAL" = "RUN_ABORT" ] && exit 9
[ "$TRACE_RC" != 0 ] && exit "$TRACE_RC"
exit 0
