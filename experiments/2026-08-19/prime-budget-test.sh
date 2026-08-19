#!/system/bin/sh
# Is the prime cluster's sustained clock limited by a SHARED power budget?
#
# Same ceiling (3801600) both times; the only thing that changes is how many prime
# cores are loaded. PMU counts on cpu6 in both cases, so the comparison is exactly
# "what clock does cpu6 get when it is alone vs when cpu7 is also busy".
#
# shared budget -> cpu6's delivered GHz drops when cpu7 is loaded
# independent   -> cpu6's delivered GHz is the same either way
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
CFB=/sys/module/cpufreq_bouncing/parameters/enable
MID=2918400
C=3801600
UID_T=10999
TMP=/data/local/tmp/pb
CHUNK=300000
MAXCHUNK=400
DUR=35

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
WANT="0:$MID 1:$MID 2:$MID 3:$MID 4:$MID 5:$MID 6:$C 7:$C"

run() {  # run <nworkers> <label>
	N=$1
	printf '\n=== ceiling %s, %s prime core(s) loaded ===\n' "$C" "$N"
	c=0
	while [ $c -lt 75 ] || [ "$(jt)" -gt 50000 ]; do c=$((c+5)); sleep 5; [ $c -ge 240 ] && break; done
	echo "start $(( $(jt) / 1000 )) C"

	BIN=$TMP/p$N; cp /system/bin/sh "$BIN"; chmod 755 "$BIN"
	w=0
	while [ $w -lt $N ]; do
		su $UID_T -c "taskset $(( 1 << (6+w) )) $BIN -c 'k=0; while [ \$k -lt $MAXCHUNK ]; do i=0; while [ \$i -lt $CHUNK ]; do i=\$((i+1)); done; k=\$((k+1)); done'" &
		w=$((w+1))
	done
	sleep 3

	( taskset -p 3f $$ >/dev/null 2>&1
	  n=0
	  while [ $n -lt $(( (DUR + 15) * 4 )) ]; do
		echo "$WANT" > $NODE 2>/dev/null
		[ "$(cat $CFB)" != 0 ] && echo 0 > $CFB 2>/dev/null
		for p in $(survivors); do uclampset -a -M 1024 -p "$p" >/dev/null 2>&1; done
		n=$((n+1)); sleep 0.25
	  done ) &
	HOLD=$!
	sleep 5

	simpleperf stat -a --cpu 6 -e cpu-cycles,instructions --duration $DUR 2>&1 \
		| grep -vE '^$|Performance counter|Total test time'
	echo "end $(( $(jt) / 1000 )) C"
	kill -9 $HOLD 2>/dev/null
	kill_uid
}

run 1
run 2
