#!/system/bin/sh
#
# Shared helpers for the experimental mitigation scripts.
# Intended to be sourced. Not a mode by itself.
#
# Abort thresholds match gb7_unclamp_loop.sh, which fired correctly at
# 98.4 C junction during the section 26 A/B. Zones are resolved by name
# (METHODOLOGY trap 3). No ${var#*(} (mksh swallows the rest of the file).

J_ABORT=95000
S_ABORT=42000
UNCLAMP_IVAL=0.25

say() { printf '%s\n' "$*"; }

rd() {
	R=NA
	[ "$1" = "NA" ] || [ -z "$1" ] && return 0
	read R < "$1" 2>/dev/null
	[ -z "$R" ] && R=NA
	return 0
}

# Resolve a thermal zone path by its type name. Empty on failure.
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

resolve_abort_zones() {
	Z_J=NA
	Z_S=NA
	_j=$(zone_by_name cpu-1-1-1) && Z_J="$_j"
	_s=$(zone_by_name shell_front) && Z_S="$_s"
	if [ "$Z_J" = "NA" ]; then
		say "ERROR: junction sensor cpu-1-1-1 not found (refusing to run without an abort)"
		return 1
	fi
	return 0
}

read_junction() {
	J=0
	[ "$Z_J" != "NA" ] && read J < "$Z_J" 2>/dev/null
	[ -z "$J" ] && J=0
}

read_shell() {
	S=0
	[ "$Z_S" != "NA" ] && read S < "$Z_S" 2>/dev/null
	[ -z "$S" ] && S=0
}

# Returns 0 if we must stop resetting (thermal abort).
thermal_tripped() {
	read_junction
	read_shell
	if [ "$J" -gt "$J_ABORT" ] || [ "$S" -gt "$S_ABORT" ]; then
		return 0
	fi
	return 1
}

pkg_pid() {
	_p=$(pidof "$1" 2>/dev/null)
	_p="${_p%% *}"
	[ -n "$_p" ] && printf '%s\n' "$_p"
}

# Foreground = cpuset top-app or foreground. Parsed without ${var#*(}.
pid_is_foreground() {
	_pid="$1"
	[ -r "/proc/$_pid/cgroup" ] || return 1
	while IFS= read -r _cl; do
		case "$_cl" in
			*:cpuset:*)
				case "$_cl" in
					*:cpuset:/top-app*|*:cpuset:/foreground*)
						return 0
						;;
				esac
				;;
		esac
	done < "/proc/$_pid/cgroup"
	return 1
}

apply_unclamp() {
	_pid="$1"
	[ -n "$_pid" ] && [ -d "/proc/$_pid" ] || return 1
	uclampset -a -M 1024 -p "$_pid" 2>/dev/null
}

now_cs() {
	# /proc/uptime in centiseconds. date +%s%N is unusable on toybox.
	read _a _b < /proc/uptime
	printf '%s\n' "${_a%.*}${_a#*.}"
}
