#!/system/bin/sh
#
# Shared harness for real-workload A/Bs. Sourced, not run.
#
# Records wall-clock, per-thread uclamp.max, prime residency, junction
# and shell. Sampling follows gb7_sampler.sh / gb7_uclamp_hunt.sh:
# zones by name, /proc/uptime, one awk pass over sched, /proc/stat
# jiffies, no ${var#*(}, no date +%s%N.
#
# The workload must run as an app uid. Root is exempt from the clamp
# (DATA.md section 27). Default uid 10999 is synthetic.

say() { printf '%s\n' "$*"; }

rd() {
	R=NA
	[ "$1" = "NA" ] || [ -z "$1" ] && return 0
	read R < "$1" 2>/dev/null
	[ -z "$R" ] && R=NA
	return 0
}

now_cs() {
	read _a _b < /proc/uptime
	printf '%s\n' "${_a%.*}${_a#*.}"
}

zone_by_name() {
	_want="$1"
	for _z in /sys/class/thermal/thermal_zone*; do
		[ -r "$_z/type" ] || continue
		read _t < "$_z/type" 2>/dev/null || continue
		if [ "$_t" = "$_want" ]; then
			printf '%s\n' "$_z/temp"
			return 0
		fi
	done
	return 1
}

# Prime CPUs = those with the maximum cpu_capacity. Do not hardcode 6/7.
discover_prime() {
	PRIME_CPUS=""
	MAXCAP=0
	for _c in /sys/devices/system/cpu/cpu[0-9]*; do
		_n="${_c##*/cpu}"
		[ -r "$_c/cpu_capacity" ] || continue
		read _cap < "$_c/cpu_capacity"
		[ "$_cap" -gt "$MAXCAP" ] && MAXCAP="$_cap"
	done
	for _c in /sys/devices/system/cpu/cpu[0-9]*; do
		_n="${_c##*/cpu}"
		[ -r "$_c/cpu_capacity" ] || continue
		read _cap < "$_c/cpu_capacity"
		[ "$_cap" -eq "$MAXCAP" ] && PRIME_CPUS="$PRIME_CPUS$_n "
	done
}

snapshot_stat() {
	# Sets ALL_BUSY and PRIME_BUSY from a single /proc/stat pass.
	ALL_BUSY=0
	PRIME_BUSY=0
	while read -r _a _u _n _s _id _io _irq _sirq _rest; do
		case "$_a" in
			cpu[0-9]*)
				_b=$((_u + _n + _s + _irq + _sirq))
				ALL_BUSY=$((ALL_BUSY + _b))
				for _p in $PRIME_CPUS; do
					if [ "$_a" = "cpu$_p" ]; then
						PRIME_BUSY=$((PRIME_BUSY + _b))
					fi
				done
				;;
			cpu) ;;
			*) break ;;
		esac
	done < /proc/stat
}

dump_ceilings() {
	say "ceilings $1"
	for _p in /sys/devices/system/cpu/cpufreq/policy*; do
		[ -d "$_p" ] || continue
		_name="${_p##*/}"
		_mx=NA; _cur=NA
		[ -r "$_p/scaling_max_freq" ] && read _mx  < "$_p/scaling_max_freq"
		[ -r "$_p/scaling_cur_freq" ] && read _cur < "$_p/scaling_cur_freq"
		printf '  %s max=%s cur=%s\n' "$_name" "$_mx" "$_cur"
	done
	if [ -r /sys/module/cpufreq_bouncing/parameters/enable ]; then
		read _e < /sys/module/cpufreq_bouncing/parameters/enable
		say "  cfb_enable=$_e"
	fi
}

thermal_status() {
	dumpsys thermalservice 2>/dev/null | grep -m1 "Thermal Status"
}

# One sample line. WPID must be set. Appends to $LOG.
sample_once() {
	read _up _ < /proc/uptime
	rd "$Z_J"; _j=$R
	rd "$Z_S"; _s=$R
	_umax_list=""
	_nclamp=0
	_nthr=0
	if [ -n "$WPID" ] && [ -d "/proc/$WPID/task" ]; then
		_scan=$(awk '
			FNR==1 {
				o = index($0, "(")
				if (o == 0) { cur = "?"; next }
				rest = substr($0, o + 1); c = index(rest, ",")
				cur = (c > 0) ? substr(rest, 1, c - 1) : "?"
				gsub(/[ \t]/, "", cur)
				order[++k] = cur
				next
			}
			/^uclamp\.max / { umx[cur] = $NF }
			END {
				for (i = 1; i <= k; i++) {
					t = order[i]
					u = (umx[t] == "" ? "NA" : umx[t])
					printf "%s:%s ", t, u
					if (u != "NA" && u != 1024) nc++
				}
				printf "\n%d %d", k + 0, nc + 0
			}
		' /proc/$WPID/task/*/sched 2>/dev/null)
		# last line is "nthr nclamp"; everything before is the list.
		# Avoid ${var#*(}. Use two awk passes on the captured text.
		_umax_list=$(printf '%s\n' "$_scan" | awk 'NR==1 {print}')
		_counts=$(printf '%s\n' "$_scan" | awk 'NR==2 {print}')
		_nthr=$(printf '%s\n' "$_counts" | awk '{print $1+0}')
		_nclamp=$(printf '%s\n' "$_counts" | awk '{print $2+0}')
	fi
	snapshot_stat
	printf 'S|%s|j=%s|s=%s|all_busy=%s|prime_busy=%s|nthr=%s|nclamp=%s|uclamp=%s\n' \
		"$_up" "$_j" "$_s" "$ALL_BUSY" "$PRIME_BUSY" "$_nthr" "$_nclamp" "$_umax_list" >> "$LOG"

	# Running extrema for the RESULT line. milli-C, skip NA.
	if [ "$_j" != "NA" ] && [ -n "$_j" ]; then
		[ "$J_MAX" -eq 0 ] || [ "$_j" -gt "$J_MAX" ] && J_MAX=$_j
		[ "$J_MIN" -eq 0 ] || [ "$_j" -lt "$J_MIN" ] && J_MIN=$_j
	fi
	if [ "$_s" != "NA" ] && [ -n "$_s" ]; then
		[ "$S_MAX" -eq 0 ] || [ "$_s" -gt "$S_MAX" ] && S_MAX=$_s
	fi
	[ "$_nclamp" -gt "$CLAMP_SAMPLES" ] && CLAMP_SAMPLES=$_nclamp
	# Track the smallest non-NA uclamp seen on any thread this tick.
	_smallest=$(printf '%s\n' "$_umax_list" | awk '{
		m = 1024
		for (i = 1; i <= NF; i++) {
			split($i, a, ":")
			if (a[2] != "" && a[2] != "NA" && a[2] + 0 < m) m = a[2] + 0
		}
		print m
	}')
	[ -n "$_smallest" ] && [ "$_smallest" -lt "$UCLAMP_MIN_SEEN" ] && \
		UCLAMP_MIN_SEEN=$_smallest
}

unclamp_loop() {
	# Background. Stops when WPID dies, FLAG is removed, or thermal abort.
	_flag="$1"
	while [ -f "$_flag" ]; do
		[ -n "$WPID" ] && [ -d "/proc/$WPID" ] || break
		rd "$Z_J"; _j=$R
		rd "$Z_S"; _s=$R
		if [ "$_j" != "NA" ] && [ "${_j:-0}" -gt 95000 ]; then
			say "ABORT|junction=$_j|shell=$_s" | tee -a "$LOG"
			rm -f "$_flag"
			break
		fi
		if [ "$_s" != "NA" ] && [ "${_s:-0}" -gt 42000 ]; then
			say "ABORT|junction=$_j|shell=$_s" | tee -a "$LOG"
			rm -f "$_flag"
			break
		fi
		uclampset -a -M 1024 -p "$WPID" 2>/dev/null
		sleep 0.25
	done
}

preflight() {
	say "preflight label=$LABEL arm=$ARM uid=$UID"
	if [ "$UID" = "0" ] || [ "$UID" = "1000" ]; then
		say "WARNING: uid $UID is exempt from the clamp (DATA.md section 27)."
		say "WARNING: this run is not a valid model of app behaviour."
	fi
	SCR=$(dumpsys display 2>/dev/null | grep -m1 mScreenState)
	say "screen: ${SCR:-unavailable}"
	case "$SCR" in
		*ON*|*on*) ;;
		*) say "WARNING: screen does not look ON. METHODOLOGY trap 2." ;;
	esac
	if [ "$Z_J" != "NA" ]; then
		rd "$Z_J"
		if [ "$R" != "NA" ] && [ -n "$R" ]; then
			say "junction_now=$R ($((R / 1000)) C)  zone=$Z_J"
		else
			say "junction_now=unreadable  zone=$Z_J"
		fi
	else
		say "ERROR: junction sensor cpu-1-1-1 not found"
		return 1
	fi
	dump_ceilings before
	TS0=$(thermal_status)
	say "thermal_status_before=${TS0:-unavailable}"
	return 0
}

# run_workload <arm> <label> <uid> <timeout_s> <command>
# Command is a single string, already quoted for `su <uid> -c`.
run_workload() {
	ARM="$1"
	LABEL="$2"
	UID="$3"
	TMAX="$4"
	CMD="$5"

	case "$ARM" in
		stock|unclamp) ;;
		*) say "ERROR: arm must be stock or unclamp, got: $ARM"; return 2 ;;
	esac

	WORKDIR=/data/local/tmp/rw-work
	LOG=/data/local/tmp/rw-${LABEL}-${ARM}.log
	FLAG=/data/local/tmp/rw-${LABEL}-${ARM}.run
	PIDFILE=$WORKDIR/wpid

	mkdir -p "$WORKDIR" 2>/dev/null
	chmod 777 "$WORKDIR" 2>/dev/null
	: > "$LOG"
	: > "$FLAG"
	rm -f "$PIDFILE"

	Z_J=NA; Z_S=NA
	_j=$(zone_by_name cpu-1-1-1) && Z_J="$_j"
	_s=$(zone_by_name shell_front) && Z_S="$_s"
	discover_prime
	say "prime_cpus=$PRIME_CPUS (capacity $MAXCAP)"

	preflight || return 2

	J_MAX=0; J_MIN=0; S_MAX=0
	CLAMP_SAMPLES=0
	UCLAMP_MIN_SEEN=1024
	WPID=""

	# The -c shell writes its pid then execs the command so the pid
	# stays the same and uclampset / task/* attach to the workload.
	# CMD must be a simple command (redirects are fine); not a pipeline.
	su "$UID" -c "echo \$\$ > $PIDFILE; exec $CMD" &
	SU_PID=$!

	# Wait briefly for the pidfile. The workload owns it.
	_w=0
	while [ "$_w" -lt 50 ]; do
		[ -s "$PIDFILE" ] && break
		sleep 0.1
		_w=$((_w + 1))
	done
	if [ -s "$PIDFILE" ]; then
		read WPID < "$PIDFILE"
	else
		say "WARNING: pidfile missing, sampling the su wrapper $SU_PID"
		WPID=$SU_PID
	fi
	say "wpid=$WPID su_pid=$SU_PID"
	say "cmd=$CMD"

	UCPID=""
	if [ "$ARM" = "unclamp" ]; then
		if ! command -v uclampset >/dev/null 2>&1; then
			say "ERROR: uclampset not on PATH; cannot run unclamp arm"
			kill -9 "$SU_PID" 2>/dev/null
			rm -f "$FLAG"
			return 2
		fi
		unclamp_loop "$FLAG" &
		UCPID=$!
	fi

	snapshot_stat
	STAT0_ALL=$ALL_BUSY
	STAT0_PRIME=$PRIME_BUSY
	T0=$(now_cs)
	say "#META arm=$ARM label=$LABEL uid=$UID wpid=$WPID t0=$T0" >> "$LOG"
	say "#META prime_cpus=$PRIME_CPUS" >> "$LOG"

	# Sample until the workload exits or TMAX seconds elapse.
	TMAXCS=$((TMAX * 100))
	while kill -0 "$SU_PID" 2>/dev/null; do
		sample_once
		EL=$(( $(now_cs) - T0 ))
		if [ "$EL" -ge "$TMAXCS" ]; then
			say "TIMEOUT at ${TMAX}s" | tee -a "$LOG"
			[ -n "$WPID" ] && kill -9 "$WPID" 2>/dev/null
			kill -9 "$SU_PID" 2>/dev/null
			break
		fi
		sleep 0.25
	done
	wait "$SU_PID" 2>/dev/null
	RC=$?

	T1=$(now_cs)
	WALL=$((T1 - T0))
	snapshot_stat
	D_ALL=$((ALL_BUSY - STAT0_ALL))
	D_PRIME=$((PRIME_BUSY - STAT0_PRIME))
	PRIME_PCT=0
	if [ "$D_ALL" -gt 0 ]; then
		PRIME_PCT=$((D_PRIME * 1000 / D_ALL))
	fi

	rm -f "$FLAG"
	[ -n "$UCPID" ] && wait "$UCPID" 2>/dev/null

	dump_ceilings after
	TS1=$(thermal_status)
	say "thermal_status_after=${TS1:-unavailable}"

	# PRIME_PCT is tenths of a percent (1000 = 100.0%).
	printf 'RESULT|arm=%s|label=%s|uid=%s|wall_cs=%s|rc=%s' \
		"$ARM" "$LABEL" "$UID" "$WALL" "$RC"
	printf '|uclamp_min_seen=%s|clamp_threads_peak=%s' \
		"$UCLAMP_MIN_SEEN" "$CLAMP_SAMPLES"
	printf '|prime_residency_tenth_pct=%s|j_min=%s|j_max=%s|s_max=%s' \
		"$PRIME_PCT" "$J_MIN" "$J_MAX" "$S_MAX"
	printf '|status=TODO: unmeasured\n'
	say "log=$LOG"
	say "this RESULT is a capture format. the workload effect is TODO: unmeasured"
}
