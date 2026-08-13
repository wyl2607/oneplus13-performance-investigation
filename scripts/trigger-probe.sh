#!/system/bin/sh
# trigger_probe.sh - measure what makes oplus_bsp_task_overload flag a thread.
#
# Runs a bounded busy loop under a chosen uid and optional affinity mask, and
# times how long it takes for a new row to appear in /proc/task_overload/abnormal_task.
#
# READ-ONLY with respect to kernel tunables. The only things it creates are its own
# short-lived busy loops, which it kills. Aborts on junction > 90 C.
#
# usage: sh trigger_probe.sh <uid> <max_seconds> <taskset_mask|none> [label]

TOL=/proc/task_overload/abnormal_task
J_ABORT=90000
PAT='trigprobe_busy'

Z_J=NA
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done

# /proc/uptime in centiseconds, integer. `date +%s%N` is unusable on toybox.
now() { read a b < /proc/uptime; echo "${a%.*}${a#*.}"; }

cleanup() {
	pkill -9 -f "$PAT" 2>/dev/null
	kill -9 $W 2>/dev/null
}

U="${1:-10999}"
MAX="${2:-90}"
MASK="${3:-none}"
LABEL="${4:-trial}"

MAXCS=$((MAX * 100))
B=$(wc -l < "$TOL" 2>/dev/null || echo 0)
J0=0; [ "$Z_J" != "NA" ] && read J0 < "$Z_J"

# The marker in the command line is what lets cleanup find every child, since
# killing the `su` wrapper does not reap the loop it spawned.
if [ "$MASK" = "none" ]; then
	su "$U" -c "sh -c 'i=0; while : ; do i=\$((i+1)); done # $PAT'" &
else
	su "$U" -c "taskset $MASK sh -c 'i=0; while : ; do i=\$((i+1)); done # $PAT'" &
fi
W=$!
trap cleanup EXIT INT TERM

T0=$(now)
RESULT=TIMEOUT
ROW=""
UC=""
# The table can be rate-limited or deduplicated, so watching it alone would miss a
# clamp that was applied without being logged. The task's own uclamp.max is ground truth.
BPID=""
while : ; do
	EL=$(( $(now) - T0 ))

	[ -z "$BPID" ] && BPID=$(pgrep -f "$PAT" 2>/dev/null | tail -1)
	if [ -n "$BPID" ] && [ -r "/proc/$BPID/sched" ]; then
		V=$(awk '/^uclamp\.max /{print $NF; exit}' "/proc/$BPID/sched" 2>/dev/null)
		if [ -n "$V" ] && [ "$V" != "1024" ]; then
			RESULT=CLAMPED
			UC="$V"
			ROW=$(tail -1 "$TOL" 2>/dev/null)
			break
		fi
	fi

	C=$(wc -l < "$TOL" 2>/dev/null || echo "$B")
	if [ "$C" != "$B" ]; then
		RESULT=LOGGED_ONLY
		ROW=$(tail -1 "$TOL" 2>/dev/null)
		break
	fi
	if [ "$Z_J" != "NA" ]; then
		read J < "$Z_J"
		if [ "${J:-0}" -gt "$J_ABORT" ]; then RESULT="THERMAL_ABORT_j=$J"; break; fi
	fi
	[ "$EL" -ge "$MAXCS" ] && break
	sleep 0.1
done

cleanup
trap - EXIT INT TERM
J1=0; [ "$Z_J" != "NA" ] && read J1 < "$Z_J"

printf 'TRIAL|%s|uid=%s|mask=%s|elapsed_s=%d.%02d|result=%s|uclamp=%s|j0=%s|j1=%s|row=%s\n' \
	"$LABEL" "$U" "$MASK" "$((EL / 100))" "$((EL % 100))" "$RESULT" "${UC:-1024}" "$J0" "$J1" "$ROW"
