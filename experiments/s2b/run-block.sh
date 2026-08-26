#!/usr/bin/env bash
# run-block.sh - drive the S2b ABBA/BAAB balanced block over adb, pulling and
# converting each run's trace, and appending to one master CSV.
#
# Host-side orchestrator: calls experiments/s2b/run-one.sh on-device once per
# run, via adb. Not itself device code.
set -u
cd "$(dirname "$0")/../.."

OFFSETS=1560,848,856,4
DURATION=${DURATION:-15}
OUT_DIR=experiments/s2b/data-$(date -u +%Y%m%d)
CSV=$OUT_DIR/s2b-runs.csv
LOG=$OUT_DIR/run-block.log
mkdir -p "$OUT_DIR"

# ABBA / BAAB balanced blocks, repeated to reach 16 runs (4 blocks).
BLOCKS=("A B B A" "B A A B" "A B B A" "B A A B")

first_row=1
[ -f "$CSV" ] && first_row=0

run_idx=0
for block_i in "${!BLOCKS[@]}"; do
	block_num=$((block_i + 1))
	pattern=(${BLOCKS[$block_i]})
	for arm in "${pattern[@]}"; do
		run_idx=$((run_idx + 1))
		run_id=$(printf "s2b-r%02d" "$run_idx")
		[ "$arm" = "A" ] && umin=0 || umin=512
		trace="/data/local/tmp/op13-s2b/${run_id}.trace"

		echo "=== run $run_idx/16  id=$run_id block=$block_num arm=$arm uclamp_min=$umin ===" | tee -a "$LOG"
		result=$(MSYS_NO_PATHCONV=1 adb shell "su -c 'cd /data/local/tmp && sh run-one.sh --run-id $run_id --arm $arm --uclamp-min $umin --duration $DURATION --uclamp-offsets $OFFSETS --out $trace'" 2>&1)
		echo "$result" | tee -a "$LOG"

		status=$(echo "$result" | sed -n 's/.*status=\([A-Z_0-9]*\).*/\1/p')
		start_temp=$(echo "$result" | sed -n 's/.*start_temp=\([0-9.]*\).*/\1/p')
		peak_temp=$(echo "$result" | sed -n 's/.*peak_temp=\([0-9.]*\).*/\1/p')

		if [ "$status" = "SESSION_STOP_THERMAL_95" ]; then
			echo "ABORT: session-stop thermal gate hit (>=95C). Stopping the whole block." | tee -a "$LOG"
			break 2
		fi
		if [ "$status" = "RUN_ABORT_THERMAL_92" ]; then
			echo "SKIP: run $run_id aborted at >=92C junction. Continuing to next run, not retried." | tee -a "$LOG"
			continue
		fi
		if [ "$status" != "OK" ]; then
			echo "WARN: run $run_id ended with status=$status, skipping from CSV." | tee -a "$LOG"
			continue
		fi

		local_trace="$OUT_DIR/${run_id}.trace"
		MSYS_NO_PATHCONV=1 adb pull "$trace" "$local_trace" >>"$LOG" 2>&1
		hdr_flag=""
		[ "$first_row" = 1 ] && hdr_flag="--header"
		python3 tools/s2b-trace-to-csv.py "$local_trace" \
			--run-id "$run_id" --block "$block_num" --arm "$arm" \
			--requested-min "$umin" \
			--initial-junction-c "$start_temp" --peak-junction-c "$peak_temp" \
			$hdr_flag >> "$CSV" 2>>"$LOG"
		first_row=0
	done
done

echo "Done. CSV at $CSV" | tee -a "$LOG"
