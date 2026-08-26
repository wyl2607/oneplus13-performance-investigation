#!/usr/bin/env bash
# run-threshold-ladder.sh - drive the S2d threshold-bisection ladder over adb.
#
# Reads threshold-plan.csv (block,order,uclamp_min,seed) and, for each row,
# calls experiments/s2d/run-one.sh staged on-device: same worker, same
# tracer, same 92/95C thermal gates as PR #15/#16, plus time_in_state
# snapshots and (if TRACE_FREQ=1) the opt-in power:cpu_frequency event.
#
# Host-side orchestrator; not itself device code. Not run automatically --
# invoke by hand after confirming device state with check-state.sh.
set -u
cd "$(dirname "$0")/../.."

PLAN=${PLAN:-experiments/s2d/threshold-plan.csv}
OFFSETS=1560,848,856,4
DURATION=${DURATION:-15}
TRACE_FREQ=${TRACE_FREQ:-0}
OUT_DIR=${OUT_DIR:-experiments/s2d/data-$(date -u +%Y%m%d)}
RUNS_CSV=$OUT_DIR/s2d-threshold-runs.csv
CYCLES_CSV=$OUT_DIR/s2d-threshold-cycles.csv
TIS_CSV=$OUT_DIR/s2d-threshold-tis.csv
LOG=$OUT_DIR/run-threshold-ladder.log
mkdir -p "$OUT_DIR"

FREQ_ARG=""
[ "$TRACE_FREQ" = 1 ] && FREQ_ARG="--trace-freq"

echo "=== pre-flight device state ===" | tee -a "$LOG"
MSYS_NO_PATHCONV=1 adb shell "su -c 'sh /data/local/tmp/check-state.sh'" 2>&1 | tee -a "$LOG"

first_row=1
[ -f "$CYCLES_CSV" ] && first_row=0
if [ ! -f "$RUNS_CSV" ]; then
	echo "run_id,block,order,uclamp_min,tid,req_readback,start_temp,peak_temp,end_temp,status,cycles_complete,cycles_per_second" > "$RUNS_CSV"
fi
if [ ! -f "$TIS_CSV" ]; then
	echo "run_id,uclamp_min,cluster,freq_khz,jiffies_before,jiffies_after,jiffies_delta" > "$TIS_CSV"
fi

RUN_OFFSET=${RUN_OFFSET:-0}
run_idx=$RUN_OFFSET
total=$(($(wc -l < "$PLAN") - 1 + RUN_OFFSET))
# Plan rows are read from fd 3, not stdin -- adb/su calls inside the loop body
# must not be allowed to compete with (and silently drain) the loop's own
# input stream (see docs/S2C_MINIMUM_CLAMP.md's stdin-pipe trap).
while IFS=, read -r block order umin seed <&3; do
	run_idx=$((run_idx + 1))
	run_id=$(printf "s2d-thr-r%02d" "$run_idx")
	trace="/data/local/tmp/op13-s2d/${run_id}.trace"

	echo "=== run $run_idx/$total  id=$run_id block=$block order=$order uclamp_min=$umin ===" | tee -a "$LOG"
	MSYS_NO_PATHCONV=1 adb shell "su -c 'sh /data/local/tmp/check-state.sh'" 2>&1 | tee -a "$LOG"
	result=$(MSYS_NO_PATHCONV=1 adb shell "su -c 'cd /data/local/tmp/op13-s2d && sh run-one.sh --run-id $run_id --arm u$umin --uclamp-min $umin --duration $DURATION --uclamp-offsets $OFFSETS $FREQ_ARG --out $trace'" 2>&1)
	echo "$result" | tee -a "$LOG"

	status=$(echo "$result" | sed -n 's/.*status=\([A-Z_0-9]*\).*/\1/p')
	tid=$(echo "$result" | sed -n 's/.*tid=\([0-9]*\).*/\1/p')
	req_readback=$(echo "$result" | sed -n 's/.*req_readback=\([0-9]*\).*/\1/p')
	start_temp=$(echo "$result" | sed -n 's/.*start_temp=\([0-9.]*\).*/\1/p')
	peak_temp=$(echo "$result" | sed -n 's/.*peak_temp=\([0-9.]*\).*/\1/p')
	end_temp=$(echo "$result" | sed -n 's/.*end_temp=\([0-9.]*\).*/\1/p')

	if [ "$status" = "SESSION_STOP_THERMAL_95" ]; then
		echo "ABORT: session-stop thermal gate hit (>=95C). Stopping the whole ladder." | tee -a "$LOG"
		break
	fi
	if [ "$status" = "RUN_ABORT_THERMAL_92" ]; then
		echo "SKIP: run $run_id aborted at >=92C junction. Continuing, not retried, excluded from CSV." | tee -a "$LOG"
		echo "$run_id,$block,$order,$umin,$tid,,,,,RUN_ABORT_THERMAL_92,," >> "$RUNS_CSV"
		sleep 20
		continue
	fi
	if [ "$status" != "OK" ]; then
		echo "WARN: run $run_id ended with status=$status, skipping from CSV." | tee -a "$LOG"
		echo "$run_id,$block,$order,$umin,$tid,,,,,$status,," >> "$RUNS_CSV"
		continue
	fi
	if [ "$req_readback" != "$umin" ]; then
		echo "WARN: req_readback=$req_readback does not match requested uclamp_min=$umin for $run_id" | tee -a "$LOG"
	fi

	local_trace="$OUT_DIR/${run_id}.trace"
	MSYS_NO_PATHCONV=1 adb pull "$trace" "$local_trace" >>"$LOG" 2>&1
	for f in tis0.before tis0.after tis6.before tis6.after; do
		MSYS_NO_PATHCONV=1 adb pull "$trace.$f" "$OUT_DIR/${run_id}.$f" >>"$LOG" 2>&1
	done
	hdr_flag=""
	[ "$first_row" = 1 ] && hdr_flag="--header"
	parse_stderr=$(python3 tools/s2c-trace-to-csv.py "$local_trace" \
		--run-id "$run_id" --block "$block" --arm "u$umin" --uclamp-min "$umin" \
		--initial-junction-c "$start_temp" --peak-junction-c "$peak_temp" \
		$hdr_flag 2>&1 >> "$CYCLES_CSV")
	echo "$parse_stderr" | tee -a "$LOG"
	first_row=0

	complete=$(echo "$parse_stderr" | sed -n 's/.*, \([0-9]*\) complete.*/\1/p')
	cps=""
	if [ -n "$complete" ]; then
		cps=$(awk -v c="$complete" -v d="$DURATION" 'BEGIN{printf "%.2f", c/d}')
	fi
	echo "$run_id,$block,$order,$umin,$tid,$req_readback,$start_temp,$peak_temp,$end_temp,OK,$complete,$cps" >> "$RUNS_CSV"

	python3 tools/s2d-tis-delta.py --run-id "$run_id" --uclamp-min "$umin" \
		--policy0-before "$OUT_DIR/${run_id}.tis0.before" --policy0-after "$OUT_DIR/${run_id}.tis0.after" \
		--policy6-before "$OUT_DIR/${run_id}.tis6.before" --policy6-after "$OUT_DIR/${run_id}.tis6.after" \
		>> "$TIS_CSV" 2>>"$LOG"

	gzip -f "$local_trace"

	# a short cooldown between runs, matching the mildest-operating-point
	# principle -- this is a threshold bisection, not a stress test.
	sleep 10
done 3< <(tail -n +2 "$PLAN")

echo "Done. Runs CSV at $RUNS_CSV, cycles CSV at $CYCLES_CSV, time_in_state CSV at $TIS_CSV" | tee -a "$LOG"
