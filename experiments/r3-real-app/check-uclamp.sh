#!/system/bin/sh
# ad-hoc residue check, not part of the harness -- reads back uclamp.min for
# every thread of a given pid, to confirm 512 clamps were reset after cleanup.
PID="$1"
for t in $(ls /proc/$PID/task 2>/dev/null); do
	R=$(uclampset -p "$t" 2>/dev/null)
	echo "$t: $R"
done
