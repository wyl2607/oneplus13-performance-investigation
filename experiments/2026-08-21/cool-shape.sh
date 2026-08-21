#!/system/bin/sh
# Where the step-down's penalty should land.
#
# daily-return-curve.sh found that under an eight-core load NO ceiling is the
# active constraint: every level above the daily one ran at the same clocks and
# the same work, and d-mid1/d-mid2 spent 100 % of the window stepped down. What
# does bind is the step-down target itself -- at COOL the mid cluster sat exactly
# on COOL_P0 (2227200) while the prime cluster sat at 2438400, well under its
# COOL_P6 of 2649600. So the prime ceiling in the retreat does nothing and the
# mid ceiling costs six cores' worth of throughput.
#
# This measures the retreat's SHAPE directly. The gate is parked at 96 C so it
# never fires and every point runs at a fixed pair of ceilings; the hardware's
# own thermal limiter is left to do whatever it does, which is the condition a
# real retreat runs under anyway.
#
# s-anchor doubles as a cross-run tie: it is the daily level's own pair, measured
# without the gate that made d-base spend 28 % of its window elsewhere.

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
CFB=/sys/module/cpufreq_bouncing/parameters/enable
DUR=150
CHUNK=300000
MAXCHUNK=2000           # self-limit only; 150 s ends the point long before this
HARD_ABORT=100000
START_C=52000
MIN_COOL=90
COOL_MAX=360
UID_T=10999
TMP=/data/local/tmp/cs
HYST=6000
DWELL=15
# The module's step-down lowers the CEILING to these and keeps both levers on.
# experiments/2026-08-20 wrote the rated maxima and handed CFB back instead --
# that is a full release, which is what op13perf/README.md still describes and
# what perfd.sh stopped doing. Measuring a step-down cost with a release harness
# would charge the level for something the module never does.
COOL_P6=2649600
COOL_P0=2227200
OUT=/data/local/tmp/cool-shape.txt
LOCK=/data/local/tmp/cs.lock

Z_J=""
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done
jt() { cat "$Z_J" 2>/dev/null || echo 0; }
now() { date +%s; }
say() { echo "$*"; echo "$*" >> $OUT; }

# Kill by real uid read from /proc. pkill -u with no pattern kills nothing under
# toybox and pgrep -x misses because comm truncates at 15 chars -- both cost this
# project a leaked spinner before.
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
	rm -rf $LOCK
	echo 1 > /data/adb/op13perf/state 2>/dev/null
	if [ -n "$S" ]; then
		say "!!! LEAK: uid $UID_T still has pids: $S"
	else
		say "### clean: no uid $UID_T processes remain"
	fi
	say "### module returned to level 1"
}

# A signal handler that only cleans up does NOT end the script: sh runs the
# handler and then RESUMES at the line the signal interrupted. Killing this
# script with TERM printed a clean teardown and left it running -- two instances
# then shared one frequency node, one output file, and killed each other's
# workers for six minutes, producing two contradictory stock results. The handler
# has to exit, and something has to stop a second instance from starting at all.
on_signal() { finish; trap - EXIT; exit 143; }
trap on_signal INT TERM
trap finish EXIT

if mkdir "$LOCK" 2>/dev/null; then
	echo $$ > "$LOCK/pid"
else
	read OP < "$LOCK/pid" 2>/dev/null
	if [ -n "$OP" ] && [ -d "/proc/$OP" ]; then
		echo "refusing to start: instance $OP is already running"
		trap - EXIT INT TERM
		exit 2
	fi
	echo "taking over a stale lock from pid ${OP:-?}"
	echo $$ > "$LOCK/pid"
fi

: > $OUT
echo 0 > /data/adb/op13perf/state
sleep 3
say "### module parked; this script drives the levers itself"
rm -rf $TMP; mkdir -p $TMP; chmod 777 $TMP

point() {   # point <label> <p6> <p0> <gate>   -- p6 "stock" applies no levers
	LBL=$1; C=$2; MID=$3; GATE=$4
	STOCK=0; [ "$C" = "stock" ] && STOCK=1
	BIN=$TMP/w$LBL
	cp /system/bin/sh "$BIN"; chmod 755 "$BIN"
	rm -f $TMP/t_* $TMP/hard

	if [ "$STOCK" = 1 ]; then
		say ""
		say "=== $LBL  (no levers: URCC inversion and the uclamp guard both left in place) ==="
	else
		say ""
		say "=== $LBL  p6 $C  p0 $MID  gate $((GATE/1000)) C ==="
	fi

	c=0
	while [ $c -lt $MIN_COOL ] || [ "$(jt)" -gt "$START_C" ]; do
		c=$((c+5)); sleep 5
		if [ $c -ge $COOL_MAX ]; then
			say "!!! cooldown failed at $(( $(jt) / 1000 )) C after ${c}s -- ABORTING"
			return 9
		fi
	done
	JSTART=$(jt)
	say "start temp $((JSTART/1000)) C after ${c}s idle"

	WANT="0:$MID 1:$MID 2:$MID 3:$MID 4:$MID 5:$MID 6:$C 7:$C"
	COOLW="0:$COOL_P0 1:$COOL_P0 2:$COOL_P0 3:$COOL_P0 4:$COOL_P0 5:$COOL_P0 6:$COOL_P6 7:$COOL_P6"
	R6=$(cat /sys/devices/system/cpu/cpufreq/policy6/cpuinfo_max_freq)
	R0=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)
	RATED="0:$R0 1:$R0 2:$R0 3:$R0 4:$R0 5:$R0 6:$R6 7:$R6"

	# one worker per core, cpu0..cpu7
	w=0
	while [ $w -lt 8 ]; do
		su $UID_T -c "taskset $(( 1 << w )) $BIN -c 'k=0; while [ \$k -lt $MAXCHUNK ]; do i=0; while [ \$i -lt $CHUNK ]; do i=\$((i+1)); done; echo . >> $TMP/t_$w; k=\$((k+1)); done'" &
		w=$((w+1))
	done
	sleep 3

	T0=$(now); AVG=0; COOLING=0; COOL_AT=0
	NS=0; NPAUSE=0; JSUM=0; JMAX=0; JTAIL=0; NTAIL=0
	# Sample what the clusters ACTUALLY ran at. A ceiling is a request; the
	# self-test showed stock prime cores out-working mid cores by 70 %, which is
	# the opposite of what the URCC inversion predicts, and no amount of staring
	# at the ceiling settles that. Sampled once a second over the tail window.
	F6SUM=0; F0SUM=0; NF=0
	while [ $(( $(now) - T0 )) -lt $DUR ]; do
		J=$(jt)
		[ "$JMAX" -lt "$J" ] && JMAX=$J
		[ "$AVG" -eq 0 ] && AVG=$J
		AVG=$(( (AVG * 7 + J) / 8 ))

		if [ "$STOCK" = 0 ]; then
			if [ "$COOLING" = 0 ] && [ "$AVG" -gt "$GATE" ]; then
				COOLING=1; COOL_AT=$(now)
			elif [ "$COOLING" = 1 ] && [ "$AVG" -lt "$((GATE - HYST))" ] &&
			     [ $(( $(now) - COOL_AT )) -ge $DWELL ]; then
				COOLING=0
			fi

			# Both branches keep CFB off and keep the uclamp lift, exactly as the
			# daemon does. Only the ceiling moves.
			if [ "$COOLING" = 0 ]; then
				echo "$WANT" > $NODE 2>/dev/null
			else
				echo "$COOLW" > $NODE 2>/dev/null
				NPAUSE=$((NPAUSE+1))
			fi
			[ "$(cat $CFB)" != 0 ] && echo 0 > $CFB 2>/dev/null
			for p in $(survivors); do
				uclampset -a -M 1024 -p "$p" >/dev/null 2>&1
			done
		fi

		NS=$((NS+1)); JSUM=$((JSUM + J))
		EL=$(( $(now) - T0 ))
		[ "$EL" -gt $((DUR - 60)) ] && { JTAIL=$((JTAIL + J)); NTAIL=$((NTAIL+1)); }
		if [ $((NS % 4)) -eq 0 ] && [ "$EL" -gt $((DUR - 60)) ]; then
			read f6 < /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq 2>/dev/null || f6=0
			read f0 < /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null || f0=0
			F6SUM=$((F6SUM + f6)); F0SUM=$((F0SUM + f0)); NF=$((NF + 1))
		fi

		if [ "$J" -gt "$HARD_ABORT" ]; then
			say "!!! HARD ABORT at $((J/1000)) C"; touch $TMP/hard; break
		fi
		sleep 0.25
	done

	TICKS=0; PRIME=0; MIDW=0
	for f in $TMP/t_*; do
		[ -f "$f" ] || continue
		n=$(wc -l < "$f")
		TICKS=$((TICKS + n))
		case "${f##*t_}" in
			6|7) PRIME=$((PRIME + n)) ;;
			*)   MIDW=$((MIDW + n)) ;;
		esac
	done
	kill_uid
	[ "$STOCK" = 0 ] && echo "$RATED" > $NODE 2>/dev/null

	PAUSEPCT=0; [ $NS -gt 0 ] && PAUSEPCT=$(( 100 * NPAUSE / NS ))
	JAVG=0; [ $NS -gt 0 ] && JAVG=$(( JSUM / NS ))
	JEQ=$JAVG; [ $NTAIL -gt 0 ] && JEQ=$(( JTAIL / NTAIL ))

	# split work is the point of the eight-worker harness: it says WHICH cluster
	# a level's extra throughput came from, which a total cannot.
	F6=0; F0=0
	[ $NF -gt 0 ] && { F6=$((F6SUM / NF)); F0=$((F0SUM / NF)); }

	say "RESULT $LBL | work=$TICKS (mid=$MIDW prime=$PRIME) | stepped-down=${PAUSEPCT}% | clk p6=$F6 p0=$F0 | start $((JSTART/1000)) C, mean $((JAVG/1000)) C, last-60s $((JEQ/1000)) C, peak $((JMAX/1000)) C$([ -f $TMP/hard ] && echo '  [HARD ABORT]')"
	return 0
}

say "BARE DEVICE, 8 workers (one per core), ${DUR}s per point"
say "gate parked at 96 C so it never fires -- each point is a fixed pair of ceilings."
point s-anchor    2841600 2400000 96000 || exit 1
point s-cool-now  2649600 2227200 96000 || exit 1
point s-prime-cut 2438400 2400000 96000 || exit 1
point s-mid-cut   2841600 2227200 96000 || exit 1
point s-deep      2438400 1996800 96000 || exit 1
say ""
say "=== done ==="
