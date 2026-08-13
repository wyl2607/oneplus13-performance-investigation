#!/system/bin/sh
#
# collect-report.sh - one pasteable device report for this investigation.
#
# STRICTLY READ-ONLY. Does not write to any file, kernel node, module
# parameter or property. Does not call logcat. Reads /proc, /sys, getprop
# and dumpsys, and prints what it found.
#
# Root is required for the useful parts (the abnormal_task table and
# another process's scheduler state). Without root the script still prints
# topology and then says what it could not read.
#
# usage:
#   adb push tools/collect-report.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/collect-report.sh [package]'
#
# Any uid >= 10000 is redacted to 10xxx in this script's own output before
# it is printed. Still check before you paste.
#
# Prime/mid clusters are resolved from cpu_capacity. Do not assume CPU6/7.
#
# mksh notes (both have already bitten this project):
#   - do not use ${var#*(} / ${var%)*}; mksh can swallow the rest of the file
#   - do not sed -i a script on the device to strip CRs (METHODOLOGY trap 5)

PKG="$1"

say()  { printf '%s\n' "$*"; }
kv()   { printf '  %-28s %s\n' "$1" "$2"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }

# Redact field 2 of a whitespace-separated table when it looks like an app uid.
# Collapses runs of whitespace; the table remains readable. Header is passed
# through. Applied only to lines we know are table-shaped.
redact_uid_field2() {
	awk '
		NR == 1 { print; next }
		{
			if ($2 + 0 >= 10000) $2 = "10xxx"
			print
		}
	'
}

say ""
say "BEGIN oneplus13-performance-investigation report"
rule

if [ "$(id -u)" != "0" ]; then
	say "NOTE: not root. Table and per-thread uclamp will be missing."
fi

# ---------------------------------------------------------------- identity
MODEL=$(getprop ro.product.model)
SOC=$(getprop ro.soc.model)
[ -z "$SOC" ] && SOC=$(getprop ro.board.platform)
BUILD=$(getprop ro.build.version.incremental)
FP=$(getprop ro.build.fingerprint)
# Fingerprint can be long; keep it, it identifies a build not a handset.
kv "Model"   "${MODEL:-unknown}"
kv "Build"   "${BUILD:-unknown}"
kv "Fingerprint" "${FP:-unknown}"
kv "Android" "$(getprop ro.build.version.release)"
kv "Kernel"  "$(uname -r)"
kv "SoC"     "${SOC:-unknown}"

# Screen state is not in the required field list, but trap 2 made a whole
# round of numbers meaningless. One line, read-only.
SCR=$(dumpsys display 2>/dev/null | grep -m1 mScreenState)
WAKE=$(dumpsys power 2>/dev/null | grep -m1 mWakefulness=)
kv "Screen"  "${SCR:-unavailable}"
kv "Wake"    "${WAKE:-unavailable}"

# ---------------------------------------------------------------- cpu_capacity, every CPU
say ""
say "cpu_capacity"
# cpu[0-9]* avoids the cpu/cpufreq directory. Sort by the numeric suffix
# without assuming how many cores there are.
for c in /sys/devices/system/cpu/cpu[0-9]*; do
	n="${c##*/cpu}"
	[ -r "$c/cpu_capacity" ] || continue
	read cap < "$c/cpu_capacity"
	printf '  cpu%s=%s\n' "$n" "$cap"
done

# Fastest cluster, same rule as diagnose.sh, for the human reading this.
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
	if [ "$cap" -eq "$MAXCAP" ]; then
		PRIME_CPUS="$PRIME_CPUS$n "
	else
		MID_CPUS="$MID_CPUS$n "
	fi
done
kv "Fastest cores (cap $MAXCAP)" "CPU: $PRIME_CPUS"
kv "Other cores"                 "CPU: $MID_CPUS"

# ---------------------------------------------------------------- cpufreq policies
say ""
say "cpufreq policies"
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -d "$p" ] || continue
	name="${p##*/}"
	rel=NA; mn=NA; mx=NA; gov=NA; cur=NA; hw=NA; smn=NA
	[ -r "$p/related_cpus" ]              && read rel < "$p/related_cpus"
	[ -r "$p/cpuinfo_min_freq" ]          && read mn  < "$p/cpuinfo_min_freq"
	[ -r "$p/scaling_max_freq" ]          && read mx  < "$p/scaling_max_freq"
	[ -r "$p/cpuinfo_max_freq" ]          && read hw  < "$p/cpuinfo_max_freq"
	[ -r "$p/scaling_governor" ]          && read gov < "$p/scaling_governor"
	[ -r "$p/scaling_cur_freq" ]          && read cur < "$p/scaling_cur_freq"
	[ -r "$p/scaling_min_freq" ]          && read smn < "$p/scaling_min_freq"
	printf '  %s  cpus=%s  min=%s  max=%s  hw_max=%s  gov=%s  cur=%s\n' \
		"$name" "$rel" "${smn:-$mn}" "$mx" "${hw:-NA}" "$gov" "$cur"
done

# CFB is the secondary limiter and feeds this guard a lower prime clock.
# Brief, so a report still answers the older limit_level question.
say ""
say "cpufreq_bouncing"
CFB=/sys/module/cpufreq_bouncing/parameters
if [ -r "$CFB/config" ]; then
	kv "enable" "$(cat "$CFB/enable" 2>/dev/null)"
	grep -E "^clus|limit_freq|limit_level|limit_thres|max_freq" \
		"$CFB/config" 2>/dev/null | sed 's/^/  /'
else
	say "  not present"
fi

# ---------------------------------------------------------------- module + table
say ""
TOL=/proc/task_overload/abnormal_task
if grep -q oplus_bsp_task_overload /proc/modules 2>/dev/null; then
	MODSTATE="loaded"
else
	MODSTATE="not loaded"
fi
if [ -e "$TOL" ]; then
	if [ -r "$TOL" ]; then
		TOLSTATE="readable"
	else
		TOLSTATE="present, not readable"
	fi
else
	TOLSTATE="absent"
fi
kv "oplus_bsp_task_overload" "$MODSTATE"
kv "/proc/task_overload/abnormal_task" "$TOLSTATE"

say ""
say "abnormal_task (uid >= 10000 redacted to 10xxx; 1024 = not clamped)"
if [ -r "$TOL" ]; then
	# Entire table, not a tail. A device report needs every clamped row.
	redact_uid_field2 < "$TOL"
else
	say "  (not readable)"
fi

# ---------------------------------------------------------------- optional package
say ""
if [ -n "$PKG" ]; then
	say "uclamp.max for package: $PKG"
	PID=$(pidof "$PKG" 2>/dev/null); PID="${PID%% *}"
	if [ -z "$PID" ]; then
		say "  not running"
	elif [ ! -d "/proc/$PID/task" ]; then
		say "  pid=$PID but /proc/$PID/task not readable"
	else
		kv "PID" "$PID"
		# Name and tid from line 1 of .../sched via index(), never ${var#*(}.
		awk '
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
				if (k == 0) { print "  (no threads readable)"; exit }
				for (i = 1; i <= k; i++) {
					t = order[i]
					u = (umx[t] == "" ? "NA" : umx[t])
					a = (ua[t]  == "" ? "NA" : ua[t])
					printf "  TID %-8s %-18s uclamp.max=%-6s util_avg=%s\n", \
						t, name[t], u, a
				}
			}
		' /proc/$PID/task/*/sched 2>/dev/null
	fi
else
	say "uclamp.max for package: (none given; pass a package name to include it)"
fi

# ---------------------------------------------------------------- thermal, by name
say ""
say "thermal (zones by name, not index — METHODOLOGY trap 3)"
TS=$(dumpsys thermalservice 2>/dev/null | grep -m1 "Thermal Status")
kv "Thermal Status" "${TS:-unavailable}"

# Junction names on the reference unit are cpu-1-*-*; shell_* are skin.
# Print every match so a different OPLUS layout still produces a report.
for z in /sys/class/thermal/thermal_zone*; do
	[ -r "$z/type" ] || continue
	read t < "$z/type" 2>/dev/null || continue
	case "$t" in
		cpu-*|shell_*)
			read v < "$z/temp" 2>/dev/null || v=NA
			if [ "$v" != "NA" ] && [ -n "$v" ]; then
				kv "$t" "$v  ($((v / 1000)) C)"
			else
				kv "$t" "unreadable"
			fi
			;;
	esac
done

rule
say "END report"
say ""
