#!/system/bin/sh
# scheduler-event-tracer.sh - S2a event-level tracer for one thread's wake path.
#
# Purpose:
#   S1 answered its questions with a 250 ms sampler and then ran out of
#   resolution: wake, enqueue, CPU selection, switch-in and migration all happen
#   between two samples. This records those events themselves, for one TID, so a
#   wake cycle can be reconstructed instead of inferred.
#
# It adds instrumentation only. It sets no uclamp, no affinity, no cpuset, no
# frequency, and it does not touch the shipped module's parameters.
#
# Isolation:
#   Everything happens inside its own tracefs instance. The global buffer, the
#   globally enabled events (this ROM ships 16 of them, sde/camera/bpf_trace)
#   and the pre-existing instances (bootreceiver, hsuart, wifi) are never
#   written. Teardown is `rmdir`, which frees the whole buffer.
#
# Filtering is kernel-side, per event, on the target pid. Nothing is filtered in
# userspace. There is no per-event work in this script at all: it enables, waits,
# disables, and copies the buffer once -- so, unlike the S1 observer, its cost
# does not scale with the number of events.
#
# trace_clock is forced to `global`. A new instance defaults to `local`, whose
# timestamps are per-CPU and NOT comparable across CPUs; a wake on one CPU and a
# switch-in on another cannot be ordered under it. See T6.
#
# --comm is the one concession to name matching, and it exists for exactly one
# question: a thread's *first* enqueue cannot be traced by tid, because the tid
# is not known until the thread exists and by then WALT has already built some
# demand for it. A comm glob arms the filter before the thread is born. Identity
# by name is weaker than identity by tid -- the S1 observer refuses it on
# purpose -- so this mode records every tid it saw and the caller must check
# that only the intended one matched.
#
# --uclamp-offsets adds a kprobe on uclamp_eff_value that reads the task's
# requested and effective uclamp out of its task_struct at the moment the
# scheduler asks for them. No tracepoint on this kernel carries a numeric uclamp
# value, and BTF-typed kprobe arguments are rejected here, so the probe needs
# literal byte offsets -- which are kernel-build-specific. It will not guess
# them: derive them with tools/btf-offsets.py from this device's own
# /sys/kernel/btf/vmlinux and pass them in. It also fires far more often than a
# placement does (measured ~23 times per placement for one thread), so it is off
# unless asked for.
#
# usage:
#   su -c 'sh scheduler-event-tracer.sh {--tid TID | --comm GLOB} [--duration S]
#          [--out FILE] [--buffer-kb KB] [--energy] [--label L]
#          [--uclamp-offsets PID,UCLAMP_REQ,UCLAMP,SE_SIZE]'
#
# defaults:
#   --duration 10   --buffer-kb 4096 (per CPU)   --out stdout
#
# exit codes:
#   0 ok   2 usage   3 already running   4 no such tid   5 event loss   130 signal

T=/sys/kernel/tracing
INST_NAME=s2a
LOCK=/data/local/tmp/op13-scheduler-event-tracer.lock
TID=""
COMM_GLOB=""
DURATION=10
OUT=""
BUFKB=4096
ENERGY=0
LABEL=""
UCLAMP_OFF=""
I=""
HELD_LOCK=0
KPROBE_ON=0
KPROBE_NAME=s2a_uclamp

while [ $# -gt 0 ]; do
	case "$1" in
		--tid)       TID=$2; shift 2 ;;
		--comm)      COMM_GLOB=$2; shift 2 ;;
		--duration)  DURATION=$2; shift 2 ;;
		--out)       OUT=$2; shift 2 ;;
		--buffer-kb) BUFKB=$2; shift 2 ;;
		--label)     LABEL=$2; shift 2 ;;
		--energy)    ENERGY=1; shift ;;
		--uclamp-offsets) UCLAMP_OFF=$2; shift 2 ;;
		-h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
		*)           echo "ERROR: unknown argument $1" >&2; exit 2 ;;
	esac
done

if [ -n "$TID" ] && [ -n "$COMM_GLOB" ]; then
	echo "ERROR: pass --tid or --comm, not both" >&2; exit 2
fi
if [ -z "$TID" ] && [ -z "$COMM_GLOB" ]; then
	echo "ERROR: pass --tid TID or --comm GLOB" >&2; exit 2
fi
[ -n "$TID" ] && { case "$TID" in ''|*[!0-9]*) echo "ERROR: --tid must be an integer" >&2; exit 2 ;; esac; }
case "$DURATION" in ''|*[!0-9]*) echo "ERROR: --duration must be an integer" >&2; exit 2 ;; esac
case "$BUFKB"    in ''|*[!0-9]*) echo "ERROR: --buffer-kb must be an integer" >&2; exit 2 ;; esac
[ "$DURATION" -ge 1 ] && [ "$DURATION" -le 120 ] || {
	echo "ERROR: --duration must be 1..120 s. This tracer snapshots the buffer at" >&2
	echo "       the end instead of draining it, so a long run trades directly" >&2
	echo "       against --buffer-kb and is rejected rather than silently lossy." >&2
	exit 2
}
# The floor is 8, not a comfortable value: T4 has to be able to *cause* event
# loss with the real tracer, not with a copy of it. Anything under 256 is a
# deliberate loss test and says so.
[ "$BUFKB" -ge 8 ] || { echo "ERROR: --buffer-kb must be >= 8" >&2; exit 2; }
[ "$BUFKB" -lt 256 ] && echo "NOTE: --buffer-kb $BUFKB is a loss-test size, not a measurement size" >&2
[ "$(id -u)" = 0 ] || { echo "ERROR: must run as root" >&2; exit 2; }
[ -d "$T" ] || { echo "ERROR: no tracefs at $T" >&2; exit 2; }
if [ -n "$TID" ] && [ ! -e "/proc/$TID/stat" ]; then
	echo "ERROR: tid $TID is not alive" >&2; exit 4
fi

cleanup() {
	if [ "$KPROBE_ON" = 1 ]; then
		[ -n "$I" ] && echo 0 > "$I/events/kprobes/$KPROBE_NAME/enable" 2>/dev/null
		echo "-:$KPROBE_NAME" > "$T/kprobe_events" 2>/dev/null
		KPROBE_ON=0
	fi
	if [ -n "$I" ] && [ -d "$I" ]; then
		echo 0 > "$I/tracing_on" 2>/dev/null
		echo   > "$I/set_event"  2>/dev/null
		# filters live in the instance and die with it, but clear them anyway so
		# a failed rmdir cannot leave a filter behind under a name we reuse
		for e in $EVENTS; do echo 0 > "$I/events/$e/filter" 2>/dev/null; done
		echo   > "$I/trace" 2>/dev/null
		rmdir "$I" 2>/dev/null
	fi
	[ "$HELD_LOCK" = 1 ] && rm -rf "$LOCK"
	return 0
}
# mksh takes the status of the EXIT trap's last command, so an EXIT trap that
# ends in a successful rm turns `exit 130` into `exit 0`. Preserve $? explicitly.
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 130' TERM

if ! mkdir "$LOCK" 2>/dev/null; then
	if [ -f "$LOCK/pid" ] && [ -d "/proc/$(cat "$LOCK/pid" 2>/dev/null)" ]; then
		echo "ERROR: tracer already running as pid $(cat "$LOCK/pid")" >&2
		exit 3
	fi
	rm -rf "$LOCK"
	mkdir "$LOCK" 2>/dev/null || { echo "ERROR: cannot take lock $LOCK" >&2; exit 3; }
fi
HELD_LOCK=1
echo $$ > "$LOCK/pid"

# --- the event set ----------------------------------------------------------
# Every one of these takes a kernel-side filter on the target pid; verified in
# data/2026-08-22/s2a-tracing-capability.txt. sched_switch is the exception that
# needs two fields, because the target appears as prev on switch-out and as next
# on switch-in.
EVENTS="sched/sched_waking
sched/sched_wakeup
sched/sched_wakeup_new
sched/sched_switch
sched/sched_migrate_task
sched/sched_stat_wait
sched/sched_process_exit
schedwalt/sched_task_util
schedwalt/sched_enq_deq_task
schedwalt/sched_find_best_target
sched_assist/set_ux_task_to_prefer_cpu
frame_boost/find_frame_boost_cpu"
[ "$ENERGY" = 1 ] && EVENTS="$EVENTS
schedwalt/sched_compute_energy"

I="$T/instances/$INST_NAME"
[ -d "$I" ] && { echo "ERROR: instance $I already exists; refusing to reuse it" >&2; I=""; exit 3; }
mkdir "$I" || { echo "ERROR: cannot create tracing instance $I" >&2; I=""; exit 2; }

echo global > "$I/trace_clock"
CLOCK=$(sed 's/.*\[//;s/\].*//' "$I/trace_clock")
[ "$CLOCK" = global ] || { echo "ERROR: trace_clock is '$CLOCK', not global" >&2; exit 2; }
echo "$BUFKB" > "$I/buffer_size_kb"
BUFKB_REAL=$(cat "$I/buffer_size_kb")

MISSING=""
for e in $EVENTS; do
	[ -d "$I/events/$e" ] || MISSING="$MISSING $e"
done
[ -n "$MISSING" ] && { echo "ERROR: events not present on this kernel:$MISSING" >&2; exit 2; }

if [ -n "$COMM_GLOB" ]; then
	MATCH="$COMM_GLOB"
	FILTER_SWITCH="prev_comm ~ \"$COMM_GLOB\" || next_comm ~ \"$COMM_GLOB\""
	FILTER_OTHER="comm ~ \"$COMM_GLOB\""
	FILTER_DESC="comm ~ $COMM_GLOB (sched_switch: prev_comm||next_comm)"
else
	MATCH="$TID"
	FILTER_SWITCH="prev_pid==$TID || next_pid==$TID"
	FILTER_OTHER="pid==$TID"
	FILTER_DESC="pid==$TID (sched_switch: prev_pid||next_pid)"
fi

for e in $EVENTS; do
	case "$e" in
		sched/sched_switch) F=$FILTER_SWITCH ;;
		*)                  F=$FILTER_OTHER ;;
	esac
	echo "$F" > "$I/events/$e/filter" || { echo "ERROR: $e rejected filter '$F'" >&2; exit 2; }
	GOT=$(cat "$I/events/$e/filter")
	case "$GOT" in
		*"$MATCH"*) ;;
		*) echo "ERROR: $e filter did not take: '$GOT'" >&2; exit 2 ;;
	esac
done

for e in $EVENTS; do echo 1 > "$I/events/$e/enable"; done

if [ -n "$UCLAMP_OFF" ]; then
	O_PID=${UCLAMP_OFF%%,*};  R=${UCLAMP_OFF#*,}
	O_REQ=${R%%,*};           R=${R#*,}
	O_EFF=${R%%,*};           O_SE=${R#*,}
	for v in "$O_PID" "$O_REQ" "$O_EFF" "$O_SE"; do
		case "$v" in ''|*[!0-9]*)
			echo "ERROR: --uclamp-offsets wants PID,UCLAMP_REQ,UCLAMP,SE_SIZE as four" >&2
			echo "       byte offsets from tools/btf-offsets.py; got '$UCLAMP_OFF'" >&2
			exit 2 ;;
		esac
	done
	[ "$TID" ] || { echo "ERROR: --uclamp-offsets needs --tid, not --comm" >&2; exit 2; }
	KP="p:$KPROBE_NAME uclamp_eff_value tpid=+$O_PID(\$arg1):s32"
	KP="$KP req_min=+$O_REQ(\$arg1):x32 req_max=+$((O_REQ + O_SE))(\$arg1):x32"
	KP="$KP eff_min=+$O_EFF(\$arg1):x32 eff_max=+$((O_EFF + O_SE))(\$arg1):x32"
	echo "$KP" > "$T/kprobe_events" || {
		echo "ERROR: kernel rejected the uclamp kprobe: $(tail -2 "$T/error_log")" >&2
		exit 2
	}
	KPROBE_ON=1
	echo "tpid==$TID" > "$I/events/kprobes/$KPROBE_NAME/filter" || {
		echo "ERROR: could not filter the uclamp kprobe to tid $TID" >&2; exit 2; }
	echo 1 > "$I/events/kprobes/$KPROBE_NAME/enable"
fi

COMM=$([ -n "$TID" ] && cat "/proc/$TID/comm" 2>/dev/null)
T_START=$(cat /proc/uptime)
echo 1 > "$I/tracing_on"
sleep "$DURATION"
echo 0 > "$I/tracing_on"
T_END=$(cat /proc/uptime)
ALIVE=no; [ -n "$TID" ] && [ -e "/proc/$TID/stat" ] && ALIVE=yes

# --- loss accounting, before anything is read -------------------------------
ENTRIES=0; OVERRUN=0; DROPPED=0; COMMIT_OVERRUN=0
PERCPU=""
for c in 0 1 2 3 4 5 6 7; do
	[ -f "$I/per_cpu/cpu$c/stats" ] || continue
	s=$(cat "$I/per_cpu/cpu$c/stats")
	e=${s#*entries: }; e=${e%%
*}
	o=${s#*overrun: }; o=${o%%
*}
	d=${s#*dropped events: }; d=${d%%
*}
	k=${s#*commit overrun: }; k=${k%%
*}
	ENTRIES=$((ENTRIES + e)); OVERRUN=$((OVERRUN + o))
	DROPPED=$((DROPPED + d)); COMMIT_OVERRUN=$((COMMIT_OVERRUN + k))
	PERCPU="$PERCPU
# cpu$c entries=$e overrun=$o commit_overrun=$k dropped=$d"
done

emit() {
	echo "# scheduler-event-tracer"
	echo "# label=$LABEL"
	echo "# tid=$TID comm=$COMM comm_glob=$COMM_GLOB alive_at_end=$ALIVE"
	[ -n "$COMM_GLOB" ] && echo "# tids_matched=$(grep -o 'pid=[0-9]*' "$I/trace" | sort -u | tr '\n' ',')"
	echo "# duration_s=$DURATION uptime_start=$T_START uptime_end=$T_END"
	echo "# trace_clock=$CLOCK buffer_size_kb_per_cpu=$BUFKB_REAL instance=$INST_NAME"
	echo "# events=$(echo "$EVENTS" | tr '\n' ',')"
	echo "# filter=$FILTER_DESC"
	[ -n "$UCLAMP_OFF" ] && echo "# uclamp_kprobe=uclamp_eff_value offsets=$UCLAMP_OFF"
	echo "# entries=$ENTRIES overrun=$OVERRUN commit_overrun=$COMMIT_OVERRUN dropped=$DROPPED"
	echo "#$PERCPU"
	echo "# loss=$([ $((OVERRUN + DROPPED + COMMIT_OVERRUN)) -eq 0 ] && echo none || echo YES)"
	cat "$I/trace"
}

if [ -n "$OUT" ]; then emit > "$OUT"; else emit; fi

if [ $((OVERRUN + DROPPED + COMMIT_OVERRUN)) -ne 0 ]; then
	echo "ERROR: the kernel dropped events (overrun=$OVERRUN commit_overrun=$COMMIT_OVERRUN dropped=$DROPPED)." >&2
	echo "       The trace is incomplete and no causal conclusion may be drawn from it." >&2
	echo "       Raise --buffer-kb, shorten --duration, or drop --energy, and re-run." >&2
	exit 5
fi
exit 0
