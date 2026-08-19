#!/system/bin/sh
# The sustained-value test found near-identical throughput at 3283200 / 3513600 /
# 3801600 (468 / 475 / 470 chunks) while the 11 s burst ladder scaled perfectly.
# Inference: under sustained load the SoC settles well below the ceiling, so the
# ceiling stops mattering. That inference is worth measuring directly rather than
# deducing from chunk rates -- log the ACTUAL cpu6/cpu7 frequency under load.
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
CFB=/sys/module/cpufreq_bouncing/parameters/enable
MID=2918400
UID_T=10999
TMP=/data/local/tmp/sf
DUR=70
CHUNK=300000
MAXCHUNK=400

Z_J=""
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done
jt() { cat "$Z_J" 2>/dev/null || echo 0; }
now() { date +%s; }

kill_uid() {
	n=0
	while [ $n -lt 12 ]; do
		F=0
		for d in /proc/[0-9]*; do
			u=$(awk '/^Uid:/{print $2; exit}' "$d/status" 2>/dev/null)
			[ "$u" = "$UID_T" ] && { kill -9 "${d#/proc/}" 2>/dev/null; F=1; }
		done
		[ "$F" = 0 ] && return 0
		n=$((n+1)); sleep 1
	done
}
survivors() { for d in /proc/[0-9]*; do
		u=$(awk '/^Uid:/{print $2; exit}' "$d/status" 2>/dev/null)
		[ "$u" = "$UID_T" ] && echo "${d#/proc/}"; done; }
finish() { kill_uid; rm -rf $TMP; echo 2 > /data/adb/op13perf/state 2>/dev/null
	S=$(survivors); [ -n "$S" ] && echo "!!! LEAK: $S" || echo "### clean"; }
trap finish EXIT INT TERM

echo 0 > /data/adb/op13perf/state; sleep 3
rm -rf $TMP; mkdir -p $TMP; chmod 777 $TMP

run() {  # run <ceiling>
	C=$1
	printf '\n=== sustained frequency at ceiling %s ===\n' "$C"
	c=0
	while [ $c -lt 60 ] || [ "$(jt)" -gt 52000 ]; do c=$((c+5)); sleep 5; [ $c -ge 240 ] && break; done
	echo "start $(( $(jt) / 1000 )) C"

	BIN=$TMP/f$C; cp /system/bin/sh "$BIN"; chmod 755 "$BIN"
	WANT="0:$MID 1:$MID 2:$MID 3:$MID 4:$MID 5:$MID 6:$C 7:$C"
	w=0
	while [ $w -lt 2 ]; do
		su $UID_T -c "taskset $(( 1 << (6+w) )) $BIN -c 'k=0; while [ \$k -lt $MAXCHUNK ]; do i=0; while [ \$i -lt $CHUNK ]; do i=\$((i+1)); done; k=\$((k+1)); done'" &
		w=$((w+1))
	done
	sleep 3
	taskset -p 3f $$ >/dev/null 2>&1

	T0=$(now); N=0; SUM6=0; SUM7=0; ATC=0; JM=0
	while [ $(( $(now) - T0 )) -lt $DUR ]; do
		echo "$WANT" > $NODE 2>/dev/null
		[ "$(cat $CFB)" != 0 ] && echo 0 > $CFB 2>/dev/null
		for p in $(survivors); do uclampset -a -M 1024 -p "$p" >/dev/null 2>&1; done
		F6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq)
		F7=$(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq)
		J=$(jt); [ "$J" -gt "$JM" ] && JM=$J
		# ignore the first 10 s so the average is the SETTLED clock, not the ramp
		if [ $(( $(now) - T0 )) -gt 10 ]; then
			N=$((N+1)); SUM6=$((SUM6+F6)); SUM7=$((SUM7+F7))
			[ "$F6" = "$C" ] && ATC=$((ATC+1))
		fi
		sleep 0.25
	done
	kill_uid
	printf 'ceiling %-8s settled cpu6 %s  cpu7 %s  at-ceiling %s%%  peak %s C\n' \
		"$C" "$((SUM6/N))" "$((SUM7/N))" "$((100*ATC/N))" "$((JM/1000))"
}

run 3283200
run 3801600
