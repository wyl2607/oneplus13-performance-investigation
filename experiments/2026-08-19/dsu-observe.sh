#!/system/bin/sh
# Can DSU / L3 frequency be OBSERVED at all? Without a readback any dsu_freq
# experiment is blind, so establish observability before touching anything.
echo "=== is debugfs mounted? ==="
mount | grep -i debugfs || echo "not mounted"
ls /sys/kernel/debug/ 2>&1 | head -5

echo
echo "=== clk_summary (would list every clock incl. DSU) ==="
if [ -r /sys/kernel/debug/clk/clk_summary ]; then
	grep -iE 'dsu|l3|gold|prime|cpu' /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -20
else
	echo "unreadable"
fi

echo
echo "=== llcc-pmu ==="
ls -R /sys/devices/platform/soc/24095000.llcc-pmu 2>/dev/null | head -20

echo
echo "=== bwmon-llcc-prime / gold ==="
for d in /sys/devices/platform/soc/240b7400.qcom,bwmon-llcc-prime /sys/devices/platform/soc/240b3400.qcom,bwmon-llcc-gold; do
	echo "--- $d"
	ls "$d" 2>/dev/null | head -12
done

echo
echo "=== ddr-cdev ==="
ls /sys/devices/platform/soc/soc:qcom,ddr-cdev 2>/dev/null | head -12
for f in /sys/devices/platform/soc/soc:qcom,ddr-cdev/*; do
	[ -f "$f" ] && printf '  %s = %s\n' "$(basename $f)" "$(cat "$f" 2>&1 | head -1)"
done

echo
echo "=== cooling devices (ddr / llcc / cpu appear here as cdevs) ==="
for c in /sys/class/thermal/cooling_device*; do
	t=$(cat $c/type 2>/dev/null)
	case "$t" in *ddr*|*llcc*|*l3*|*cpu*) printf '%-28s cur=%s max=%s\n' "$t" "$(cat $c/cur_state 2>/dev/null)" "$(cat $c/max_state 2>/dev/null)";; esac
done | head -20

echo
echo "=== dsu_freq node permissions and write probe (no write yet) ==="
ls -l /proc/game_opt/dsu_freq
echo "current value: $(cat /proc/game_opt/dsu_freq)"
echo "game_pid state: $(cat /proc/game_opt/game_pid)"
echo "=== DONE ==="
