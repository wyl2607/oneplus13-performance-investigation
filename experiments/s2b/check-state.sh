#!/system/bin/sh
for z in /sys/class/thermal/thermal_zone*; do
	t=$(cat "$z/type" 2>/dev/null)
	[ "$t" = "cpu-1-1-1" ] && echo "junction_c=$(awk '{printf "%.1f", $1/1000}' "$z/temp")"
done
echo "perfd_running=$(ps -A | grep -c perfd)"
echo "cfb_enable=$(cat /sys/module/cpufreq_bouncing/parameters/enable)"
