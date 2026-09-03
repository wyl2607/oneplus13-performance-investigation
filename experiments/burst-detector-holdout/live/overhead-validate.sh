#!/system/bin/sh
# R4 Phase 3 overhead validation driver.
# Regimes: 1-thread (core7 only) and 8-thread (one pinned thread per core).
# Each regime: 3 repeats OFF, 3 repeats ON (dominant-thread-observer.sh running).
# Requires: /data/local/tmp/dto.sh (dominant-thread-observer.sh), root.

OUT=/data/local/tmp/overhead-results.log
OBSDIR=/data/local/tmp/obs-logs
mkdir -p "$OBSDIR"
: > "$OUT"

now_cs() { read a b < /proc/uptime; echo "${a%.*}${a#*.}"; }

zone_by_name() {
	_want="$1"
	for _z in /sys/class/thermal/thermal_zone*; do
		[ -r "$_z/type" ] || continue
		read _t < "$_z/type" 2>/dev/null || continue
		if [ "$_t" = "$_want" ]; then
			printf '%s\n' "$_z/temp"
			return 0
		fi
	done
	return 1
}

Z_J=$(zone_by_name cpu-1-1-1)
Z_S=$(zone_by_name shell_front)

rd() { [ -r "$1" ] && read R < "$1" 2>/dev/null || R=NA; }

cpu_busy_jiffies() {
	# sum of user+nice+system+irq+softirq+steal across all cpuN lines (excl idle/iowait)
	awk '/^cpu[0-9]/ { s += $2+$3+$4+$7+$8+$9 } END { print s+0 }' /proc/stat
}

N_LITTLE=1500000
N_BIG=3000000

run_workload_1t() {
	# single busy thread on core7 (big)
	taskset 80 sh -c "i=0; while [ \$i -lt $N_BIG ]; do i=\$((i+1)); done"
}

run_workload_8t() {
	for m in 01 02 04 08 10 20; do
		taskset $m sh -c "i=0; while [ \$i -lt $N_LITTLE ]; do i=\$((i+1)); done" &
	done
	for m in 40 80; do
		taskset $m sh -c "i=0; while [ \$i -lt $N_BIG ]; do i=\$((i+1)); done" &
	done
	wait
}

do_run() {
	regime=$1   # 1t | 8t
	arm=$2      # OFF | ON
	rep=$3

	rd "$Z_J"; j0=$R
	rd "$Z_S"; s0=$R
	cpu0=$(cpu_busy_jiffies)

	obs_pid=""
	obslog="$OBSDIR/${regime}-${arm}-${rep}.log"
	if [ "$arm" = "ON" ]; then
		sh /data/local/tmp/dto.sh 25 250 5 > "$obslog" 2>&1 &
		obs_pid=$!
		sleep 1
	fi

	t0=$(now_cs)
	if [ "$regime" = "1t" ]; then
		run_workload_1t
	else
		run_workload_8t
	fi
	t1=$(now_cs)
	wall_cs=$((t1 - t0))

	obs_cpu="NA"
	if [ -n "$obs_pid" ]; then
		if [ -r "/proc/$obs_pid/stat" ]; then
			read -r _stat < "/proc/$obs_pid/stat"
			rest=${_stat##*) }
			set -- $rest
			# after stripping "pid (comm) ", fields: state ppid pgrp session tty tpgid flags
			# minflt cminflt majflt cmajflt utime stime cutime cstime ...
			utime=${13:-0}; stime=${14:-0}; cutime=${15:-0}; cstime=${16:-0}
			obs_cpu="utime=${utime}_stime=${stime}_cutime=${cutime}_cstime=${cstime}"
		fi
		kill "$obs_pid" 2>/dev/null
		wait "$obs_pid" 2>/dev/null
	fi

	cpu1=$(cpu_busy_jiffies)
	rd "$Z_J"; j1=$R
	rd "$Z_S"; s1=$R

	no_top_app=0
	max_wall_ms=0
	nwindows=0
	if [ -r "$obslog" ]; then
		no_top_app=$(grep -c 'type=no_top_app' "$obslog")
		nwindows=$(grep -c '^WINDOW' "$obslog")
		max_wall_ms=$(grep '^WINDOW' "$obslog" | sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p' | sort -n | tail -1)
		[ -n "$max_wall_ms" ] || max_wall_ms=0
	fi

	echo "RESULT|regime=$regime|arm=$arm|rep=$rep|wall_cs=$wall_cs|cpu_busy_jiffies_delta=$((cpu1-cpu0))|junction_c_start=$j0|junction_c_end=$j1|shell_c_start=$s0|shell_c_end=$s1|observer_selfstat=$obs_cpu|observer_windows=$nwindows|observer_no_top_app=$no_top_app|observer_max_wall_ms=$max_wall_ms" >> "$OUT"
}

for regime in 1t 8t; do
	for arm in OFF ON; do
		for rep in 1 2 3; do
			do_run "$regime" "$arm" "$rep"
			sleep 3
		done
	done
done

cat "$OUT"
