#!/system/bin/sh
# Mid-cluster ceiling experiment for op13perf.
#
# Changes ONLY EXTREME_P0 (the level-3 mid-cluster ceiling) in the module's conf
# and restarts its daemon, because perfd.sh sources conf once at startup.
# Everything else is untouched: the prime ceiling stays at EXTREME_P6=3513600 and
# the thermal gate stays at EXTREME_GATE=92000, so the owner's stated 92 C red
# line still governs the run.
#
# The original conf is copied to conf.bak-midexp on first use; "restore" puts it
# back. usage: sh set-midceil.sh <freq|restore>
NEW=$1
S=/data/adb/op13perf
M=/data/adb/modules/op13perf

[ -n "$NEW" ] || { echo "usage: set-midceil.sh <freq|restore>"; exit 2; }

[ -f "$S/conf.bak-midexp" ] || cp "$S/conf" "$S/conf.bak-midexp"

if [ "$NEW" = "restore" ]; then
	cp "$S/conf.bak-midexp" "$S/conf"
else
	# the value must be a real OPP step or the kernel snaps it down silently
	# (METHODOLOGY trap 3 / DATA.md section 39 instrument failure 3)
	grep -q -w "$NEW" /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies || {
		echo "REFUSED: $NEW is not in policy0 scaling_available_frequencies"; exit 3; }
	sed -i "s/^EXTREME_P0=.*/EXTREME_P0=$NEW/" "$S/conf"
fi

echo "conf now: $(grep '^EXTREME_P0=' $S/conf)  $(grep '^EXTREME_P6=' $S/conf)  $(grep '^EXTREME_GATE=' $S/conf)"

OLD=$(cat $S/pid 2>/dev/null)
pkill -f perfd.sh
sleep 1
nohup "$M/perfd.sh" >/dev/null 2>&1 &
echo $! > "$S/pid"
sleep 3
echo "daemon: old pid $OLD -> new pid $(cat $S/pid)"
echo 3 > "$S/state"
sleep 2
echo "status: $(cat $S/status)"
echo "p0max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) p6max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)"
echo "node: $(cat /sys/kernel/msm_performance/parameters/cpu_max_freq)"
