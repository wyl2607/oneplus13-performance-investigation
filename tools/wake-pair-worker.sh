#!/system/bin/sh
# wake-pair-worker.sh - the S1 controlled pair, made reproducible.
#
# Two workers that do the *same* arithmetic and differ only in whether the
# thread ever sleeps:
#   continuous  spin, never sleeps
#   wake        the same burst, then sleep, at a fixed rate
#
# S1 ran this pair from a scratch script that was deleted during device restore,
# so the pair could not be re-run. It lives here now.
#
# Both run under the same app uid and are moved into the same cpuset, so uid,
# cgroup, shell and machine are held constant and only the sleep/wake pattern
# differs.
#
# Two device-specific constraints are baked in, both measured in S1:
#   - /system/bin/sh is mksh and printf is NOT a builtin (6.4 ms per fork), so
#     nothing forks inside the loop. That includes the loop's own deadline test:
#     `$(cut -d. -f1 /proc/uptime)` forks once per iteration, which held the
#     "continuous" worker at 57 % duty instead of ~100 %. `read _u _r
#     < /proc/uptime` is a builtin read and does not fork.
#   - `sleep` forks. The sleep here is `read -t` against a fifo that has a
#     long-lived writer; without a writer, opening the fifo blocks forever.
#
# The worker writes its OWN pid. `su UID -c ...` reports the wrapper's pid, not
# the worker's -- in S1 that mistake put the wrapper in top-app and left the real
# worker invisible, wasting a full trace.
#
# The rename uses `echo -n`. This kernel does NOT strip a trailing newline on a
# write to /proc/self/comm, and a thread named "w-wake\n" turns its own
# /proc/<tid>/stat into a two-line file, which silently breaks every field-offset
# reader of it -- awk returned two numbers, not one. Measured here, not assumed.
#
# usage (as root):
#   sh wake-pair-worker.sh --mode continuous|wake [--duration S] [--burst N]
#                          [--sleep-s S] [--uid UID] [--cpuset PATH]
#
# prints one line to stdout when the worker is up:
#   WORKER tid=<tid> mode=<mode> uid=<uid> cpuset=<path>
# then waits for the worker and prints the burst count it completed:
#   BURSTS n=<count>
# The burst count is the throughput number the tracer's own overhead is measured
# against; it is written once, at the end, never inside the loop.

MODE=""
DURATION=12
BURST=1200
SLEEP_S=0.020
UID_=10999
CPUSET=/dev/cpuset/top-app/tasks
RUN=/data/local/tmp/op13-wake-pair
HELD=0

while [ $# -gt 0 ]; do
	case "$1" in
		--mode)     MODE=$2; shift 2 ;;
		--duration) DURATION=$2; shift 2 ;;
		--burst)    BURST=$2; shift 2 ;;
		--sleep-s)  SLEEP_S=$2; shift 2 ;;
		--uid)      UID_=$2; shift 2 ;;
		--cpuset)   CPUSET=$2; shift 2 ;;
		*) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
	esac
done

case "$MODE" in continuous|wake) ;; *) echo "ERROR: --mode must be continuous or wake" >&2; exit 2 ;; esac
case "$DURATION" in ''|*[!0-9]*) echo "ERROR: --duration must be an integer" >&2; exit 2 ;; esac
case "$BURST"    in ''|*[!0-9]*) echo "ERROR: --burst must be an integer" >&2; exit 2 ;; esac
case "$UID_"     in ''|*[!0-9]*) echo "ERROR: --uid must be an integer" >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 2; }
[ -w "$CPUSET" ] || { echo "ERROR: cannot write $CPUSET" >&2; exit 2; }

cleanup() {
	[ -f "$RUN/worker.pid" ] && kill "$(cat "$RUN/worker.pid")" 2>/dev/null
	[ -f "$RUN/writer.pid" ] && kill "$(cat "$RUN/writer.pid")" 2>/dev/null
	[ "$HELD" = 1 ] && rm -rf "$RUN"
	return 0
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 130' TERM

if ! mkdir "$RUN" 2>/dev/null; then
	if [ -f "$RUN/worker.pid" ] && [ -e "/proc/$(cat "$RUN/worker.pid" 2>/dev/null)/stat" ]; then
		echo "ERROR: a worker is already running as pid $(cat "$RUN/worker.pid")" >&2
		exit 3
	fi
	rm -rf "$RUN"; mkdir "$RUN" || { echo "ERROR: cannot create $RUN" >&2; exit 3; }
fi
HELD=1
chmod 777 "$RUN"

# The fifo sleep needs a writer that outlives every read, or the worker's first
# open() blocks forever. This was a hang in S1, not a hypothetical.
FIFO="$RUN/tick"
mknod "$FIFO" p 2>/dev/null || mkfifo "$FIFO" 2>/dev/null || {
	echo "ERROR: cannot create fifo $FIFO" >&2; exit 2; }
chmod 666 "$FIFO"
sleep 3600 > "$FIFO" &
echo $! > "$RUN/writer.pid"

cat > "$RUN/worker.sh" <<WORKER
echo \$\$ > "$RUN/worker.pid"
echo -n w-$MODE > /proc/self/comm
read _u _r < /proc/uptime
END=\$(( \${_u%.*} + $DURATION ))
n=0
if [ "$MODE" = continuous ]; then
	while :; do
		read _u _r < /proc/uptime
		[ \${_u%.*} -ge \$END ] && break
		i=0; while [ \$i -lt $BURST ]; do i=\$((i+1)); done
		n=\$((n+1))
	done
else
	while :; do
		read _u _r < /proc/uptime
		[ \${_u%.*} -ge \$END ] && break
		i=0; while [ \$i -lt $BURST ]; do i=\$((i+1)); done
		n=\$((n+1))
		read -t $SLEEP_S _x < "$FIFO"
	done
fi
echo \$n > "$RUN/bursts"
WORKER
chmod 777 "$RUN/worker.sh"

su "$UID_" -c "sh $RUN/worker.sh" &
SU_PID=$!

# the worker announces itself; the wrapper's pid is not the worker's
n=0
while [ ! -s "$RUN/worker.pid" ]; do
	n=$((n+1)); [ "$n" -gt 100 ] && { echo "ERROR: worker never reported a pid" >&2; exit 4; }
	read -t 0.05 _x < "$FIFO"
done
TID=$(cat "$RUN/worker.pid")
[ -e "/proc/$TID/stat" ] || { echo "ERROR: worker pid $TID is not alive" >&2; exit 4; }

echo "$TID" > "$CPUSET" || { echo "ERROR: could not move $TID into $CPUSET" >&2; exit 4; }
echo "WORKER tid=$TID mode=$MODE uid=$UID_ cpuset=$CPUSET burst=$BURST sleep_s=$SLEEP_S"

wait "$SU_PID"
echo "BURSTS n=$(cat "$RUN/bursts" 2>/dev/null)"
exit 0
