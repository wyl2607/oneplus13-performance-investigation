#!/bin/bash
# Bare-device GB7 ladder, driven from the host.
#
# Reads a plan CSV from tools/make-gb7-repro-plan.py and, for each row:
#   1. switches op13perf to that arm's level
#   2. waits out a cooldown gate (junction AND shell, plus a minimum dwell)
#   3. force-stops Geekbench, launches it, taps Run by its real bounds
#   4. waits for a NEW row to appear in Geekbench's own history.db
#   5. records level, scores, and the thermal summary of that run
#
# Scores come from /data/data/com.primatelabs.parkdale/files/history.db rather
# than from a screenshot, so a missed tap cannot be mistaken for a finished run:
# if no new row appears inside the timeout, the run is marked FAILED and the
# ladder stops.
#
# usage: run-bare-ladder.sh <plan.csv> <outdir>
set -u

PLAN="$1"; OUT="$2"
mkdir -p "$OUT"
RESULTS="$OUT/results.csv"
LOG="$OUT/run.log"

# RECOVERY IS A FIXED DWELL, NOT A SHELL-TEMPERATURE GATE.
#
# Measured twice on this device, bare, USB attached:
#   idle floor before any run     junction ~39 C, shell 33.8-33.9 C (flat 3 min)
#   after one GB7 run             junction recovers to 38-40 C in ~4 min,
#                                 shell sits at 35.2 C and does NOT fall in 8 min
#
# The chassis floor RISES monotonically across a session and never returns to its
# pre-run value within any practical wait. So any fixed shell threshold is
# reachable early in a session and unreachable later -- which is exactly what
# happened, twice, with 33.0 and then 35.0. Gating on it does not equalise runs,
# it just gives early runs a short wait and late runs the full timeout.
#
# What comparability actually needs is that every run gets the SAME treatment.
# So: a fixed dwell, identical for all runs; junction as a safety assertion only
# (it does recover); and the starting shell temperature RECORDED as a covariate,
# so the drift is visible in the data and the ABBA ordering can neutralise it.
DWELL_S=300          # identical for every run, no early exit
JUNC_SAFE=55000      # after the dwell, junction should be back near its ~39 C floor
JUNC_EXTRA_S=300     # if it is not, wait up to this much longer, then FLAG
RUN_TIMEOUT_S=900

say() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }

dev() { adb shell "su -M -c \"sh -c \\\"$1\\\"\"" </dev/null; }

junc()  { adb shell 'cat /sys/class/thermal/thermal_zone28/temp' 2>/dev/null | tr -d '\r'; }
shellt() { adb shell 'for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type); [ "$t" = shell_front ] && cat $z/temp; done' 2>/dev/null | tr -d '\r' | head -1; }

db_count() {
	dev "cp /data/data/com.primatelabs.parkdale/files/history.db /data/local/tmp/h.db 2>/dev/null; chmod 666 /data/local/tmp/h.db" >/dev/null 2>&1
	adb pull /data/local/tmp/h.db "$OUT/h.db" >/dev/null 2>&1
	python3 - "$OUT/h.db" <<'PY'
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    print(c.execute("select count(*) from cpu_documents").fetchone()[0])
except Exception:
    print(-1)
PY
}

db_latest() {
	python3 - "$OUT/h.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
r = c.execute("""select cd.score, cd.multicore_score, d.created_at
                 from cpu_documents cd join documents d on d.id=cd.document_id
                 order by d.created_at desc limit 1""").fetchone()
print(f"{r[0]},{r[1]},{r[2]}")
PY
}

set_level() {
	dev "echo $1 > /data/adb/op13perf/state" >/dev/null 2>&1
	sleep 3
	local st; st=$(dev "cat /data/adb/op13perf/status" | tr -d '\r')
	say "  level set to $1 -> $st"
	case "$st" in
		*"level=$1"*held=yes*) return 0 ;;
		*) say "  !! level did not take, aborting"; return 1 ;;
	esac
}

# Sets START_J / START_S (millidegrees) for the caller to record.
cooldown() {
	local t0 j s el
	t0=$(date +%s)
	while :; do
		el=$(( $(date +%s) - t0 ))
		[ "$el" -ge "$DWELL_S" ] && break
		if [ $(( el % 60 )) -lt 16 ]; then
			say "  settling... ${el}/${DWELL_S}s  junction $(( $(junc) / 1000 ))C  shell $(( $(shellt) / 1000 ))C"
		fi
		sleep 15
	done
	# junction is the one that genuinely recovers; treat it as an assertion
	while :; do
		j=$(junc)
		[ "${j:-99999}" -lt "$JUNC_SAFE" ] && break
		el=$(( $(date +%s) - t0 ))
		if [ "$el" -ge $(( DWELL_S + JUNC_EXTRA_S )) ]; then
			START_J=$j; START_S=$(shellt)
			say "  !! junction still $((j/1000))C after ${el}s - FLAGGED"
			return 1
		fi
		say "  junction $((j/1000))C still above $((JUNC_SAFE/1000))C, waiting"
		sleep 15
	done
	START_J=$j; START_S=$(shellt)
	say "  settled ${DWELL_S}s: start junction $((START_J/1000))C shell $((START_S/1000))C"
	return 0
}

tap_run() {
	adb shell 'uiautomator dump /sdcard/ui.xml >/dev/null 2>&1'
	local b x1 y1 x2 y2
	b=$(adb shell 'cat /sdcard/ui.xml' | tr '<' '\n' | grep 'id/runCpuBenchmarks' \
		| grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)
	[ -n "$b" ] || { say "  !! Run button not found"; return 1; }
	read -r x1 y1 x2 y2 <<<"$(echo "$b" | grep -o '[0-9]\+' | tr '\n' ' ')"
	adb shell "input tap $(( (x1+x2)/2 )) $(( (y1+y2)/2 ))"
	say "  tapped Run at $(( (x1+x2)/2 )),$(( (y1+y2)/2 ))  [$b]"
}

echo "run_id,block,order,arm,level,single,multi,cool_ok,start_junc_c,start_shell_c,junc_peak_c,shell_peak_c,stepdown_pct" > "$RESULTS"

say "=== bare-device ladder start ==="
say "plan: $PLAN"

# The plan is read into an array FIRST, not streamed into the loop.
#
# Two separate traps here, both already stepped in:
#   1. `tail | while` puts the body in a subshell, so an `exit` on an abort path
#      kills only the subshell and the script still prints "done".
#   2. feeding the loop from a redirect instead is not enough either: `adb shell`
#      reads stdin, so the first iteration SWALLOWS the remaining plan lines and
#      the ladder silently runs exactly one row. Observed: "done, 1/8".
# Hence: read the plan up front, iterate over the array, and every adb call in
# the body still gets </dev/null for good measure.
# `mapfile` is bash 4+; macOS /bin/bash is 3.2, so build the array by hand.
PLAN_ROWS=()
while IFS= read -r _line; do
	[ -n "$_line" ] && PLAN_ROWS[${#PLAN_ROWS[@]}]="$_line"
done < <(tail -n +2 "$PLAN")
say "plan holds ${#PLAN_ROWS[@]} runs"
[ "${#PLAN_ROWS[@]}" -gt 0 ] || { say "!! empty plan"; exit 7; }

for _row in "${PLAN_ROWS[@]}"; do
	IFS=, read -r run_id block order arm label <<<"$_row"
	[ -n "$run_id" ] || continue
	case "$arm" in A) LEVEL=1 ;; B) LEVEL=2 ;; *) say "unknown arm $arm"; exit 2 ;; esac

	say "--- $run_id (block $block, order $order) arm=$arm level=$LEVEL  $label"
	set_level "$LEVEL" || exit 3

	START_J=0; START_S=0; COOL_OK=yes; cooldown || COOL_OK=FLAGGED

	BEFORE=$(db_count)
	[ "$BEFORE" -ge 0 ] || { say "  !! cannot read history.db"; exit 4; }

	adb shell 'am force-stop com.primatelabs.parkdale' >/dev/null 2>&1 </dev/null
	sleep 2
	adb shell 'input keyevent KEYCODE_WAKEUP' >/dev/null 2>&1 </dev/null
	adb shell 'monkey -p com.primatelabs.parkdale -c android.intent.category.LAUNCHER 1' >/dev/null 2>&1 </dev/null
	sleep 6

	adb shell "su -M -c \"nohup sh /data/local/tmp/gb7-watch.sh 900 /data/local/tmp/w-$run_id.txt >/dev/null 2>&1 &\"" >/dev/null 2>&1 </dev/null
	sleep 1
	tap_run || exit 5

	t0=$(date +%s); GOT=""
	while :; do
		sleep 20
		NOW=$(db_count)
		if [ "$NOW" -gt "$BEFORE" ] 2>/dev/null; then GOT=$(db_latest); break; fi
		el=$(( $(date +%s) - t0 ))
		if [ "$el" -ge "$RUN_TIMEOUT_S" ]; then
			say "  !! no new result in ${el}s - the run did not happen. STOPPING."
			exit 6
		fi
	done

	adb shell 'pkill -f gb7-watch.sh' >/dev/null 2>&1 </dev/null
	adb pull "/data/local/tmp/w-$run_id.txt" "$OUT/" >/dev/null 2>&1

	SINGLE=$(echo "$GOT" | cut -d, -f1); MULTI=$(echo "$GOT" | cut -d, -f2)
	TH=$(python3 tools/analyze-watch.py "$OUT/w-$run_id.txt" 2>/dev/null \
		| awk '/^BUSY:/{f=1} f&&/junction/{gsub(/[^0-9. ]/,"");print $NF; exit}')
	PK=$(python3 - "$OUT/w-$run_id.txt" <<'PY'
import sys
j=[];s=[];c=0;n=0
for line in open(sys.argv[1]):
    if line[0] in '#t': continue
    p=line.strip().split('|')
    if len(p)<15: continue
    n+=1; j.append(int(p[11])); s.append(int(p[12]))
    if p[14]=='yes': c+=1
print(f"{max(j)/1000:.1f},{max(s)/1000:.1f},{100*c/max(n,1):.1f}" if n else "NA,NA,NA")
PY
)
	say "  RESULT single=$SINGLE multi=$MULTI  start(j,s)=$((START_J/1000)),$((START_S/1000))C  peak(j,s,stepdown%)=$PK"
	echo "$run_id,$block,$order,$arm,$LEVEL,$SINGLE,$MULTI,$COOL_OK,$((START_J/1000)),$((START_S/1000)),$PK" >> "$RESULTS"
done

say "=== ladder done, $(( $(wc -l < "$RESULTS") - 1 ))/$(( $(wc -l < "$PLAN") - 1 )) runs recorded ==="
cat "$RESULTS"
