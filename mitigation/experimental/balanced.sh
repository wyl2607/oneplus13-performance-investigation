#!/system/bin/sh
#
# balanced.sh - stock behaviour. A genuine no-op.
#
# This mode exists so the list is honest: leaving oplus_bsp_task_overload
# in place is a real choice. It writes nothing, changes nothing, and
# installs nothing.
#
# usage: sh balanced.sh

say() { printf '%s\n' "$*"; }

say "mode=balanced"
say "this is stock. no kernel node, module parameter, uclamp, cpuset,"
say "cpufreq or thermal tunable is written."
say ""
say "oplus_bsp_task_overload remains the runaway-thread guard."
say "that is the correct default: a lifted clamp drove junction p95 from"
say "52.1 C to 87.2 C on the reference device, peaking at 95.0 C, while"
say "the shell moved 35.0 C to 36.1 C. the phone still felt cool."
say ""
say "for a per-app allowlist see performance.sh"
say "for a supervised benchmark see extreme.sh --yes-junction-95c"
exit 0
