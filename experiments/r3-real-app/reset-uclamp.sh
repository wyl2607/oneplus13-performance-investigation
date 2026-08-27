#!/system/bin/sh
# ad-hoc emergency reset, not part of the harness -- resets uclamp.min=0 on
# every thread of a given pid, used to clear R3 smoke-test contamination.
PID="$1"
for t in $(ls /proc/$PID/task 2>/dev/null); do
	uclampset -m 0 -p "$t" 2>/dev/null
done
echo "reset done for pid $PID"
