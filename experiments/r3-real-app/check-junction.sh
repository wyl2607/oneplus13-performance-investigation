#!/system/bin/sh
# ad-hoc host-driver helper, not part of the harness -- prints the cpu-1-1-1
# junction thermal zone's current temp (milli-C).
for z in /sys/class/thermal/thermal_zone*; do
	t=$(cat "$z/type" 2>/dev/null)
	if [ "$t" = "cpu-1-1-1" ]; then
		cat "$z/temp"
		exit 0
	fi
done
