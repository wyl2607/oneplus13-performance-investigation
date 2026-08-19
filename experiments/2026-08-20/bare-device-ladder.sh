#!/system/bin/sh
# Bare-device sustained ladder -- NO 40 W cooler attached.
#
# Every number in DATA.md section 39 was taken with the cooler on, so the module's
# level 1 and level 2 were shipped as reasoned guesses. This measures them.
#
# Derived from experiments/2026-08-19/sustained-value.sh, which is where the harness
# design, the two leak fixes and the EMA pause logic come from. Four changes:
#   1. mid frequency is per-point, because level 1 runs a lower mid (2400000) than
#      the other levels and the mid cluster is where most of a bare device's heat
#      actually comes from.
#   2. a STOCK point that applies no levers at all, so "is the module worth running
#      bare" has a measured answer rather than an assumed one.
#   3. the points are the module's real levels, gates included, rather than a sweep
#      of ceilings -- the question is which level to run bare, not where the silicon
#      ceiling is.
#   4. teardown returns the module to level 1, the bare-device default.
#
# Figure of merit is completed WORK over a fixed window with the level's own thermal
# pausing charged against it. A ceiling that spends 30% of the window paused can lose
# to a lower one that never pauses -- which is the entire question for a bare device.

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
CFB=/sys/module/cpufreq_bouncing/parameters/enable
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
	echo 1 > /data/adb/op13perf/state 2>/dev/null
	if [ -n "$S" ]; then
		echo "!!! LEAK: uid $UID_T still has pids: $S"
	else
		echo "### clean: no uid $UID_T processes remain"
	fi
	echo "### module returned to level 1 (bare-device default)"
}
trap finish EXIT INT TERM

echo 0 > /data/adb/op13perf/state
sleep 3
echo "### module parked; this script drives the levers itself"
rm -rf $TMP; mkdir -p $TMP; chmod 777 $TMP

point() {   # point <label> <ceiling> <mid> <gate>   -- ceiling "stock" applies no levers
	LBL=$1; C=$2; MID=$3; GATE=$4
	STOCK=0; [ "$C" = "stock" ] && STOCK=1
	BIN=$TMP/w$LBL
	cp /system/bin/sh "$BIN"; chmod 755 "$BIN"
	rm -f $TMP/t_* $TMP/hard

	if [ "$STOCK" = 1 ]; then
		printf '\n=== %s  (no levers applied) ===\n' "$LBL"
	else
		printf '\n=== %s  ceiling %s  mid %s  gate %s C ===\n' "$LBL" "$C" "$MID" "$((GATE/1000))"
	fi

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

		if [ "$STOCK" = 0 ]; then
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
	[ "$STOCK" = 0 ] && echo "$RATED" > $NODE 2>/dev/null

	PAUSEPCT=0; [ $NS -gt 0 ] && PAUSEPCT=$(( 100 * NPAUSE / NS ))
	JAVG=0; [ $NS -gt 0 ] && JAVG=$(( JSUM / NS ))
	JEQ=$JAVG; [ $NTAIL -gt 0 ] && JEQ=$(( JTAIL / NTAIL ))

	printf 'RESULT %-11s | work=%s | pause=%s%% | start %s C, mean %s C, last-60s %s C, peak %s C%s\n' \
		"$LBL" "$TICKS" "$PAUSEPCT" "$((JSTART/1000))" "$((JAVG/1000))" "$((JEQ/1000))" "$((JMAX/1000))" \
		"$([ -f $TMP/hard ] && echo '  [HARD ABORT]')"
	return 0
}

echo "BARE DEVICE (no cooler): $NWORK prime-pinned workers, ${DUR}s per point"
echo "stock runs first so the comparison is not read against a device already soaked."
point stock     stock   0       0     || exit 1
point daily     2841600 2400000 88000 || exit 1
point perf      3283200 2918400 90000 || exit 1
point extreme   3513600 2918400 92000 || exit 1
