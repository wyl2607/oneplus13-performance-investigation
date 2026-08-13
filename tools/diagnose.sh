#!/system/bin/sh
#
# diagnose.sh - is an app's sustained CPU work being clamped off the prime cores?
#
# STRICTLY READ-ONLY. This script does not write to any file, kernel node, module
# parameter or property. It only reads /proc and /sys and prints what it found.
#
# Root is required: reading another process's scheduler state is privileged.
#
# usage:
#   adb push tools/diagnose.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/diagnose.sh <package>'
#
#   e.g.  sh /data/local/tmp/diagnose.sh com.primatelabs.parkdale
#
# Run it WHILE the app is doing sustained CPU work, not while it sits idle.
#
# Nothing here is specific to Geekbench. Any package that keeps a thread busy
# for more than a few seconds will do.

PKG="$1"

say()  { printf '%s\n' "$*"; }
kv()   { printf '  %-26s %s\n' "$1" "$2"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }

if [ -z "$PKG" ]; then
	say "usage: sh diagnose.sh <package-name>"
	say "   run it while the app is under sustained CPU load"
	exit 2
fi

if [ "$(id -u)" != "0" ]; then
	say "ERROR: root required - reading another process's scheduler state is privileged."
	exit 2
fi

say ""
say "OnePlus / OPLUS sustained-load diagnostic"
rule

# ---------------------------------------------------------------- device
MODEL=$(getprop ro.product.model)
SOC=$(getprop ro.soc.model)
[ -z "$SOC" ] && SOC=$(getprop ro.board.platform)
kv "Model"        "${MODEL:-unknown}"
kv "SoC"          "${SOC:-unknown}"
kv "Android"      "$(getprop ro.build.version.release)"
kv "Build"        "$(getprop ro.build.version.incremental)"
kv "Kernel"       "$(uname -r)"

# ---------------------------------------------------------------- topology
# Resolve the fastest cluster rather than assuming CPU6/7, so this is meaningful
# on other OPLUS devices with different layouts.
PRIME_CPUS=""; MID_CPUS=""; MAXCAP=0
for c in /sys/devices/system/cpu/cpu[0-9]*; do
	n="${c##*/cpu}"
	[ -r "$c/cpu_capacity" ] || continue
	read cap < "$c/cpu_capacity"
	[ "$cap" -gt "$MAXCAP" ] && MAXCAP="$cap"
done
for c in /sys/devices/system/cpu/cpu[0-9]*; do
	n="${c##*/cpu}"
	[ -r "$c/cpu_capacity" ] || continue
	read cap < "$c/cpu_capacity"
	if [ "$cap" -eq "$MAXCAP" ]; then PRIME_CPUS="$PRIME_CPUS$n "; else MID_CPUS="$MID_CPUS$n "; fi
done
kv "Fastest cores (capacity $MAXCAP)" "CPU: $PRIME_CPUS"
kv "Other cores"  "CPU: $MID_CPUS"

# ---------------------------------------------------------------- module
TOL=/proc/task_overload/abnormal_task
if [ -e "$TOL" ]; then
	TOLSTATE="present"
elif grep -q oplus_bsp_task_overload /proc/modules 2>/dev/null; then
	TOLSTATE="module loaded, /proc/task_overload not readable"
else
	TOLSTATE="NOT present on this device"
fi
kv "oplus_bsp_task_overload" "$TOLSTATE"

say ""
rule
say "TARGET: $PKG"
rule

PID=$(pidof "$PKG" 2>/dev/null); PID="${PID%% *}"
if [ -z "$PID" ]; then
	say "  not running. Start the app, put it under load, and run this again."
	exit 1
fi
kv "PID" "$PID"

# ---------------------------------------------------------------- threads
# One awk pass over every thread: name and tid come from line 1 of .../sched,
# so no dependence on FILENAME.
say ""
say "  Threads with a reduced uclamp.max (1024 = untouched):"
CLAMPED=$(awk '
	FNR==1 {
		o = index($0, "(")
		if (o == 0) { cur = "?"; next }
		nm = substr($0, 1, o - 1); gsub(/[ \t]/, "", nm)
		rest = substr($0, o + 1); c = index(rest, ",")
		cur = (c > 0) ? substr(rest, 1, c - 1) : "?"
		gsub(/[ \t]/, "", cur)
		name[cur] = nm; order[++k] = cur
		next
	}
	/^uclamp\.max /       { umx[cur] = $NF }
	/^se\.avg\.util_avg / { ua[cur]  = $NF }
	END {
		for (i = 1; i <= k; i++) {
			t = order[i]
			if (umx[t] != "" && umx[t] != 1024)
				printf "    TID %-8s %-18s uclamp.max=%-6s util_avg=%s\n", t, name[t], umx[t], ua[t]
		}
	}' /proc/$PID/task/*/sched 2>/dev/null)

if [ -n "$CLAMPED" ]; then
	printf '%s\n' "$CLAMPED"
	NCLAMP=$(printf '%s\n' "$CLAMPED" | wc -l)
else
	say "    none"
	NCLAMP=0
fi

# Where are the busiest threads actually running?
say ""
say "  Currently-running threads of this app, and which CPU they are on:"
RUN=$(awk '{
		tid = $1
		c = index($0, ") ")
		if (c == 0) next
		n = split(substr($0, c + 2), f, " ")
		if (n < 37) next
		if (f[1] == "R") printf "    TID %-8s CPU%s\n", tid, f[37]
	}' /proc/$PID/task/*/stat 2>/dev/null)
[ -n "$RUN" ] && printf '%s\n' "$RUN" || say "    none runnable at this instant"

# ---------------------------------------------------------------- prime cores
say ""
say "  Fastest cores right now:"
for n in $PRIME_CPUS; do
	F=NA
	[ -r "/sys/devices/system/cpu/cpu$n/cpufreq/scaling_cur_freq" ] && \
		read F < "/sys/devices/system/cpu/cpu$n/cpufreq/scaling_cur_freq"
	MN=NA
	[ -r "/sys/devices/system/cpu/cpu$n/cpufreq/cpuinfo_min_freq" ] && \
		read MN < "/sys/devices/system/cpu/cpu$n/cpufreq/cpuinfo_min_freq"
	if [ "$F" = "$MN" ]; then STATE="at minimum - idle"; else STATE=""; fi
	kv "CPU$n" "$((F / 1000)) MHz  $STATE"
done

# ---------------------------------------------------------------- the table
if [ -r "$TOL" ]; then
	say ""
	say "  /proc/task_overload/abnormal_task  (limit_flag 1024 = not clamped):"
	head -1 "$TOL" 2>/dev/null | sed 's/^/    /'
	grep -v "1024" "$TOL" 2>/dev/null | tail -8 | sed 's/^/    /'
fi

# ---------------------------------------------------------------- thermal
say ""
say "  Is this thermal? (it usually is not)"
for z in /sys/class/thermal/thermal_zone*; do
	[ -r "$z/type" ] || continue
	read t < "$z/type"
	case "$t" in
		cpu-1-1-1|shell_front)
			read v < "$z/temp" 2>/dev/null
			kv "$t" "$((v / 1000)) C" ;;
	esac
done
TS=$(dumpsys thermalservice 2>/dev/null | grep -m1 "Thermal Status")
kv "Android" "${TS:-unavailable}"

# ---------------------------------------------------------------- verdict
say ""
rule
if [ "$NCLAMP" -gt 0 ]; then
	say "RESULT: $NCLAMP thread(s) of this app have a reduced uclamp.max."
	say ""
	say "  The scheduler is being told these threads need less CPU than they"
	say "  actually use, so it has no reason to place them on the fastest"
	say "  cores. If those cores read 'idle' above while the app is working"
	say "  hard, that is the effect."
	say ""
	say "  This is not a hardware fault and not thermal throttling."
	say "  See docs/FOR-USERS.md."
else
	say "RESULT: no clamped threads seen at this instant."
	say ""
	say "  If the app was idle, or had only just started, run this again"
	say "  a few seconds into sustained CPU work - on the reference device"
	say "  the clamp lands 5-30 s after the load begins."
fi
rule
say ""
