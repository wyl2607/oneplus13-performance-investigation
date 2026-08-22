#!/system/bin/sh
# dominant-thread-observer.sh - read-only S1 observer for top-app thread behaviour.
#
# Purpose:
#   Find the one or two threads that dominate short foreground windows, without
#   changing any kernel or Android performance state. This is the measurement
#   scaffold for the next phase of the project: burst / wake-heavy responsiveness.
#
# Reads only:
#   /dev/cpuset/top-app/tasks
#   /proc/<pid>/task/<tid>/{stat,schedstat,status,sched,comm}
#   /proc/uptime
#
# Writes only a temporary lock/work directory under /data/local/tmp and removes
# it on exit. It never writes sysfs, procfs tunables, cgroups, uclamp or affinity.
#
# usage:
#   su -c 'sh dominant-thread-observer.sh [duration_s] [interval_ms] [top_n]'
#
# defaults:
#   duration_s=30  interval_ms=250  top_n=5

TOPAPP=/dev/cpuset/top-app/tasks
LOCK=/data/local/tmp/op13-dominant-thread-observer.lock
DURATION=${1:-30}
INTERVAL_MS=${2:-250}
TOPN=${3:-5}
TMP=""

case "$DURATION" in ''|*[!0-9]*) echo "ERROR: duration_s must be an integer" >&2; exit 2 ;; esac
case "$INTERVAL_MS" in ''|*[!0-9]*) echo "ERROR: interval_ms must be an integer" >&2; exit 2 ;; esac
case "$TOPN" in ''|*[!0-9]*) echo "ERROR: top_n must be an integer" >&2; exit 2 ;; esac
[ "$DURATION" -ge 1 ] || { echo "ERROR: duration_s must be >= 1" >&2; exit 2; }
[ "$INTERVAL_MS" -ge 50 ] && [ "$INTERVAL_MS" -le 2000 ] || {
	echo "ERROR: interval_ms must be 50..2000" >&2; exit 2;
}
[ "$TOPN" -ge 1 ] && [ "$TOPN" -le 20 ] || { echo "ERROR: top_n must be 1..20" >&2; exit 2; }

[ "$(id -u 2>/dev/null)" = "0" ] || {
	echo "ERROR: run as root; Android normally hides other apps' /proc scheduling data" >&2
	exit 2
}
[ -r "$TOPAPP" ] || { echo "ERROR: missing $TOPAPP" >&2; exit 2; }

# Fractional sleep is supported by Android toybox. Calculate it once so the
# observer does not spawn awk merely to sleep on every sample.
SLEEP_S=$(awk -v ms="$INTERVAL_MS" 'BEGIN { printf "%.3f", ms / 1000 }')

# /proc/uptime is available on every target build. The first field has two
# decimal places here, so concatenating integer and fractional pieces gives
# centiseconds without relying on unsupported `date +%s%N`.
now_cs() {
	read a b < /proc/uptime || return 1
	echo "${a%.*}${a#*.}"
}

cleanup() {
	[ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null
	if [ -r "$LOCK/pid" ]; then
		read owner < "$LOCK/pid" 2>/dev/null
		[ "$owner" = "$$" ] && rm -rf "$LOCK" 2>/dev/null
	fi
}

# The repository has already had one measurement corrupted by two harnesses
# running at once. Keep the same fail-closed rule even though this tool is
# read-only: two observers double /proc scan overhead and distort the workload.
if ! mkdir "$LOCK" 2>/dev/null; then
	owner=""
	[ -r "$LOCK/pid" ] && read owner < "$LOCK/pid" 2>/dev/null
	if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
		echo "ERROR: observer already running as pid $owner" >&2
		exit 3
	fi
	rm -rf "$LOCK" 2>/dev/null
	mkdir "$LOCK" 2>/dev/null || { echo "ERROR: cannot acquire $LOCK" >&2; exit 3; }
fi
echo $$ > "$LOCK/pid"
TMP="$LOCK/work.$$"
mkdir "$TMP" || { cleanup; exit 3; }
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

# Return unique application TGIDs currently represented in the kernel top-app
# cpuset. Use status/Tgid rather than process-name matching: comm truncation has
# already caused false identification in this project. uid >= 10000 filters the
# framework/system processes that can share top-app during transitions.
top_tgids() {
	set --
	for t in $(cat "$TOPAPP" 2>/dev/null); do
		[ -r "/proc/$t/status" ] && set -- "$@" "/proc/$t/status"
	done
	[ $# -gt 0 ] || return 0
	awk '
		FNR == 1 { tg="" }
		/^Tgid:/ { tg=$2 }
		/^Uid:/  { if (tg != "" && $2 + 0 >= 10000) print tg }
	' "$@" 2>/dev/null | sort -nu
}

# Fast snapshot. Keep this deliberately small: all expensive status/sched reads
# are deferred until after ranking, and are done only for top_n threads.
#
# Columns (space-delimited; comm is sanitized):
#   tid tgid comm runtime_ns runqueue_wait_ns timeslices cpu
snapshot_fast() {
	out=$1
	tgids=$2
	: > "$out"
	for p in $tgids; do
		[ -d "/proc/$p/task" ] || continue
		for d in /proc/$p/task/*; do
			[ -d "$d" ] || continue
			tid=${d##*/}
			[ -r "$d/schedstat" ] && [ -r "$d/stat" ] || continue
			read runtime wait slices < "$d/schedstat" 2>/dev/null || continue
			line=$(cat "$d/stat" 2>/dev/null) || continue
			# /proc/<tid>/stat field 2 (comm) is parenthesized and can contain
			# spaces. Strip through the closing ") " before splitting fields.
			rest=${line#*) }
			set -- $rest
			cpu=${37:-NA}
			comm=$(cat "$d/comm" 2>/dev/null | tr ' |\t' '___')
			[ -n "$comm" ] || comm=NA
			printf '%s %s %s %s %s %s %s\n' \
				"$tid" "$p" "$comm" "$runtime" "$wait" "$slices" "$cpu" >> "$out"
		done
	done
}

# Rank only threads that exist in both snapshots. Output:
#   delta_runtime_ns delta_wait_ns delta_slices tid tgid comm cpu0 cpu1
rank_window() {
	prev=$1
	cur=$2
	out=$3
	awk '
		NR == FNR {
			r[$1]=$4; w[$1]=$5; s[$1]=$6; c[$1]=$7
			next
		}
		($1 in r) {
			dr=$4-r[$1]; dw=$5-w[$1]; ds=$6-s[$1]
			if (dr >= 0 && dw >= 0 && ds >= 0)
				print dr, dw, ds, $1, $2, $3, c[$1], $7
		}
	' "$prev" "$cur" 2>/dev/null | sort -nr -k1,1 | head -n "$TOPN" > "$out"
}

# Enrich one already-ranked TID. These are totals/current state rather than
# interval deltas. That is intentional: the fast path remains cheap, while a
# future analyzer can difference totals for TIDs that persist across windows.
enrich_tid() {
	tid=$1
	uid=NA; allowed=NA; vctx=NA; nvctx=NA
	umin=NA; umax=NA; mig=NA
	if [ -r "/proc/$tid/status" ]; then
		set -- $(awk '
			/^Uid:/ { uid=$2 }
			/^Cpus_allowed_list:/ { a=$2 }
			/^voluntary_ctxt_switches:/ { v=$2 }
			/^nonvoluntary_ctxt_switches:/ { n=$2 }
			END { print (uid==""?"NA":uid), (a==""?"NA":a), (v==""?"NA":v), (n==""?"NA":n) }
		' "/proc/$tid/status" 2>/dev/null)
		uid=${1:-NA}; allowed=${2:-NA}; vctx=${3:-NA}; nvctx=${4:-NA}
	fi
	if [ -r "/proc/$tid/sched" ]; then
		set -- $(awk '
			/^uclamp\.min / { umin=$NF }
			/^uclamp\.max / { umax=$NF }
			/nr_migrations/ && mig=="" { mig=$NF }
			END { print (umin==""?"NA":umin), (umax==""?"NA":umax), (mig==""?"NA":mig) }
		' "/proc/$tid/sched" 2>/dev/null)
		umin=${1:-NA}; umax=${2:-NA}; mig=${3:-NA}
	fi
	printf '%s %s %s %s %s %s %s\n' "$uid" "$allowed" "$umin" "$umax" "$mig" "$vctx" "$nvctx"
}

START=$(now_cs) || { echo "ERROR: cannot read /proc/uptime" >&2; exit 2; }
DEADLINE=$((START + DURATION * 100))
SEQ=0
PREV="$TMP/prev"
CUR="$TMP/cur"
RANKED="$TMP/ranked"

TG0=$(top_tgids)
snapshot_fast "$PREV" "$TG0"
T0=$(now_cs)

uname_r=$(uname -r 2>/dev/null | tr ' |\t' '___')
printf 'META|version=1|duration_s=%s|interval_ms=%s|top_n=%s|kernel=%s|read_only=yes\n' \
	"$DURATION" "$INTERVAL_MS" "$TOPN" "${uname_r:-NA}"
printf 'FIELDS|THREAD|seq|rank|tgid|tid|uid|comm|runtime_ms|runtime_pct|runq_wait_ms|slices|cpu_start|cpu_end|allowed|uclamp_min|uclamp_max|migrations_total|vol_ctx_total|nonvol_ctx_total\n'

while [ "$(now_cs)" -lt "$DEADLINE" ]; do
	sleep "$SLEEP_S"
	TG1=$(top_tgids)
	T1=$(now_cs)
	SEQ=$((SEQ + 1))

	if [ -z "$TG1" ]; then
		printf 'EVENT|seq=%s|type=no_top_app|t_cs=%s\n' "$SEQ" "$T1"
		TG0="$TG1"
		: > "$PREV"
		T0=$T1
		continue
	fi

	snapshot_fast "$CUR" "$TG1"

	# Do not join two different apps across a transition. That would rank thread
	# disappearance/creation rather than a workload. The next window starts clean.
	if [ "$TG1" != "$TG0" ]; then
		printf 'EVENT|seq=%s|type=top_app_changed|from=%s|to=%s|t_cs=%s\n' \
			"$SEQ" "$(echo "$TG0" | tr '\n ' ',_')" "$(echo "$TG1" | tr '\n ' ',_')" "$T1"
		cp "$CUR" "$PREV"
		TG0="$TG1"
		T0=$T1
		continue
	fi

	WALL_CS=$((T1 - T0))
	[ "$WALL_CS" -gt 0 ] || WALL_CS=1
	rank_window "$PREV" "$CUR" "$RANKED"
	printf 'WINDOW|seq=%s|t_cs=%s|wall_ms=%s|tgids=%s\n' \
		"$SEQ" "$T1" "$((WALL_CS * 10))" "$(echo "$TG1" | tr '\n ' ',_')"

	rank=0
	while read dr dw ds tid tgid comm cpu0 cpu1; do
		[ -n "$tid" ] || continue
		rank=$((rank + 1))
		set -- $(enrich_tid "$tid")
		uid=${1:-NA}; allowed=${2:-NA}; umin=${3:-NA}; umax=${4:-NA}
		mig=${5:-NA}; vctx=${6:-NA}; nvctx=${7:-NA}
		runtime_ms=$(awk -v n="$dr" 'BEGIN { printf "%.3f", n / 1000000 }')
		wait_ms=$(awk -v n="$dw" 'BEGIN { printf "%.3f", n / 1000000 }')
		pct=$(awk -v n="$dr" -v cs="$WALL_CS" 'BEGIN { printf "%.1f", (n / (cs * 10000000)) * 100 }')
		printf 'THREAD|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"$SEQ" "$rank" "$tgid" "$tid" "$uid" "$comm" "$runtime_ms" "$pct" \
			"$wait_ms" "$ds" "$cpu0" "$cpu1" "$allowed" "$umin" "$umax" "$mig" "$vctx" "$nvctx"
	done < "$RANKED"

	cp "$CUR" "$PREV"
	TG0="$TG1"
	T0=$T1
done

printf 'END|windows=%s|elapsed_s=%s\n' "$SEQ" "$(( ($(now_cs) - START) / 100 ))"
