#!/system/bin/sh
# Survey every DSU / L3 / DDR / memlat knob that could explain why a 4.6% higher
# sustained prime clock produced no extra work. Read-only.

echo "=== /proc/game_opt ==="
for f in /proc/game_opt/*; do
	printf '%-46s = %s\n' "$f" "$(cat "$f" 2>&1 | head -1)"
done

echo
echo "=== devfreq devices ==="
for d in /sys/class/devfreq/*; do
	[ -e "$d" ] || continue
	echo "--- $(basename $d)"
	printf '  governor=%s cur=%s min=%s max=%s\n' \
		"$(cat $d/governor 2>/dev/null)" "$(cat $d/cur_freq 2>/dev/null)" \
		"$(cat $d/min_freq 2>/dev/null)" "$(cat $d/max_freq 2>/dev/null)"
	AF=$(cat $d/available_frequencies 2>/dev/null)
	[ -n "$AF" ] && echo "  avail=$AF"
done

echo
echo "=== anything named dsu / l3 / llcc / ddr in sysfs (bounded search) ==="
ls -d /sys/devices/system/cpu/cpu*/cpufreq 2>/dev/null | head -2
for p in /sys/class/devfreq /sys/kernel/dsu /sys/module/qcom_dsu* /sys/devices/platform/soc/*dsu*; do
	[ -e "$p" ] && echo "exists: $p"
done
find /sys/devices/platform/soc -maxdepth 1 -iname '*llcc*' -o -maxdepth 1 -iname '*ddr*' 2>/dev/null | head -10

echo
echo "=== bus/memlat governors that clamp L3 with the CPU ==="
for d in /sys/class/devfreq/*; do
	b=$(basename $d)
	case "$b" in
		*llcc*|*l3*|*ddr*|*memlat*|*bw*|*cpu*)
			echo "--- $b: polling=$(cat $d/polling_interval 2>/dev/null) trans=$(cat $d/trans_stat 2>/dev/null | head -3 | tail -1)" ;;
	esac
done

echo
echo "=== is there a DSU cpufreq-like policy? ==="
ls /sys/devices/system/cpu/cpufreq/ 2>/dev/null

echo
echo "=== fqm_dump requesters mentioning dsu/l3 ==="
grep -iE 'dsu|l3|llcc' /proc/oplus_freqreq_monitor/fqm_dump 2>/dev/null | head -5 || echo "none"
echo "=== DONE ==="
