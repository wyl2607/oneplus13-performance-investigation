#!/system/bin/sh
#
# performance.sh - per-app allowlist, foreground only, bounded, abortable.
#
# EXPERIMENTAL. Can drive the SoC junction to 95 C while the phone still
# feels cool. Not a boot service. Not a daily driver. Supervise it.
#
# Only the packages named on the command line are touched, and only while
# a process of that package is in /top-app or /foreground. When the app
# backgrounds, exits, the timer expires, or the junction/shell abort
# fires, the loop stops calling uclampset and stock takes back over.
#
# Primitive: uclampset -a -M 1024 -p <pid> every 250 ms, because
# uclamp_fork() copies the clamp onto every worker the pool spawns.
#
# usage: sh performance.sh <max_seconds> <package> [package ...]

HERE=$(dirname "$0")
# dirname is fine; do not use ${0%/*} on a path that might lack a slash
# in a way that surprises mksh. dirname is in toybox.
. "$HERE/common.sh"

if [ -z "$1" ] || [ -z "$2" ]; then
	say "usage: sh performance.sh <max_seconds> <package> [package ...]"
	say "  duration is required. an unbounded run is extreme.sh, not this."
	exit 2
fi
MAX="$1"
shift
case "$MAX" in
	*[!0-9]*)
		say "ERROR: max_seconds must be an integer, got: $MAX"
		exit 2
		;;
esac
[ "$MAX" -gt 0 ] || { say "ERROR: max_seconds must be > 0"; exit 2; }

if [ "$(id -u)" != "0" ]; then
	say "ERROR: root required (uclampset on another process is privileged)"
	exit 2
fi

if ! command -v uclampset >/dev/null 2>&1; then
	say "ERROR: uclampset not on PATH (expected /system/bin/uclampset)"
	exit 2
fi

resolve_abort_zones || exit 2

say "mode=performance"
say "max_seconds=$MAX  interval=${UNCLAMP_IVAL}s"
say "abort junction>${J_ABORT} shell>${S_ABORT} (milli-C)"
say "junction_zone=$Z_J  shell_zone=$Z_S"
say "packages: $*"
say "writes: uclampset only. no cpufreq, cpuset, thermal, governor, module."
say "on abort/timeout/background/exit: stop resetting, stock clamp returns."

T0=$(now_cs)
MAXCS=$((MAX * 100))
APPLIED=0
N=0

while : ; do
	EL=$(( $(now_cs) - T0 ))
	if [ "$EL" -ge "$MAXCS" ]; then
		say "STOP|timeout after ${MAX}s applied=$APPLIED"
		exit 0
	fi

	if thermal_tripped; then
		# Fail back to stock: do not apply another unclamp, just leave.
		say "ABORT|junction=$J|shell=$S|applied=$APPLIED"
		exit 3
	fi

	HIT=0
	for pkg in "$@"; do
		P=$(pkg_pid "$pkg")
		[ -n "$P" ] || continue
		if pid_is_foreground "$P"; then
			if apply_unclamp "$P"; then
				APPLIED=$((APPLIED + 1))
				HIT=1
			fi
		fi
	done

	N=$((N + 1))
	if [ $((N % 40)) -eq 1 ]; then
		say "TICK|elapsed_s=$((EL / 100)).$((EL % 100 / 10))|applied=$APPLIED|fg=$HIT|j=$J|s=$S"
	fi
	sleep "$UNCLAMP_IVAL"
done
