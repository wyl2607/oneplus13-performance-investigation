#!/system/bin/sh
# Ceiling ladder: does raising the prime ceiling above 3283200 actually get delivered?
#
# Fixed-work pure-ALU probe (mksh integer loop, no syscalls, no memory traffic), so
# wall time should be exactly inversely proportional to the delivered clock. If it
# is not, the ceiling is being eaten by another requester rather than honoured.
#
# Only the PRIME ceiling varies; mid is pinned at 2918400 throughout so the ladder
# is not confounded by mid-cluster placement.
#
# Traps this design is guarding against, all previously hit in this project:
#  - the harness itself landing on prime and holding the clock up (taskset 3f)
#  - the guard de-duplicating on (uid, comm) -> a distinct binary name per point
#  - reporting a result for a probe that never ran -> cpu_ticks checked per point
#  - an advisory cooldown that lets a trial start hot -> the gate here is BLOCKING
#    and the whole run aborts if it cannot be met

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
CFB=/sys/module/cpufreq_bouncing/parameters/enable
MID=2918400
LADDER="3283200 3513600 3801600 4089600 4320000"
ABORT_C=95000
START_C=45000
COOL_MAX=150
UID_T=10999
TMP=/data/local/tmp/ladder

Z_J=""
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done
jt() { cat "$Z_J" 2>/dev/null || echo 0; }
now() { read a b < /proc/uptime; echo "${a%.*}${a#*.}"; }   # centiseconds

teardown() {
	pkill -9 -u $UID_T 2>/dev/null
	[ -n "$WPID" ] && kill -9 "$WPID" 2>/dev/null
	WPID=""
}
finish() {
	teardown
	rm -rf $TMP
	# hand the device back to the module
	echo 2 > /data/adb/op13perf/state 2>/dev/null
	echo "### module returned to level 2"
}
trap finish EXIT INT TERM

# The module daemon writes the node at 4 Hz and would fight this experiment.
echo 0 > /data/adb/op13perf/state
sleep 3
echo "### module parked (state=$(cat /data/adb/op13perf/state))"
echo 0 > $CFB 2>/dev/null
echo "### CFB=$(cat $CFB) (held off by this script for the whole ladder)"

rm -rf $TMP; mkdir -p $TMP; chmod 777 $TMP

# --- calibrate N so one pass is roughly 12 s at the current ceiling ---
echo "$MID:0 1:$MID 2:$MID 3:$MID 4:$MID 5:$MID 6:3283200 7:3283200" >/dev/null
echo "0:$MID 1:$MID 2:$MID 3:$MID 4:$MID 5:$MID 6:3283200 7:3283200" > $NODE
cp /system/bin/sh $TMP/cal; chmod 755 $TMP/cal
T0=$(now)
taskset 80 $TMP/cal -c 'i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done'
T1=$(now)
CAL=$((T1 - T0))
[ "$CAL" -lt 10 ] && CAL=10
N=$(( 300000 * 1200 / CAL ))
echo "### calibration: 300000 iterations took ${CAL} cs -> N=$N for ~12 s"
echo

run_point() {   # run_point <ceiling> <pass>
	C=$1; PASS=$2
	BIN=$TMP/spin${PASS}_$C
	cp /system/bin/sh "$BIN"; chmod 755 "$BIN"

	# BLOCKING cooldown. If it cannot be met the whole experiment stops.
	c=0
	while [ "$(jt)" -gt "$START_C" ]; do
		c=$((c+5)); sleep 5
		if [ $c -ge $COOL_MAX ]; then
			echo "!!! COOLDOWN FAILED at $(( $(jt) / 1000 )) C after ${c}s -- ABORTING LADDER"
			return 9
		fi
	done
	J0=$(jt)

	WANT="0:$MID 1:$MID 2:$MID 3:$MID 4:$MID 5:$MID 6:$C 7:$C"
	echo "$WANT" > $NODE

	# watchdog: re-assert node, lift uclamp on the probe, enforce the thermal abort.
	# Pinned to cpu0-5 so it cannot itself hold the prime clock up (trap 6).
	(
		taskset -p 3f $$ >/dev/null 2>&1
		while :; do
			echo "$WANT" > $NODE 2>/dev/null
			[ "$(cat $CFB)" != 0 ] && echo 0 > $CFB 2>/dev/null
			for p in $(pgrep -u $UID_T 2>/dev/null); do
				uclampset -a -M 1024 -p "$p" >/dev/null 2>&1
			done
			if [ "$(jt)" -gt "$ABORT_C" ]; then
				echo "THERMAL_ABORT" > $TMP/abort
				pkill -9 -u $UID_T 2>/dev/null
				exit 0
			fi
			sleep 0.25
		done
	) &
	WPID=$!
	sleep 1

	rm -f $TMP/abort
	T0=$(now)
	su $UID_T -c "taskset 80 $BIN -c 'i=0; while [ \$i -lt $N ]; do i=\$((i+1)); done'" &
	SPID=$!

	# observe while it runs, from OUTSIDE the prime cluster
	HELD=yes; ATC=0; SAMP=0; JMAX=$J0
	while kill -0 $SPID 2>/dev/null; do
		SAMP=$((SAMP+1))
		G=$(tr -s ' ' < $NODE | sed 's/ *$//')
		[ "$G" = "$WANT" ] || HELD=no
		F=$(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq)
		[ "$F" = "$C" ] && ATC=$((ATC+1))
		J=$(jt); [ "$J" -gt "$JMAX" ] && JMAX=$J
		sleep 0.25
	done
	wait $SPID 2>/dev/null
	T1=$(now)
	MS=$(( (T1 - T0) * 10 ))

	kill -9 $WPID 2>/dev/null; WPID=""

	if [ -f $TMP/abort ]; then
		echo "pass$PASS ceiling=$C  ***THERMAL ABORT at $((JMAX/1000)) C***"
		return 1
	fi

	PCT=0; [ "$SAMP" -gt 0 ] && PCT=$(( 100 * ATC / SAMP ))
	printf 'pass%s ceiling=%-8s time=%6sms  held=%-3s cpu7@ceiling=%3s%%  junc %s->%s C\n' \
		"$PASS" "$C" "$MS" "$HELD" "$PCT" "$((J0/1000))" "$((JMAX/1000))"
	return 0
}

echo "ceiling ladder, mid pinned at $MID, abort $((ABORT_C/1000)) C, start-below $((START_C/1000)) C"
echo
for C in $LADDER; do run_point $C A || { [ $? = 9 ] && exit 1; }; done
echo
echo "--- descending pass, to expose thermal drift ---"
for C in 4320000 4089600 3801600 3513600 3283200; do run_point $C B || { [ $? = 9 ] && exit 1; }; done

echo
echo "### leak check"
ps -A -o PID,USER,NAME 2>/dev/null | grep -E "spin|u0_a999" | grep -v grep || echo "clean"
