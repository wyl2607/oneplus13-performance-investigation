#!/system/bin/sh
# Passive observer for a GB7 run at EXTREME_P6=3513600. The module does the work;
# this only watches. The question is whether the higher peak clock beats the extra
# thermal pausing it causes, so the thing to measure is the PAUSE DUTY CYCLE.
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
ST=/data/adb/op13perf/status
MAX_S=900

Z_J=""
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done

echo "# extreme ceiling now: $(grep ^EXTREME_P6 /data/adb/op13perf/conf)"
echo "# gate: $(grep ^EXTREME_GATE /data/adb/op13perf/conf)"
echo "ts|state|p6cur|p7cur|p0cur|p6max|junc|cooling"

i=0
while [ $i -lt $((MAX_S * 2)) ]; do
	S=$(cat $ST 2>/dev/null)
	COOL=no
	case "$S" in cooling*) COOL=yes ;; esac
	printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
		"$(date +%s)" "$(echo "$S" | cut -c1-28)" \
		"$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)" \
		"$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)" \
		"$(cat $Z_J 2>/dev/null)" "$COOL"
	i=$((i+1)); sleep 0.5
done
echo "### module log:"; tail -25 /data/adb/op13perf/log
