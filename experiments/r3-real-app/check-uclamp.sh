#!/system/bin/sh
# Reusable boost-exit-invariant check: confirm uclamp.min=0 on every thread
# of a given pid. Standalone (post-session audit) or called from run-one.sh's
# cleanup() via common.sh's verify_boost_clean. See docs/METHODOLOGY.md,
# "Safety invariant: boost exit must be verified".
#
# usage: sh check-uclamp.sh PID
# exit 0 CLEAN, 1 RESIDUE, 2 usage
DIR=$(dirname "$0")
. "$DIR/common.sh"

PID="$1"
[ -n "$PID" ] || { echo "usage: check-uclamp.sh PID"; exit 2; }

if verify_boost_clean "$PID"; then
	echo "CLEAN pid=$PID"
	exit 0
else
	echo "RESIDUE pid=$PID -- run reset-uclamp.sh $PID"
	exit 1
fi
