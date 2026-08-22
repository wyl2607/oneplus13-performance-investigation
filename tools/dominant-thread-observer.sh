#!/system/bin/sh
# dominant-thread-observer.sh - read-only S1 observer for top-app thread behaviour.
#
# Purpose:
#   Find the one or two threads that dominate short foreground windows, without
#   changing any kernel or Android performance state. This is the measurement
#   scaffold for the next phase of the project: burst / wake-heavy responsiveness.
#
# Reads only:
#   /dev/cpuset/top-app/cgroup.procs
#   /proc/<pid>/task/<tid>/{stat,schedstat,status,sched,comm}
#   /proc/uptime
#
# Writes only a temporary lock/work directory under /data/local/tmp and removes
# it on exit. It never writes sysfs, procfs tunables, cgroups, uclamp or affinity.
#
# This targets Android's /system/bin/sh (mksh R59). That matters: printf is NOT a
# mksh builtin, it is /system/bin/printf, and a fork costs ~6.4 ms on this device.
# The scaffold used printf once per scanned thread, which made one snapshot of a
# 135-thread app cost 960 ms -- see V1..V6 in docs/DOMINANT_THREAD_OBSERVER.md.
# Nothing in the per-thread path may fork.
#
# usage:
#   su -c 'sh dominant-thread-observer.sh [duration_s] [interval_ms] [top_n]'
#
# defaults:
#   duration_s=30  interval_ms=250  top_n=5

TOPAPP=/dev/cpuset/top-app/cgroup.procs
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

# /proc/uptime resolves to 10 ms, so the whole scheduler runs on centiseconds.
INTERVAL_CS=$((INTERVAL_MS / 10))
[ "$INTERVAL_CS" -ge 5 ] || INTERVAL_CS=5

# /proc/uptime is available on every target build. The first field has two
# decimal places here, so concatenating integer and fractional pieces gives
# centiseconds without relying on unsupported `date +%s%N`.
now_cs() {
	read a b < /proc/uptime || return 1
	echo "${a%.*}${a#*.}"
}

# Sleep until an absolute centisecond deadline instead of a fixed interval. A
# fixed sleep made the real cadence interval + scan cost: measured 1.4 s for a
# nominal 250 ms, and still 330 ms once the forks were gone. Every S1 question is
# phrased about a 250 ms window, so the window has to actually be 250 ms: the
# deadline is pulled forward by the previous cycle's measured scan cost, so the
# snapshot *completes* on the grid rather than starting on it.
nap_until() {
	r=$(( $1 - $(now_cs) ))
	[ "$r" -gt 0 ] || return 0
	f=$((r % 100))
	[ "$f" -lt 10 ] && f="0$f"
	sleep "$((r / 100)).$f"
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
# An EXIT trap whose last command succeeds REPLACES the status the signal trap
# asked for: mksh returned 0 for a TERMed run, so a caller could not tell an
# aborted trace from a completed one. Carry the status across the handler.
trap 'rc=$?; cleanup; exit $rc' EXIT

# Return unique application TGIDs currently represented in the kernel top-app
# cpuset. cgroup.procs lists the processes directly; the tasks file lists every
# thread, which meant 163 status reads instead of 3 for the same answer (both
# methods verified to return the identical TGID set on-device).
# Use status/Tgid rather than process-name matching: comm truncation has already
# caused false identification in this project. uid >= 10000 filters the
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

# Fast snapshot. Keep this deliberately minimal: no comm/status/sched enrichment
# here, and no forks at all. Those extra reads are deferred until after ranking
# and performed only for top_n threads.
#
# Columns:
#   tid tgid runtime_ns runqueue_wait_ns timeslices cpu
snapshot_fast() {
	out=$1
	tgids=$2
	{
		for p in $tgids; do
			[ -d "/proc/$p/task" ] || continue
			for d in /proc/$p/task/*; do
				[ -d "$d" ] || continue
				tid=${d##*/}
				[ -r "$d/schedstat" ] && [ -r "$d/stat" ] || continue
				read runtime wait slices < "$d/schedstat" 2>/dev/null || continue
				IFS= read -r line < "$d/stat" 2>/dev/null || continue
				# /proc/<tid>/stat is `pid (comm) state ... processor ...`, and comm
				# may itself contain ") ": this device has live threads named
				# `AdWorker(NG) #1`. Shortest-match stripping returned processor=-1
				# for them -- a value that looks legitimate. Strip to the LAST ") ";
				# 14734 threads were scanned and no stat tail after the comm contains
				# a parenthesis, so the longest match cannot overshoot.
				rest=${line##*) }
				set -- $rest
				echo "$tid $p $runtime $wait $slices ${37:-NA}"
			done
		done
	} > "$out"
}

# Rank only threads that exist in both snapshots. Output:
#   delta_runtime_ns delta_wait_ns delta_slices tid tgid cpu0 cpu1
rank_window() {
	prev=$1
	cur=$2
	out=$3
	awk '
		NR == FNR {
			r[$1]=$3; w[$1]=$4; s[$1]=$5; c[$1]=$6
			next
		}
		($1 in r) {
			dr=$3-r[$1]; dw=$4-w[$1]; ds=$5-s[$1]
			if (dr >= 0 && dw >= 0 && ds >= 0)
				print dr, dw, ds, $1, $2, c[$1], $6
		}
	' "$prev" "$cur" 2>/dev/null | sort -nr -k1,1 | head -n "$TOPN" > "$out"
}

# Enrich every already-ranked TID in ONE awk. These are totals/current state
# rather than interval deltas. That is intentional: the fast path remains cheap,
# while a future analyzer can difference totals for TIDs that persist across
# windows.
#
# The scaffold read status and sched with two awks inside a command substitution,
# per thread: six forks for five threads, 19 ms each. Measured whole-observer cost
# at 250 ms / top 5 was 62 % of one core, and two thirds of that was children.
#
# Both the requested and the effective uclamp.max are reported. They diverge, and
# not rarely: a continuously running thread the oplus guard had clamped to 500
# still read effective=1024 in 17 of 30 samples, and only picked up 500 once it
# was dequeued. The scheduler latches the effective value at enqueue, so on a
# continuous worker the requested value alone would claim a clamp that was not
# being applied yet.
#
# Result is a single delimited string, ";tid:fields;tid:fields;", looked up with
# parameter substitution. The delimiter is a semicolon, not the '|' the rest of
# the output format uses: mksh treats '|' inside ${var#pattern} as pattern
# alternation, so the lookup matched nothing and every enriched field came out NA.
# A tid that died between ranking and enrichment simply misses, and the caller's
# :-NA defaults cover it.
ENR=";"
enrich_ranked() {
	# Take the path before `set --` clears the positional parameters.
	_ranked=$1
	set --
	while read _a _b _c _t _rest; do
		[ -n "$_t" ] || continue
		set -- "$@" "/proc/$_t/status" "/proc/$_t/sched"
	done < "$_ranked"
	ENR=";"
	[ $# -gt 0 ] || return 0
	awk '
		function d(x) { return (x == "" ? "NA" : x) }
		FNR == 1 { n=split(FILENAME, a, "/"); t=a[3]; seen[t]=1 }
		FILENAME ~ /\/status$/ {
			if ($1 == "Uid:") uid[t]=$2
			else if ($1 == "Cpus_allowed_list:") al[t]=$2
			else if ($1 == "voluntary_ctxt_switches:") v[t]=$2
			else if ($1 == "nonvoluntary_ctxt_switches:") nv[t]=$2
			next
		}
		$1 == "uclamp.min" { umin[t]=$NF; next }
		$1 == "uclamp.max" { umax[t]=$NF; next }
		/^effective uclamp.max/ { umaxe[t]=$NF; next }
		$1 == "se.nr_migrations" { mig[t]=$NF }
		END {
			for (t in seen)
				print t, d(uid[t]), d(al[t]), d(umin[t]), d(umax[t]), \
				      d(umaxe[t]), d(mig[t]), d(v[t]), d(nv[t])
		}
	' "$@" 2>/dev/null > "$TMP/enr"
	while read _t _rest; do
		ENR="$ENR$_t:$_rest;"
	done < "$TMP/enr"
}

# ns -> "s.mmm" and tenths -> "n.t", both fork-free. awk was doing this once per
# ranked thread purely to place a decimal point.
MS=""
ns_ms() {
	_i=$(( $1 / 1000000 ))
	_f=$(( $1 % 1000000 / 1000 ))
	if [ "$_f" -lt 10 ]; then _f="00$_f"; elif [ "$_f" -lt 100 ]; then _f="0$_f"; fi
	MS="$_i.$_f"
}

START=$(now_cs) || { echo "ERROR: cannot read /proc/uptime" >&2; exit 2; }
DEADLINE=$((START + DURATION * 100))
SEQ=0
PREV="$TMP/prev"
CUR="$TMP/cur"
RANKED="$TMP/ranked"

TG0=$(top_tgids)
W0=$(now_cs)
snapshot_fast "$PREV" "$TG0"
T0=$(now_cs)
SCAN_CS=$((T0 - W0))

uname_r=$(uname -r 2>/dev/null | tr ' |\t' '___')
echo "META|version=2|duration_s=$DURATION|interval_ms=$INTERVAL_MS|top_n=$TOPN|kernel=${uname_r:-NA}|read_only=yes"
echo "FIELDS|THREAD|seq|rank|tgid|tid|uid|comm|runtime_ms|runtime_pct|runq_wait_ms|slices|cpu_start|cpu_end|allowed|uclamp_min|uclamp_max|uclamp_max_eff|migrations_total|vol_ctx_total|nonvol_ctx_total"

while [ "$(now_cs)" -lt "$DEADLINE" ]; do
	nap_until $((T0 + INTERVAL_CS - SCAN_CS))
	W0=$(now_cs)
	TG1=$(top_tgids)

	if [ -z "$TG1" ]; then
		T1=$(now_cs)
		SCAN_CS=$((T1 - W0))
		SEQ=$((SEQ + 1))
		echo "EVENT|seq=$SEQ|type=no_top_app|t_cs=$T1"
		TG0="$TG1"
		: > "$PREV"
		T0=$T1
		continue
	fi

	snapshot_fast "$CUR" "$TG1"
	# Timestamp AFTER the scan. Taking it before charged the window only the sleep
	# and left the scan out of wall_ms, which inflated every runtime_pct.
	T1=$(now_cs)
	SCAN_CS=$((T1 - W0))
	SEQ=$((SEQ + 1))

	# Do not join two different apps across a transition. That would rank thread
	# disappearance/creation rather than a workload. The next window starts clean.
	if [ "$TG1" != "$TG0" ]; then
		echo "EVENT|seq=$SEQ|type=top_app_changed|from=${TG0//$'\n'/,}|to=${TG1//$'\n'/,}|t_cs=$T1"
		SWAP="$PREV"; PREV="$CUR"; CUR="$SWAP"
		TG0="$TG1"
		T0=$T1
		continue
	fi

	WALL_CS=$((T1 - T0))
	[ "$WALL_CS" -gt 0 ] || WALL_CS=1
	rank_window "$PREV" "$CUR" "$RANKED"
	echo "WINDOW|seq=$SEQ|t_cs=$T1|wall_ms=$((WALL_CS * 10))|tgids=${TG1//$'\n'/,}"

	enrich_ranked "$RANKED"
	rank=0
	while read dr dw ds tid tgid cpu0 cpu1; do
		[ -n "$tid" ] || continue
		rank=$((rank + 1))
		e=${ENR#*;$tid:}
		set -- ${e%%;*}
		uid=${1:-NA}; allowed=${2:-NA}; umin=${3:-NA}; umax=${4:-NA}
		umaxe=${5:-NA}; mig=${6:-NA}; vctx=${7:-NA}; nvctx=${8:-NA}
		comm=NA
		if [ -r "/proc/$tid/comm" ]; then
			IFS= read -r comm < "/proc/$tid/comm" 2>/dev/null || comm=NA
			# mksh substitution, not `| tr`: two forks per thread for one string.
			comm=${comm//[ 	|]/_}
			[ -n "$comm" ] || comm=NA
		fi
		ns_ms "$dr"; runtime_ms=$MS
		ns_ms "$dw"; wait_ms=$MS
		tenths=$(( dr / (WALL_CS * 10000) ))
		echo "THREAD|$SEQ|$rank|$tgid|$tid|$uid|$comm|$runtime_ms|$((tenths / 10)).$((tenths % 10))|$wait_ms|$ds|$cpu0|$cpu1|$allowed|$umin|$umax|$umaxe|$mig|$vctx|$nvctx"
	done < "$RANKED"

	SWAP="$PREV"; PREV="$CUR"; CUR="$SWAP"
	TG0="$TG1"
	T0=$T1
done

echo "END|windows=$SEQ|elapsed_s=$(( ($(now_cs) - START) / 100 ))"
