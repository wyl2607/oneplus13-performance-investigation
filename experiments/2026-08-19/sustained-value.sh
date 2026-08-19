#!/system/bin/sh
# Sustained-value comparison: which prime ceiling actually delivers the most WORK
# over a realistic window, once its own thermal pausing is charged against it?
#
# Peak clock is not the figure of merit -- a higher ceiling that spends 30% of the
# time paused can lose to a lower one that never pauses. Each point therefore
# measures completed work over a fixed duration, not time-to-finish.
#
# The harness replicates the module's own policy (4 Hz node re-assert, uclamp lift,
# CFB off, EMA-smoothed pause with hysteresis + dwell) so the result reflects what
# the module would actually give.
#
# TWO LEAK FIXES after the first attempt left two workers spinning at 100% for
# nine minutes of CPU time:
#   1. toybox `pkill -9 -u UID` with no PATTERN matches NOTHING and reports nothing.
#      Killing is now done by walking /proc and reading each task's real uid.
#   2. More importantly the workers are now SELF-LIMITING: they exit on their own
#      after MAXCHUNK chunks, so a teardown failure can no longer leak forever.

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
CFB=/sys/module/cpufreq_bouncing/parameters/enable
MID=2918400
DUR=150
CHUNK=300000
MAXCHUNK=700            # self-limit: ~350 s of work, comfortably past DUR
NWORK=2                 # pinned to cpu6,cpu7 -- the cluster whose ceiling we vary
HARD_ABORT=100000
START_C=52000
MIN_COOL=90
COOL_MAX=300
UID_T=10999
TMP=/data/local/tmp/sv
HYST=6000
DWELL=15

Z_J=""
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done
jt() { cat "$Z_J" 2>/dev/null || echo 0; }
now() { date +%s; }

# Kill by real uid read from /proc, not by pkill's pattern matching.
kill_uid() {
	n=0
	while [ $n -lt 12 ]; do
		FOUND=0
		for d in /proc/[0-9]*; do
			u=$(awk '/^Uid:/{print $2; exit}' "$d/status" 2>/dev/null)
			if [ "$u" = "$UID_T" ]; then
				kill -9 "${d#/proc/}" 2>/dev/null
				FOUND=1
			fi
		done
		[ "$FOUND" = 0 ] && return 0
		n=$((n+1)); sleep 1
	done
	return 1
}

survivors() {
	for d in /proc/[0-9]*; do
		u=$(awk '/^Uid:/{print $2; exit}' "$d/status" 2>/dev/null)
		[ "$u" = "$UID_T" ] && echo "${d#/proc/}"
	done
}

finish() {
	kill_uid
	S=$(survivors)
	rm -rf $TMP
	echo 2 > /data/adb/op13perf/state 2>/dev/null
	if [ -n "$S" ]; then
		echo "!!! LEAK: uid $UID_T still has pids: $S"
	else
		echo "### clean: no uid $UID_T processes remain"
	fi
	echo "### module returned to level 2"
}
trap finish EXIT INT TERM

echo 0 > /data/adb/op13perf/state
sleep 3
echo "### module parked; this script drives the levers itself"
rm -rf $TMP; mkdir -p $TMP; chmod 777 $TMP

point() {   # point <ceiling> <gate>
	C=$1; GATE=$2
	BIN=$TMP/w$C
	cp /system/bin/sh "$BIN"; chmod 755 "$BIN"
	rm -f $TMP/t_* $TMP/hard

	printf '\n=== ceiling %s  gate %s C ===\n' "$C" "$((GATE/1000))"

	# Every point starts from the same thermal state: a mandatory idle period AND
	# a temperature target, so the first point does not get an unfair cold start.
	c=0
	while [ $c -lt $MIN_COOL ] || [ "$(jt)" -gt "$START_C" ]; do
		c=$((c+5)); sleep 5
		if [ $c -ge $COOL_MAX ]; then
			echo "!!! cooldown failed at $(( $(jt) / 1000 )) C after ${c}s -- ABORTING"
			return 9
		fi
	done
	JSTART=$(jt)
	echo "start temp $((JSTART/1000)) C after ${c}s idle"

	WANT="0:$MID 1:$MID 2:$MID 3:$MID 4:$MID 5:$MID 6:$C 7:$C"
	R6=$(cat /sys/devices/system/cpu/cpufreq/policy6/cpuinfo_max_freq)
	R0=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)
	RATED="0:$R0 1:$R0 2:$R0 3:$R0 4:$R0 5:$R0 6:$R6 7:$R6"

	w=0
	while [ $w -lt $NWORK ]; do
		CPU=$((6 + w))
		su $UID_T -c "taskset $(( 1 << CPU )) $BIN -c 'k=0; while [ \$k -lt $MAXCHUNK ]; do i=0; while [ \$i -lt $CHUNK ]; do i=\$((i+1)); done; echo . >> $TMP/t_$w; k=\$((k+1)); done'" &
		w=$((w+1))
	done
	sleep 3

	# controller pinned OFF the prime cluster so it cannot hold the clock up
	taskset -p 3f $$ >/dev/null 2>&1
	T0=$(now); AVG=0; COOLING=0; COOL_AT=0
	NS=0; NPAUSE=0; JSUM=0; JMAX=0; JTAIL=0; NTAIL=0
	while [ $(( $(now) - T0 )) -lt $DUR ]; do
		J=$(jt)
		[ "$JMAX" -lt "$J" ] && JMAX=$J
		[ "$AVG" -eq 0 ] && AVG=$J
		AVG=$(( (AVG * 7 + J) / 8 ))

		if [ "$COOLING" = 0 ] && [ "$AVG" -gt "$GATE" ]; then
			COOLING=1; COOL_AT=$(now)
			echo "$RATED" > $NODE 2>/dev/null; echo 1 > $CFB 2>/dev/null
		elif [ "$COOLING" = 1 ] && [ "$AVG" -lt "$((GATE - HYST))" ] &&
		     [ $(( $(now) - COOL_AT )) -ge $DWELL ]; then
			COOLING=0
		fi

		if [ "$COOLING" = 0 ]; then
			echo "$WANT" > $NODE 2>/dev/null
			[ "$(cat $CFB)" != 0 ] && echo 0 > $CFB 2>/dev/null
			for p in $(survivors); do
				uclampset -a -M 1024 -p "$p" >/dev/null 2>&1
			done
		else
			NPAUSE=$((NPAUSE+1))
		fi

		NS=$((NS+1)); JSUM=$((JSUM + J))
		EL=$(( $(now) - T0 ))
		[ "$EL" -gt $((DUR - 60)) ] && { JTAIL=$((JTAIL + J)); NTAIL=$((NTAIL+1)); }

		if [ "$J" -gt "$HARD_ABORT" ]; then
			echo "!!! HARD ABORT at $((J/1000)) C"; touch $TMP/hard; break
		fi
		sleep 0.25
	done

	TICKS=0
	for f in $TMP/t_*; do
		[ -f "$f" ] && TICKS=$((TICKS + $(wc -l < "$f")))
	done
	kill_uid
	echo "$RATED" > $NODE 2>/dev/null

	PAUSEPCT=0; [ $NS -gt 0 ] && PAUSEPCT=$(( 100 * NPAUSE / NS ))
	JAVG=0; [ $NS -gt 0 ] && JAVG=$(( JSUM / NS ))
	JEQ=$JAVG; [ $NTAIL -gt 0 ] && JEQ=$(( JTAIL / NTAIL ))

	printf 'RESULT %s | work=%s | pause=%s%% | start %s C, mean %s C, last-60s %s C, peak %s C%s\n' \
		"$C" "$TICKS" "$PAUSEPCT" "$((JSTART/1000))" "$((JAVG/1000))" "$((JEQ/1000))" "$((JMAX/1000))" \
		"$([ -f $TMP/hard ] && echo '  [HARD ABORT]')"
	return 0
}

echo "sustained value: $NWORK prime-pinned workers, ${DUR}s per point, mid pinned $MID"
point 3283200 95000 || exit 1
point 3513600 95000 || exit 1
point 3801600 97000 || exit 1
