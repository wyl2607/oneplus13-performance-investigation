#!/system/bin/sh
#
# Shared helpers for the R3 real-app uclamp pilot (docs/R3_REAL_APP_PILOT.md).
# Sourced by run-one.sh, not run directly.
#
# Reuses, unmodified in behaviour, the primitives already validated by
# earlier phases:
#   - thermal zone resolution by name, soft/hard two-tier gate:
#     92 C = RUN_ABORT (this run only), 95 C = SESSION_STOP (whole session) --
#     same thresholds and semantics as experiments/s2d/run-one.sh
#   - prime-CPU discovery by cpu_capacity, /proc/stat busy-jiffy sampling --
#     same as experiments/real-workloads/common.sh
#   - the uclampset primitive -- mitigation/experimental/common.sh
#
# Two mechanism levels (docs/R3_REAL_APP_PILOT.md):
#   process    -- uclampset -m 512 -a -p <main_pid>, uclamp_fork() propagates
#                 it to every worker the pool spawns
#   active-set -- every tick, rank /proc/<pid>/task/* by runtime delta and
#                 clamp only the top-K; threads that drop out of the top-K
#                 are reset to uclamp.min=0, not left boosted

J_ZONE_TYPE=cpu-1-1-1
S_ZONE_TYPE=shell_front
J_SOFT=92000
J_HARD=95000
S_HARD=42000
TICK_S=0.25
TOPAPP=/dev/cpuset/top-app/cgroup.procs
POLICY0_TIS=/sys/devices/system/cpu/cpufreq/policy0/stats/time_in_state
POLICY6_TIS=/sys/devices/system/cpu/cpufreq/policy6/stats/time_in_state

say() { printf '%s\n' "$*"; }

rd() {
	R=NA
	[ "$1" = "NA" ] || [ -z "$1" ] && return 0
	read R < "$1" 2>/dev/null
	[ -z "$R" ] && R=NA
	return 0
}

now_cs() {
	read _a _b < /proc/uptime
	printf '%s\n' "${_a%.*}${_a#*.}"
}

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

resolve_zones() {
	Z_J=NA
	Z_S=NA
	_j=$(zone_by_name "$J_ZONE_TYPE") && Z_J="$_j"
	_s=$(zone_by_name "$S_ZONE_TYPE") && Z_S="$_s"
	if [ "$Z_J" = "NA" ]; then
		say "ERROR: junction sensor $J_ZONE_TYPE not found (refusing to run without an abort)"
		return 1
	fi
	return 0
}

# Prime CPUs = those with the maximum cpu_capacity. Do not hardcode 6/7.
discover_prime() {
	PRIME_CPUS=""
	MAXCAP=0
	for _c in /sys/devices/system/cpu/cpu[0-9]*; do
		[ -r "$_c/cpu_capacity" ] || continue
		read _cap < "$_c/cpu_capacity"
		[ "$_cap" -gt "$MAXCAP" ] && MAXCAP="$_cap"
	done
	for _c in /sys/devices/system/cpu/cpu[0-9]*; do
		_n="${_c##*/cpu}"
		[ -r "$_c/cpu_capacity" ] || continue
		read _cap < "$_c/cpu_capacity"
		[ "$_cap" -eq "$MAXCAP" ] && PRIME_CPUS="$PRIME_CPUS$_n "
	done
}

snapshot_stat() {
	ALL_BUSY=0
	PRIME_BUSY=0
	while read -r _a _u _n _s _id _io _irq _sirq _rest; do
		case "$_a" in
			cpu[0-9]*)
				_b=$((_u + _n + _s + _irq + _sirq))
				ALL_BUSY=$((ALL_BUSY + _b))
				for _p in $PRIME_CPUS; do
					[ "$_a" = "cpu$_p" ] && PRIME_BUSY=$((PRIME_BUSY + _b))
				done
				;;
			cpu) ;;
			*) break ;;
		esac
	done < /proc/stat
}

# Resolve the main pid for a package via pidof. Empty on failure.
pkg_pid() {
	_p=$(pidof "$1" 2>/dev/null)
	_p="${_p%% *}"
	[ -n "$_p" ] && printf '%s\n' "$_p"
}

pid_in_topapp() {
	_pid="$1"
	[ -r "/proc/$_pid/cgroup" ] || return 1
	while IFS= read -r _cl; do
		case "$_cl" in
			*:cpuset:/top-app*) return 0 ;;
		esac
	done < "/proc/$_pid/cgroup"
	return 1
}

# Sets THERMAL_LEVEL: 0 ok, 1 soft (92C, RUN_ABORT), 2 hard (95C, SESSION_STOP)
check_thermal() {
	rd "$Z_J"; _j=$R
	rd "$Z_S"; _s=$R
	THERMAL_LEVEL=0
	THERMAL_J=$_j
	THERMAL_S=$_s
	if [ "$_j" != "NA" ] && [ "${_j:-0}" -ge "$J_HARD" ]; then THERMAL_LEVEL=2; return; fi
	if [ "$_s" != "NA" ] && [ "${_s:-0}" -ge "$S_HARD" ]; then THERMAL_LEVEL=2; return; fi
	if [ "$_j" != "NA" ] && [ "${_j:-0}" -ge "$J_SOFT" ]; then THERMAL_LEVEL=1; return; fi
}

# Rank a pid's threads by runtime delta since the previous scan (schedstat
# field 1, ns of on-cpu time) and print the top-N tids, space-separated on a
# single line, most active first. A single trailing line (not one tid per
# line) matters: callers do a " $list " substring membership test, which
# needs one flat space-delimited string, not newline-joined output. Uses a
# single awk pass per call, same discipline as
# tools/dominant-thread-observer.sh: no per-thread fork.
rank_active_threads() {
	_pid="$1"
	_topn="$2"
	[ -d "/proc/$_pid/task" ] || return 1
	awk -v topn="$_topn" '
		FNR == 1 { tid = FILENAME; sub(/.*task\//, "", tid); sub(/\/schedstat/, "", tid); runtime = $1 + 0; order[++k] = tid; rt[tid] = runtime }
		END {
			for (i = 1; i <= k; i++) {
				t = order[i]
				for (j = i + 1; j <= k; j++) {
					u = order[j]
					if (rt[u] > rt[t]) { tmp = order[i]; order[i] = order[j]; order[j] = tmp; t = order[i] }
				}
			}
			n = (topn < k) ? topn : k
			out = ""
			for (i = 1; i <= n; i++) out = out order[i] " "
			print out
		}
	' /proc/"$_pid"/task/*/schedstat 2>/dev/null
}

# Apply uclamp.min=512 to every thread of $1 (process level).
apply_process_clamp() {
	_pid="$1"
	[ -n "$_pid" ] && [ -d "/proc/$_pid" ] || return 1
	uclampset -m 512 -a -p "$_pid" 2>/dev/null
}

reset_process_clamp() {
	_pid="$1"
	[ -n "$_pid" ] && [ -d "/proc/$_pid" ] || return 1
	uclampset -m 0 -a -p "$_pid" 2>/dev/null
}

# One tick of the active-set clamp: re-rank, clamp new entrants, reset
# threads that dropped out. $1=pid $2=topk $3=clamped-set-file (tids,
# space-separated on one line, tracked across ticks so drop-outs get reset).
active_set_tick() {
	_pid="$1"
	_topk="$2"
	_setfile="$3"
	_new=$(rank_active_threads "$_pid" "$_topk")
	_old=""
	[ -f "$_setfile" ] && _old=$(cat "$_setfile")
	for _t in $_new; do
		[ -d "/proc/$_pid/task/$_t" ] && uclampset -m 512 -p "$_t" 2>/dev/null
	done
	for _t in $_old; do
		case " $_new " in
			*" $_t "*) ;;
			*) [ -d "/proc/$_pid/task/$_t" ] && uclampset -m 0 -p "$_t" 2>/dev/null ;;
		esac
	done
	printf '%s\n' "$_new" > "$_setfile"
	printf '%s\n' "$_new"
}
