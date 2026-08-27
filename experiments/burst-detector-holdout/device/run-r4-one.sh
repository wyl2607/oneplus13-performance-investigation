#!/system/bin/sh
# run-r4-one.sh - one R4 burst-detector holdout run
# (experiments/burst-detector-holdout/README.md, r4-plan.csv).
#
# usage (as root, from /data/local/tmp):
#   sh run-r4-one.sh --run-id ID --workload WORKLOAD_ID
#                     --module-state module_on|module_off
#                     --out MANIFEST_LOG --observer-out TRACE_LOG
#                     [--package PKG] [--activity COMPONENT]
#                     [--duration S] [--swipe X1,Y1,X2,Y2,DURATION_MS]
#                     [--synth-uid UID]
#
# --package is required for the five interaction_transition workloads
# (app_launch_cold, app_launch_warm, app_switch, browser_scroll,
# camera_launch). It is a runtime argument only, never written to any file
# that gets committed -- same discipline as experiments/r3-real-app/run-one.sh
# (see docs/R3_REAL_APP_PILOT.md#app-privacy). --out lives under
# experiments/burst-detector-holdout/raw/ (gitignored via the repo-wide
# raw/ pattern) and must be sanitized before anything derived is committed.
#
# The four steady/background workloads (steady_game_title, steady_gameplay,
# video_playback, background_download) are HUMAN_ASSISTED: this script only
# captures for --duration seconds while a human keeps the real content
# running. It never fabricates am/input actions for them and never emits
# EVENT markers for them (README: "steady/background: cannot fake event
# latency").
#
# exit codes: 0 ok, 2 usage, 9 RUN_ABORT_THERMAL_92, 10 SESSION_STOP_THERMAL_95,
#             11 MODULE_SET_FAILED (module state could not be verified before
#             the workload ran -- this run's data is not valid and the whole
#             session should stop, since if module control is unreliable every
#             later run is compromised too), 12 CLEANUP_VERIFY_FAILED (module
#             could not be verified OFF afterwards; see the boost-exit
#             invariant, docs/METHODOLOGY.md)

DIR=$(dirname "$0")
. "$DIR/common.sh"

RUN_ID=""; WORKLOAD=""; MODULE_STATE=""; PACKAGE=""; ACTIVITY=""
DURATION=30; SWIPE="540,1500,540,600,300"; OUT=""; OBSERVER_OUT=""
SYNTH_UID=10999

while [ $# -gt 0 ]; do
	case "$1" in
		--run-id)        RUN_ID=$2; shift 2 ;;
		--workload)      WORKLOAD=$2; shift 2 ;;
		--module-state)  MODULE_STATE=$2; shift 2 ;;
		--package)       PACKAGE=$2; shift 2 ;;
		--activity)      ACTIVITY=$2; shift 2 ;;
		--duration)      DURATION=$2; shift 2 ;;
		--swipe)         SWIPE=$2; shift 2 ;;
		--out)           OUT=$2; shift 2 ;;
		--observer-out)  OBSERVER_OUT=$2; shift 2 ;;
		--synth-uid)     SYNTH_UID=$2; shift 2 ;;
		*) say "ERROR: unknown arg $1"; exit 2 ;;
	esac
done
for req in RUN_ID WORKLOAD MODULE_STATE OUT OBSERVER_OUT; do
	eval "v=\$$req"
	[ -n "$v" ] || { say "ERROR: --$(echo $req | tr 'A-Z' 'a-z' | tr '_' '-') is required"; exit 2; }
done
case "$MODULE_STATE" in
	module_on) MOD_WANT=1 ;;
	module_off) MOD_WANT=0 ;;
	*) say "ERROR: --module-state must be module_on or module_off, got: $MODULE_STATE"; exit 2 ;;
esac
case "$WORKLOAD" in
	app_launch_cold|app_launch_warm|app_switch|browser_scroll|camera_launch)
		[ -n "$PACKAGE" ] || { say "ERROR: --package required for workload $WORKLOAD"; exit 2; }
		;;
	steady_game_title|steady_gameplay|video_playback|background_download|synthetic_compute|synthetic_wake)
		;;
	*) say "ERROR: unknown workload $WORKLOAD"; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { say "ERROR: must run as root"; exit 2; }
command -v uclampset >/dev/null 2>&1 || { say "ERROR: uclampset not on PATH"; exit 2; }

resolve_zones || exit 2

WORKDIR=/data/local/tmp/op13-r4
mkdir -p "$WORKDIR" 2>/dev/null
: > "$OUT"
SYNTH_PIDFILE="$WORKDIR/synth.$RUN_ID.pid"
rm -f "$SYNTH_PIDFILE"

cleanup() {
	# Kill any synthetic worker first so it stops contending before the
	# module is switched off underneath it.
	if [ -f "$SYNTH_PIDFILE" ]; then
		read _sp < "$SYNTH_PIDFILE" 2>/dev/null
		[ -n "$_sp" ] && kill -9 "$_sp" 2>/dev/null
		rm -f "$SYNTH_PIDFILE"
	fi
	# Boost-exit invariant (docs/METHODOLOGY.md): force module_off, verify by
	# read-back, one retry, fail closed with a distinct status and a
	# persistent on-device marker rather than a silent "clean" claim.
	if set_module_state 0; then
		if verify_no_residual_lift >>"$OUT.cleanup_verify" 2>&1; then
			return 0
		fi
	fi
	say "RESULT run_id=$RUN_ID status=CLEANUP_VERIFY_FAILED see=$OUT.cleanup_verify" >> "$OUT"
	: > "$WORKDIR/CLEANUP_FAILED.$RUN_ID"
	CLEANUP_FAILED=1
}
CLEANUP_FAILED=0
trap 'cleanup; exit 130' INT TERM

# --- preflight ---
say "#META run_id=$RUN_ID workload=$WORKLOAD module_state=$MODULE_STATE" >> "$OUT"
SCR=$(dumpsys display 2>/dev/null | grep -m1 mScreenState)
say "#META screen=${SCR:-unavailable}" >> "$OUT"
case "$SCR" in
	*ON*|*on*) ;;
	*) say "WARNING: screen does not look ON (METHODOLOGY trap 2)" >> "$OUT" ;;
esac
check_thermal
say "#META start_junction_c=$((THERMAL_J / 1000)) start_shell_c=$((THERMAL_S / 1000))" >> "$OUT"
if [ "$THERMAL_LEVEL" -ge 1 ]; then
	say "RESULT run_id=$RUN_ID status=THERMAL_ABOVE_SOFT_GATE_AT_START j=$THERMAL_J s=$THERMAL_S" >> "$OUT"
	exit 9
fi

# --- apply the independent variable: module state ---
if ! set_module_state "$MOD_WANT"; then
	say "RESULT run_id=$RUN_ID status=MODULE_SET_FAILED module_state=$MODULE_STATE" >> "$OUT"
	exit 11
fi

# --- start the read-only observer for the capture window ---
# Padding: the observer must outlive the workload action so the tail of the
# capture is not truncated mid-interaction. dominant-thread-observer.sh is
# pushed alongside this script into the same flat device directory by
# tools/run-r4-holdout.py's AdbDevice.push_scripts() -- it is NOT reached via
# the host repo's tools/ layout, which does not exist on-device.
OBS_DURATION=$((DURATION + 5))
( sh "$DIR/dominant-thread-observer.sh" "$OBS_DURATION" 250 5 > "$OBSERVER_OUT" 2>>"$OUT.observer_stderr" ) &
OBSERVER_PID=$!
sleep 0.3

# --- run the workload action ---
STATUS=OK
T_START_CS=$(now_cs)

case "$WORKLOAD" in
	app_launch_cold)
		am force-stop "$PACKAGE" >/dev/null 2>&1
		sleep 0.5
		_target="$PACKAGE"
		[ -n "$ACTIVITY" ] && _target="$PACKAGE/$ACTIVITY"
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(now_ms)" >> "$OUT"
		AMOUT=$(am start -W -n "$_target" 2>&1)
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(now_ms)" >> "$OUT"
		say "#AM_START $AMOUT" >> "$OUT"
		EVENT_MS=$(printf '%s\n' "$AMOUT" | sed -n 's/^TotalTime: //p')
		[ -n "$EVENT_MS" ] || STATUS=NO_TOTALTIME_PARSED
		sleep "$DURATION"
		;;
	app_launch_warm)
		_target="$PACKAGE"
		[ -n "$ACTIVITY" ] && _target="$PACKAGE/$ACTIVITY"
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(now_ms)" >> "$OUT"
		AMOUT=$(am start -W -n "$_target" 2>&1)
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(now_ms)" >> "$OUT"
		say "#AM_START $AMOUT" >> "$OUT"
		EVENT_MS=$(printf '%s\n' "$AMOUT" | sed -n 's/^TotalTime: //p')
		[ -n "$EVENT_MS" ] || STATUS=NO_TOTALTIME_PARSED
		sleep "$DURATION"
		;;
	app_switch)
		_target="$PACKAGE"
		[ -n "$ACTIVITY" ] && _target="$PACKAGE/$ACTIVITY"
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(now_ms)" >> "$OUT"
		AMOUT=$(am start -W -n "$_target" 2>&1)
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(now_ms)" >> "$OUT"
		say "#AM_START $AMOUT" >> "$OUT"
		EVENT_MS=$(printf '%s\n' "$AMOUT" | sed -n 's/^TotalTime: //p')
		[ -n "$EVENT_MS" ] || STATUS=NO_TOTALTIME_PARSED
		sleep "$DURATION"
		;;
	browser_scroll)
		dumpsys gfxinfo "$PACKAGE" reset >/dev/null 2>&1
		sleep 0.3
		X1=$(echo "$SWIPE" | cut -d, -f1); Y1=$(echo "$SWIPE" | cut -d, -f2)
		X2=$(echo "$SWIPE" | cut -d, -f3); Y2=$(echo "$SWIPE" | cut -d, -f4)
		SDUR=$(echo "$SWIPE" | cut -d, -f5)
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(now_ms)" >> "$OUT"
		_n=0
		while [ "$_n" -lt "$DURATION" ]; do
			input swipe "$X1" "$Y1" "$X2" "$Y2" "$SDUR" >/dev/null 2>&1
			sleep 0.5
			_n=$((_n + 1))
		done
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(now_ms)" >> "$OUT"
		GFX=$(dumpsys gfxinfo "$PACKAGE" 2>/dev/null)
		say "#GFXINFO_BEGIN" >> "$OUT"
		printf '%s\n' "$GFX" | grep -E 'Total frames rendered|Janky frames|Number Missed Vsync|90th percentile|95th percentile|99th percentile' >> "$OUT"
		say "#GFXINFO_END" >> "$OUT"
		;;
	camera_launch)
		am force-stop "$PACKAGE" >/dev/null 2>&1
		sleep 0.5
		_target="$PACKAGE"
		[ -n "$ACTIVITY" ] && _target="$PACKAGE/$ACTIVITY"
		say "EVENT|event_id=$RUN_ID|phase=start|t_ms=$(now_ms)" >> "$OUT"
		AMOUT=$(am start -W -n "$_target" 2>&1)
		say "EVENT|event_id=$RUN_ID|phase=end|t_ms=$(now_ms)" >> "$OUT"
		say "#AM_START $AMOUT" >> "$OUT"
		EVENT_MS=$(printf '%s\n' "$AMOUT" | sed -n 's/^TotalTime: //p')
		[ -n "$EVENT_MS" ] || STATUS=NO_TOTALTIME_PARSED
		sleep "$DURATION"
		;;
	steady_game_title|steady_gameplay|video_playback|background_download)
		# HUMAN_ASSISTED: the host driver has already paused and prompted a
		# human to have the real content running before invoking this
		# script. No am/input actions, no EVENT markers -- just hold the
		# capture window open.
		say "#META human_assisted=yes" >> "$OUT"
		sleep "$DURATION"
		;;
	synthetic_compute|synthetic_wake)
		# Same spin/burst-sleep algorithm as experiments/real-workloads/worker.sh,
		# inlined so this directory pushes as a single self-contained unit.
		# synthetic_compute spins with no sleep; synthetic_wake bursts then
		# sleeps, matching the S1 mechanism-control pair (workloads.csv).
		# Forced directly into the top-app cgroup by pid, rather than relying
		# on a real foreground app to carry it there, so the synthetic
		# control does not depend on any specific installed app. This
		# top-app-membership assumption is exactly what Phase 7's overhead
		# validation must confirm before the holdout is trusted (README,
		# "Overhead validation").
		if [ "$WORKLOAD" = "synthetic_compute" ]; then
			_burst_n=0; _burst_s=0
		else
			_burst_n=2000000; _burst_s=0.2
		fi
		(
			su "$SYNTH_UID" -c "
				N=$_burst_n; S=$_burst_s
				if [ \"\$N\" = 0 ]; then
					i=0; while : ; do i=\$((i+1)); done
				else
					while : ; do
						i=0
						while [ \$i -lt \$N ]; do i=\$((i+1)); done
						sleep \$S
					done
				fi
			" &
			echo $! > "$SYNTH_PIDFILE"
			wait
		) &
		_w=0
		while [ "$_w" -lt 30 ]; do
			[ -s "$SYNTH_PIDFILE" ] && break
			sleep 0.1
			_w=$((_w + 1))
		done
		if [ -s "$SYNTH_PIDFILE" ]; then
			read _sp < "$SYNTH_PIDFILE"
			echo "$_sp" > "$TOPAPP_PROCS" 2>/dev/null || \
				say "WARNING: could not force pid $_sp into top-app cpuset" >> "$OUT"
		else
			say "WARNING: synthetic worker pidfile never appeared" >> "$OUT"
			STATUS=SYNTH_WORKER_NOT_STARTED
		fi
		sleep "$DURATION"
		;;
esac

T_END_CS=$(now_cs)
kill "$OBSERVER_PID" 2>/dev/null
wait "$OBSERVER_PID" 2>/dev/null

check_thermal
say "#META end_junction_c=$((THERMAL_J / 1000)) end_shell_c=$((THERMAL_S / 1000))" >> "$OUT"
if [ "$THERMAL_LEVEL" -eq 2 ]; then
	STATUS=SESSION_STOP_THERMAL_95
elif [ "$THERMAL_LEVEL" -eq 1 ]; then
	STATUS=RUN_ABORT_THERMAL_92
fi

cleanup

WALL_CS=$((T_END_CS - T_START_CS))
say "RESULT run_id=$RUN_ID workload=$WORKLOAD module_state=$MODULE_STATE wall_cs=$WALL_CS event_ms=${EVENT_MS:-NA} status=$([ "$CLEANUP_FAILED" = 1 ] && echo CLEANUP_VERIFY_FAILED || echo $STATUS) out=$OUT observer_out=$OBSERVER_OUT" >> "$OUT"

[ "$CLEANUP_FAILED" = 1 ] && exit 12
[ "$STATUS" = "SESSION_STOP_THERMAL_95" ] && exit 10
[ "$STATUS" = "RUN_ABORT_THERMAL_92" ] && exit 9
exit 0
