#!/system/bin/sh
# Resolve the open anomaly: at ceiling 3801600 the sustained clock measured ~4.6%
# higher than at 3283200, yet 150 s of work came out flat. Either the core is not
# really running faster, or it is running faster while stalled on something outside
# the core (DSU / L3 / memory).
#
# PMU counters settle it in one internally-consistent measurement:
#   cpu-cycles / second   = the frequency ACTUALLY delivered (better than sampling
#                           scaling_cur_freq, which reports the request)
#   instructions / second = the work actually done
#   stall_backend_mem     = cycles lost waiting on memory outside the core
#
# core-bound  -> instructions/s rises with cycles/s, stall fraction flat
# outside-core-> cycles/s rises, instructions/s flat, stall fraction rises
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
CFB=/sys/module/cpufreq_bouncing/parameters/enable
MID=2918400
UID_T=10999
TMP=/data/local/tmp/ds
CHUNK=300000
MAXCHUNK=400
DUR=40

Z_J=""
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done
jt() { cat "$Z_J" 2>/dev/null || echo 0; }

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

point() {  # point <ceiling>
	C=$1
	printf '\n=== ceiling %s ===\n' "$C"
	c=0
	while [ $c -lt 60 ] || [ "$(jt)" -gt 52000 ]; do c=$((c+5)); sleep 5; [ $c -ge 240 ] && break; done
	echo "start $(( $(jt) / 1000 )) C"

	BIN=$TMP/d$C; cp /system/bin/sh "$BIN"; chmod 755 "$BIN"
	WANT="0:$MID 1:$MID 2:$MID 3:$MID 4:$MID 5:$MID 6:$C 7:$C"

	# one worker, pinned to cpu6 only, so a cpu6-scoped PMU count is exactly it
	su $UID_T -c "taskset 40 $BIN -c 'k=0; while [ \$k -lt $MAXCHUNK ]; do i=0; while [ \$i -lt $CHUNK ]; do i=\$((i+1)); done; k=\$((k+1)); done'" &
	sleep 3

	# hold the levers from cpu0-5 while perf counts on cpu6
	( taskset -p 3f $$ >/dev/null 2>&1
	  n=0
	  while [ $n -lt $(( (DUR + 15) * 4 )) ]; do
		echo "$WANT" > $NODE 2>/dev/null
		[ "$(cat $CFB)" != 0 ] && echo 0 > $CFB 2>/dev/null
		for p in $(survivors); do uclampset -a -M 1024 -p "$p" >/dev/null 2>&1; done
		n=$((n+1)); sleep 0.25
	  done ) &
	HOLD=$!
	sleep 5   # let the clock settle before counting

	simpleperf stat -a --cpu 6 \
		-e cpu-cycles,instructions,armv8_pmuv3/stall_backend_mem/ \
		--duration $DUR 2>&1 | grep -vE '^$|Performance counter|Total test time'

	echo "end temp $(( $(jt) / 1000 )) C, requested $(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq)"
	kill -9 $HOLD 2>/dev/null
	kill_uid
}

point 3283200
point 3801600
