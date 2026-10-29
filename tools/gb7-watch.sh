#!/system/bin/sh
#
# gb7-watch.sh - passive observer for a benchmark run.
#
# STRICTLY READ-ONLY with respect to kernel state: it writes nothing to /proc,
# /sys, any module parameter or the op13perf state. It only reads, and appends
# to its own output file.
#
# The module does the work; this watches, so that a run can be checked against
# what the levers ACTUALLY did rather than what they were asked to do. Section
# 39's instrument failure 1 is the reason that distinction is load-bearing.
#
# usage:
#   adb push tools/gb7-watch.sh /data/local/tmp/
#   adb shell su -M -c 'nohup sh /data/local/tmp/gb7-watch.sh 700 /data/local/tmp/run.txt >/dev/null 2>&1 &'
#
# Sampling is whatever a round of 15 `cat`s costs on this shell -- about 1.5 Hz,
# not the nominal 2 Hz. That is fine for ceilings and thermals and far too coarse
# for placement; use tools/scheduler-event-tracer.sh for anything event-level.
#
# Privacy: this deliberately does NOT dump /proc/task_overload/abnormal_task,
# which carries app uids and thread names (see docs/PRIVACY.md). It records the
# clamped-row COUNT only, which is all the analysis needs.

MAX_S=${1:-600}
OUT=${2:-/data/local/tmp/gb7-watch.txt}
ST=/data/adb/op13perf/status
CFB=/sys/module/cpufreq_bouncing/parameters/enable

# Zones are resolved BY NAME, never by index (METHODOLOGY trap 3).
Z_J=""; Z_S=""
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ]   && Z_J="$z/temp"
	[ "$t" = "shell_front" ] && Z_S="$z/temp"
done

{
echo "# started $(date '+%F %T')  level/status: $(cat $ST 2>/dev/null)"
echo "# p6max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq) p0max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) cfb=$(cat $CFB 2>/dev/null)"
echo "# node=$(cat /sys/kernel/msm_performance/parameters/cpu_max_freq 2>/dev/null)"
echo "ts|c0|c1|c2|c3|c4|c5|c6|c7|p0max|p6max|junc|shell|cfb|cool"
} > "$OUT"

i=0; N=$((MAX_S * 2))
while [ $i -lt $N ]; do
	S=$(cat $ST 2>/dev/null)
	COOL=no; case "$S" in *cooling*|*STEPPED-DOWN*) COOL=yes ;; esac
	printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$(date +%s)" \
		"$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu3/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu5/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)" \
		"$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)" \
		"$(cat $Z_J 2>/dev/null)" "$(cat $Z_S 2>/dev/null)" \
		"$(cat $CFB 2>/dev/null)" "$COOL" >> "$OUT"
	i=$((i+1)); sleep 0.5
done

{
echo "### clamped rows in abnormal_task at end (count only, see PRIVACY.md):"
awk 'NR>1 && $3 != 1024 {n++} END {print (n+0)}' /proc/task_overload/abnormal_task 2>/dev/null
echo "### module log tail:"
tail -15 /data/adb/op13perf/log 2>/dev/null
} >> "$OUT"
