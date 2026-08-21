#!/system/bin/sh
# What the daily level's two ceilings are actually worth, per degree of heat.
#
# Level 1 was shipped as a reasoned guess and DATA.md 40 measured it with two
# prime-pinned workers. That harness cannot see P0 at all: policy0 owns cpu0-5,
# six of the eight cores, and no worker ever ran there. Yet level 1 is the
# always-on level, and it holds those six cores at 2400000 against a rated
# 3532800 -- 68 %. This measures that.
#
# Points are chosen to SEPARATE the two levers rather than to walk the module's
# levels: P0 moves with P6 held, P6 moves with P0 held, so the daily level's
# return can be attributed instead of inferred.
#
# Figure of merit is work per degree. A ceiling that buys 8 % throughput for 9 C
# is a bad trade on an always-on level even though its raw work is higher, and
# raw work alone is what a ladder of levels hides.
#
# Differences from experiments/2026-08-20/bare-device-ladder.sh:
#   1. eight workers, one per core, because a level that governs six mid cores
#      cannot be judged by a load that never lands on one.
#   2. the controller is NOT isolated from the workers any more -- there is no
#      free cluster left. Its cost is small and identical at every point, so
#      comparisons between points hold; absolute ticks are not comparable to the
#      2026-08-20 run and are not meant to be.
#   3. the report carries C over stock and work-per-degree, since the question is
#      the trade and not the peak.

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
TMP=/data/local/tmp/drc
HYST=6000
DWELL=15
# The module's step-down lowers the CEILING to these and keeps both levers on.
# experiments/2026-08-20 wrote the rated maxima and handed CFB back instead --
# that is a full release, which is what op13perf/README.md still describes and
# what perfd.sh stopped doing. Measuring a step-down cost with a release harness
# would charge the level for something the module never does.
COOL_P6=2649600
COOL_P0=2227200
OUT=/data/local/tmp/daily-return-curve.txt

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
	echo 1 > /data/adb/op13perf/state 2>/dev/null
	if [ -n "$S" ]; then
		say "!!! LEAK: uid $UID_T still has pids: $S"
	else
		say "### clean: no uid $UID_T processes remain"
	fi
	say "### module returned to level 1"
}
trap finish EXIT INT TERM

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
say "stock first, so nothing is read against an already-soaked device."
point stock   stock   0       0     || exit 1
point d-base  2841600 2400000 88000 || exit 1
point d-mid1  2841600 2745600 88000 || exit 1
point d-mid2  2841600 2918400 88000 || exit 1
point d-p6up  3283200 2400000 88000 || exit 1
point perf    3283200 2918400 90000 || exit 1
say ""
say "=== done ==="
