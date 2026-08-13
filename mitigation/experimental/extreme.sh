#!/system/bin/sh
#
# extreme.sh - opt-in, per-package, benchmark or active-cooling only.
#
# EXPERIMENTAL. The section 26 A/B lived in this regime and aborted at
# 98.4 C junction with the shell at 35.5 C. The phone still felt cool.
# Do not run this unattended, in a case, on a hot day, or as a boot
# service. Do not point it at every app on the device.
#
# Still one package. A global unclamp is not an acceptable design; see
# ../README.md. No foreground gate (a benchmark should not depend on
# cpuset spelling). Same 250 ms uclampset primitive, same 95 C / 42 C
# abort that fails back to stock.
#
# usage: sh extreme.sh --yes-junction-95c <package> [max_seconds]
#   max_seconds defaults to 600 if omitted.

HERE=$(dirname "$0")
. "$HERE/common.sh"

if [ "$1" != "--yes-junction-95c" ]; then
	say "usage: sh extreme.sh --yes-junction-95c <package> [max_seconds]"
	say ""
	say "refusing to start without --yes-junction-95c."
	say "lifting the clamp took junction p95 from 52.1 C to 87.2 C and"
	say "the peak to 95.0 C; shell moved 35.0 C to 36.1 C. android's"
	say "thermal framework escalates on skin, not junction. this mode"
	say "is for a supervised benchmark or an actively cooled run only."
	exit 2
fi
shift

PKG="$1"
MAX="${2:-600}"
if [ -z "$PKG" ]; then
	say "usage: sh extreme.sh --yes-junction-95c <package> [max_seconds]"
	exit 2
fi
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

say "mode=extreme"
say "package=$PKG  max_seconds=$MAX  interval=${UNCLAMP_IVAL}s"
say "abort junction>${J_ABORT} shell>${S_ABORT} (milli-C)"
say "junction_zone=$Z_J  shell_zone=$Z_S"
say "no foreground gate. still one package, not a global unclamp."
say "writes: uclampset only. on abort/timeout: stop resetting, stock returns."

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
		say "ABORT|junction=$J|shell=$S|applied=$APPLIED"
		exit 3
	fi

	P=$(pkg_pid "$PKG")
	if [ -n "$P" ]; then
		if apply_unclamp "$P"; then
			APPLIED=$((APPLIED + 1))
		fi
	fi

	N=$((N + 1))
	if [ $((N % 40)) -eq 1 ]; then
		say "TICK|elapsed_s=$((EL / 100)).$((EL % 100 / 10))|pid=${P:-none}|applied=$APPLIED|j=$J|s=$S"
	fi
	sleep "$UNCLAMP_IVAL"
done
