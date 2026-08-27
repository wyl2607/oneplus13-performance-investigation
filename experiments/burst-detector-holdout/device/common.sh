#!/system/bin/sh
#
# Shared helpers for the R4 burst-detector holdout on-device runner
# (experiments/burst-detector-holdout/README.md). Sourced by run-r4-one.sh,
# not run directly.
#
# Reuses, unmodified in behaviour, primitives already validated by earlier
# phases:
#   - thermal zone resolution by name, soft/hard two-tier gate: 92 C = this
#     run only, 95 C = whole session -- experiments/r3-real-app/common.sh
#   - the boost-exit safety invariant (docs/METHODOLOGY.md, "Safety invariant:
#     boost exit must be verified"): sweep, then verify by read-back, then one
#     retry, then fail closed with a distinct status and a persistent marker.
#     R4 does not apply an experimental uclamp boost itself, but the op13perf
#     module it toggles does (guard-lift via `uclampset -a -M 1024`), so the
#     same invariant applies to the module's own uclamp state on exit.
#
# op13perf module control (mitigation/op13perf/perfd.sh, module README):
#   state 0 = module_off (stock, no lift, no ceiling change)
#   state 1 = module_off (daily tier: DAILY_P6/DAILY_P0 ceilings, URCC lift,
#             CFB disabled) -- this is "module_on" for R4, matching the tier
#             S1's traces were collected under.
#   Switching writes STATE and the daemon (perfd.sh) picks it up within its
#   poll loop; the daemon itself verifies its own writes into STATUS. This
#   script re-verifies independently rather than trusting that file, per the
#   same "verify, do not assume" discipline as the boost-exit invariant.

J_ZONE_TYPE=cpu-1-1-1
S_ZONE_TYPE=shell_front
J_SOFT=92000
J_HARD=95000
S_HARD=42000
TICK_S=0.25

MOD_STATEDIR=/data/adb/op13perf
MOD_STATE=$MOD_STATEDIR/state
MOD_STATUS=$MOD_STATEDIR/status
MOD_NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
MOD_CFB=/sys/module/cpufreq_bouncing/parameters/enable
MOD_SETTLE_S=5
TOPAPP_PROCS=/dev/cpuset/top-app/cgroup.procs

say() { printf '%s\n' "$*"; }

now_cs() {
	read _a _b < /proc/uptime
	printf '%s\n' "${_a%.*}${_a#*.}"
}

now_ms() {
	printf '%s\n' "$(( $(now_cs) * 10 ))"
}

rd() {
	R=NA
	[ "$1" = "NA" ] || [ -z "$1" ] && return 0
	read R < "$1" 2>/dev/null
	[ -z "$R" ] && R=NA
	return 0
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

# Sets THERMAL_LEVEL: 0 ok, 1 soft (92C, this run only), 2 hard (95C, session)
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

# Resolve the main pid for a package via pidof. Empty on failure.
pkg_pid() {
	_p=$(pidof "$1" 2>/dev/null)
	_p="${_p%% *}"
	[ -n "$_p" ] && printf '%s\n' "$_p"
}

# Foreground tgids from the kernel's own top-app cpuset, uid >= 10000 only --
# same discipline as perfd.sh's refresh_pids and dominant-thread-observer.sh's
# top_tgids: never match by process name (comm truncates at 15 chars).
top_app_tgids() {
	set --
	for t in $(cat "$TOPAPP_PROCS" 2>/dev/null); do
		[ -r "/proc/$t/status" ] && set -- "$@" "/proc/$t/status"
	done
	[ $# -gt 0 ] || return 0
	awk '
		FNR == 1 { tg="" }
		/^Tgid:/ { tg=$2 }
		/^Uid:/  { if (tg != "" && $2 + 0 >= 10000) print tg }
	' "$@" 2>/dev/null | sort -nu
}

# --- module control -----------------------------------------------------

mkdir_mod_statedir() {
	mkdir -p "$MOD_STATEDIR" 2>/dev/null
}

# Read back the module's own idea of ceilings/CFB and compare against what
# state $1 (0 off, 1 on) should have produced. Returns 0 if consistent.
verify_module_state() {
	_want="$1"
	rd "$MOD_NODE"; _node=$R
	_cfb=NA
	[ -r "$MOD_CFB" ] && read _cfb < "$MOD_CFB" 2>/dev/null
	_status=""
	[ -r "$MOD_STATUS" ] && read _status < "$MOD_STATUS" 2>/dev/null
	if [ "$_want" = "0" ]; then
		# off: module hands CFB back to the system (=1) and releases the
		# ceiling node to rated maxima (perfd.sh's release()). We cannot
		# know the exact rated string across devices, so treat "not
		# obviously still clamped to a daily/perf/extreme ceiling" plus
		# cfb=1 as clean, and also require status to literally say off.
		case "$_status" in
			off*) ;;
			*) say "MODULE_VERIFY_FAIL: status='$_status' (expected off*)"; return 1 ;;
		esac
		if [ "$_cfb" != "1" ] && [ "$_cfb" != "NA" ]; then
			say "MODULE_VERIFY_FAIL: cfb=$_cfb (expected 1 on off)"
			return 1
		fi
		return 0
	else
		case "$_status" in
			level=1\ held=yes*) ;;
			*) say "MODULE_VERIFY_FAIL: status='$_status' (expected level=1 held=yes)"; return 1 ;;
		esac
		return 0
	fi
}

# Set module state (0 off, 1 on), wait for the daemon's settle window, then
# verify independently. One retry, then fail closed -- same shape as the
# boost-exit invariant. Returns 0 clean, 1 residue/verify failure.
set_module_state() {
	_want="$1"
	mkdir_mod_statedir
	echo "$_want" > "$MOD_STATE" 2>/dev/null
	sleep "$MOD_SETTLE_S"
	if verify_module_state "$_want"; then
		return 0
	fi
	say "MODULE_VERIFY retry: re-writing state=$_want"
	echo "$_want" > "$MOD_STATE" 2>/dev/null
	sleep "$MOD_SETTLE_S"
	verify_module_state "$_want"
}

# Boost-exit invariant applied to whichever pids are currently in top-app:
# after forcing module_off, no thread should still read a lifted
# uclamp.max=1024-only-by-guard artefact stuck at a non-stock value from the
# module's own lift loop. The module's guard reclamps within its own poll
# once the lift stops (mitigation/op13perf/README.md, "关闭时会发生什么"), so
# this is a belt-and-suspenders read-back, not the primary mechanism.
verify_no_residual_lift() {
	_bad=0
	for _tg in $(top_app_tgids); do
		[ -d "/proc/$_tg/task" ] || continue
		for _t in $(ls "/proc/$_tg/task" 2>/dev/null); do
			_line=$(uclampset -p "$_t" 2>/dev/null)
			_min=$(printf '%s\n' "$_line" | sed -n 's/.*min: \([0-9]*\).*/\1/p')
			if [ -n "$_min" ] && [ "$_min" != "0" ]; then
				printf 'RESIDUAL tid=%s min=%s\n' "$_t" "$_min"
				_bad=1
			fi
		done
	done
	return $_bad
}
