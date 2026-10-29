#!/system/bin/sh
#
# qos-writer-hunt.sh - who else is moving policy->max?
#
# `scaling_max_freq` was observed leaving the op13perf level's values during a
# GB7 run -- sometimes to rated (a release), sometimes to a hard clamp. A fast
# sampler showed the ceilings rock-stable at idle (400/400) and under an
# eight-core root-uid load (600/600), so the writer was neither perfd's own
# 250 ms re-assert nor load alone. This finds it by name.
#
# It kprobes freq_qos_update_request -- the single choke point every freq_qos
# min/max change goes through -- in its OWN tracefs instance, and filters out
# the op13perf daemon's pid kernel-side, so whatever still shows up is the
# contender. DATA.md section 44 records the answer:
# /odm/bin/hw/vendor.oplus.hardware.urcc-service.
#
# Read-only apart from its own tracefs instance, which it removes on the way out.
#
# usage:
#   adb push tools/qos-writer-hunt.sh /data/local/tmp/
#   adb shell su -M -c 'sh /data/local/tmp/qos-writer-hunt.sh 60'
#
# Run it WHILE a real foreground app is ramping up. URCC is quiescent otherwise,
# which is exactly why idle sampling never caught it.

T=/sys/kernel/tracing
I=$T/instances/qoshunt
SECS=${1:-60}

[ -d "$T" ] || { echo "no tracefs at $T"; exit 2; }

PERFD=$(cat /data/adb/op13perf/pid 2>/dev/null)
[ -n "$PERFD" ] || PERFD=$(ps -A -o pid,args 2>/dev/null | grep -m1 '[p]erfd.sh' | awk '{print $1}')

mkdir -p "$I" 2>/dev/null
# A fresh instance defaults to the per-CPU `local` clock, under which causal
# pairings come out wrong while reporting zero inversions (SCHEDULER_EVENT_TRACER T6).
echo global > "$I/trace_clock" 2>/dev/null
echo 16384 > "$I/buffer_size_kb" 2>/dev/null
echo 0 > "$I/tracing_on" 2>/dev/null

echo '-:qosupd' >> "$T/kprobe_events" 2>/dev/null
echo 'p:qosupd freq_qos_update_request val=$arg2:s32' >> "$T/kprobe_events" || {
	echo "could not create the kprobe"; rmdir "$I" 2>/dev/null; exit 3; }
[ -d "$I/events/kprobes/qosupd" ] || {
	echo "probe not visible in the instance"; rmdir "$I" 2>/dev/null; exit 3; }

if [ -n "$PERFD" ]; then
	echo "common_pid != $PERFD" > "$I/events/kprobes/qosupd/filter"
	echo "# excluding op13perf daemon pid $PERFD; filter reads back as: $(cat $I/events/kprobes/qosupd/filter)"
else
	echo "# WARNING: op13perf daemon pid not found, its own 4 Hz writes are NOT filtered out"
fi

echo 1 > "$I/events/kprobes/qosupd/enable"
echo 0 > "$I/trace"
echo 1 > "$I/tracing_on"
sleep "$SECS"
echo 0 > "$I/tracing_on"

# Loss accounting is read BEFORE the buffer is, so a truncated capture cannot be
# mistaken for a quiet one.
echo "# $(grep -i '^overrun' "$I/per_cpu/cpu0/stats" 2>/dev/null)"
cat "$I/trace"

echo 0 > "$I/events/kprobes/qosupd/enable"
echo '-:qosupd' >> "$T/kprobe_events"
rmdir "$I" 2>/dev/null
