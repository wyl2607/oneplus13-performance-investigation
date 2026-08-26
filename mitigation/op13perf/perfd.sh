#!/system/bin/sh
# op13perf daemon.
#
# Three limiters, all measured on this device on 2026-08-19:
#   1. URCC parks the prime cluster BELOW the mid cluster (1689600 vs 2400000).
#      Only /sys/kernel/msm_performance/parameters/cpu_max_freq can move it --
#      scaling_max_freq loses to URCC's freq_qos request under min(). The node is
#      non-persistent and URCC reclaims it, hence the 4 Hz re-assert.
#   2. oplus_bsp_task_overload clamps busy threads to
#      floor(614 * prime_cur_freq / 4320000), which pins them to the mid cluster.
#      Lifted with uclampset on the foreground app's own pids. It is a general
#      runaway-thread guard, not benchmark detection -- the same clamp values show
#      up on ordinary app threads.
#   3. cpufreq_bouncing clamps prime to 2438400 via freq_qos after 50 ms of load,
#      which would beat our request under min(). Disabled while a level is on; the
#      system re-enables it on every screen wake, so it needs re-checking. Restored
#      to 1 on OFF.
#
# GB7 on this device: 725/5942 stock -> 1210/7626 with lever 1 -> 2071/8166 with both.
#
# Everything here is non-persistent kernel state and a reboot clears it. Switching
# OFF is NOT self-reverting at idle -- writing cpu_max_freq overwrites the request
# URCC owns, and an unloaded write held 40 s with no drift -- so OFF explicitly
# writes the rated maxima, meaning "this module imposes no limit".

MODDIR=${0%/*}
STATEDIR=/data/adb/op13perf
STATE=$STATEDIR/state
SINCE=$STATEDIR/since
CONF=$STATEDIR/conf
LOG=$STATEDIR/log
STATUS=$STATEDIR/status
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
SCREEN=/sys/class/drm/card0-DSI-1/enabled
TOPAPP=/dev/cpuset/top-app/tasks
CFB=/sys/module/cpufreq_bouncing/parameters/enable

mkdir -p "$STATEDIR"

# Defaults live here, not only in the conf file, so an older conf missing a key
# still yields a working daemon instead of an empty variable.
BOOT_LEVEL=1
DAILY_P6=2841600
DAILY_P0=2400000
DAILY_GATE=88000
DAILY_TIMEOUT=0
PERF_P6=3283200
PERF_P0=2918400
PERF_GATE=90000
PERF_TIMEOUT=0
EXTREME_P6=3513600
EXTREME_P0=2918400
EXTREME_GATE=92000
EXTREME_TIMEOUT=0
COOL_P6=2649600
COOL_P0=2227200
THERMAL_HYST=6000
THERMAL_DWELL=15
PAUSE_ON_SCREEN_OFF=1

[ -f "$CONF" ] || cat > "$CONF" <<'EOF'
# 开机自动进入的档位：0=关 1=日常档 2=高性能档 3=极限档
# 默认 1。开机时无法知道 40W 散热器接没接，而 3 档的前提就是接着散热器，
# 所以开机只能进裸机安全的档位。
BOOT_LEVEL=1

# 档位 1 · 日常（裸机常开）。两个频率都必须是 scaling_available_frequencies
# 里的真实台阶，否则内核静默向下吸附（2918400 在 policy6 上不存在，会变成 2841600）。
# 这一档解除 URCC 倒挂与 uclamp 钳位（多核成绩的来源），但不追高频率。
#
# 2026-08-21 已用八核负载实测（一核一个 worker，150 s，裸机），DATA.md 42/43 节。
# 结论是**这两个值不动**：八核满载下上限根本不是活跃约束，五组从 2841600/2400000
# 到 3283200/2918400 的配置吞吐只差 3.7%，落在本机约 5% 的跑间散布内；抬中核会让
# 整个窗口 100% 处在退让态，抬超大核反而让超大核自己做的功从 358 掉到 330。
# 试过把超大核降两档到 2438400（单次看着 +4.7%），A/B 交替复测后 t=1.06 不成立，
# 而现状配置自己两次跑出 1054 和 978——散布是待测效应的 3 倍。不是「最优」，是
# 「没有更好的可买」。少核 burst 场景仍未测，那才是这一档真正的用途。
DAILY_P6=2841600
DAILY_P0=2400000
# 红线 88：裸机散热差于台架，比 2 档的 90 更早退让。2026-08-21 实测：八核满载下
# 这一档有 28% 的时间处在退让态，而**不加任何杠杆的 stock 自己峰值就到 90 C**——
# 热是核数带来的，不是这个模块带来的。
DAILY_GATE=88000
DAILY_TIMEOUT=0

# 档位 2 · 高性能（裸机短时）。接散热器实测 2071/8166，峰值 98.8 C（退让闸曾触发）。
# 裸机跑这一档的持续表现未实测，预期会更早、更频繁地退让到 COOL。
PERF_P6=3283200
PERF_P0=2918400
# 红线 90：开机风暴在原厂设置下自己就能到 92 C，定 85 会导致常开时频繁误退让。
PERF_GATE=90000
PERF_TIMEOUT=0

# 档位 3 · 极限（必须接 40W 散热器）。散热器无法自动检测，只能手动选。
# 取 3513600 而不是 3801600：接散热器实测 3801600 的 GB7 峰值 100 C，距内核跳闸点
# 105 只剩 5 C，而它买到的只有单核 +7.9%，多核 −1.0%（多核受超大核集群共享功耗
# 预算限制，本来就吃不到更高的上限）。3513600 实测 2240/8679，峰值 96.1 C。
EXTREME_P6=3513600
EXTREME_P0=2918400
EXTREME_GATE=92000
EXTREME_TIMEOUT=0

# 过热时降到的档位。退让是「降档」不是「全撤」——解钳和 CFB 继续保持，
# 否则 guard 会立刻把线程钳回中核，而多核成绩（5942→8596）正是靠解钳拿到的。
#
# 必须严格低于**最低的常用档**（1 档的 2841600/2400000）。原先这两个值与 1 档
# 完全相同，于是 1 档触发退让时「降」到了自己身上，日志照打 STEP-DOWN 而频率
# 一点没动——2026-08-20 在真实使用里撞到 gate 88 C（瞬时 95 C）才暴露出来。
#
# 2026-08-21 实测（DATA.md 42 节）：**八核满载下这一对不降温**——退让态 89 C，
# 不退让 88 C，差值在噪声里；而 COOL_P6 的 2649600 压根没被吃到（超大核在 COOL
# 下自己只跑到 2438400），所以退让的超大核那一半是空的，惩罚全落在 6 个中核上。
# 把中核砍到 1996800 确实能降 6 C，但吞吐要付 12.4%。
# **没有据此改值**：上面测的是八核满载，而那恰好是上限不起作用的工况；退让真正
# 要救的一两个忙核场景还没测，拿八核证据去改会重犯 42 节自己犯过的错。
COOL_P6=2649600
COOL_P0=2227200

# 超时自动关闭：0 = 不自动关，一直保持（单位秒）
# 过热回滞：平滑后的温度需低于 红线 - 该值 才恢复
# 过热最短停留：退让后至少保持这么多秒才允许恢复，防止在红线上反复横跳
THERMAL_HYST=6000
THERMAL_DWELL=15

# 息屏时暂停两个杠杆（1=是）
PAUSE_ON_SCREEN_OFF=1
EOF
. "$CONF"

# The module list's two fields are written from here because every switching path
# ends at this daemon: the Magisk Action button, the Termux widget and the QS tile
# all just write $STATE and let the poll below pick it up. action.sh used to be the
# only writer, so any switch that did not come from that button left the list
# describing the level the device booted into -- measured 2026-08-21 as a device
# sitting at level 2 while the list still read "日常档 2841600".
. "$MODDIR/desc.sh"

# junction sensor, by type not by index -- indices move across boots
Z_J=""
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done

jt() { [ -z "$Z_J" ] && echo 0 || cat "$Z_J" 2>/dev/null; }
now() { date +%s; }

log() {
	[ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 65536 ] && : > "$LOG"
	echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
}

release() {
	R6=$(cat /sys/devices/system/cpu/cpufreq/policy6/cpuinfo_max_freq 2>/dev/null)
	R0=$(cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq 2>/dev/null)
	[ -n "$R6" ] && [ -n "$R0" ] && \
		echo "0:$R0 1:$R0 2:$R0 3:$R0 4:$R0 5:$R0 6:$R6 7:$R6" > "$NODE" 2>/dev/null
}

# Foreground pids come from the kernel's own top-app cpuset, not from name
# matching -- comm truncates at 15 chars and this project has been burned by
# name matching four times. uid >= 10000 filters out system processes.
PIDS=""
refresh_pids() {
	set --
	for t in $(cat "$TOPAPP" 2>/dev/null); do
		set -- "$@" "/proc/$t/status"
	done
	if [ $# -eq 0 ]; then PIDS=""; return; fi
	PIDS=$(awk 'FNR==1{tg=""} /^Tgid:/{tg=$2} /^Uid:/{if(tg!="" && $2+0>=10000) print tg}' "$@" 2>/dev/null | sort -u | head -6)
}

screen_on() {
	[ "$PAUSE_ON_SCREEN_OFF" != "1" ] && return 0
	[ -r "$SCREEN" ] || return 0
	read s < "$SCREEN" 2>/dev/null
	[ "$s" = "enabled" ]
}

log "daemon started, pid $$, sensor ${Z_J:-NONE}, BOOT_LEVEL=$BOOT_LEVEL"
[ -f "$STATE" ] || echo 0 > "$STATE"

i=0
LAST=-1
COOLING=0
while :; do
	read ST < "$STATE" 2>/dev/null || ST=0
	case "$ST" in 1|2|3) : ;; *) ST=0 ;; esac

	if [ "$ST" != "$LAST" ]; then
		if [ "$ST" = 0 ]; then
			if [ "$LAST" != "-1" ]; then
				release
				log "OFF -- released to rated; URCC re-applies on its next ramp"
			else
				log "OFF -- initial state, nothing to release"
			fi
			# hand CFB back to the system; OFF means stock
			[ -w "$CFB" ] && echo 1 > "$CFB" 2>/dev/null
			echo "off" > "$STATUS"
		else
			now > "$SINCE"
			log "ON level $ST"
		fi
		write_prop "$ST" "$MODDIR/module.prop"
		LAST=$ST
		COOLING=0
		i=0
	fi

	if [ "$ST" = 0 ]; then
		sleep 2
		continue
	fi

	# Screen check comes BEFORE the thermal logic on purpose: with the screen off
	# no levers are applied, so any heat is the system's own and backing off from
	# it would be managing a fire we did not light. Observed after a reboot -- the
	# boot storm reached 92 C at stock settings while this daemon was idle.
	if ! screen_on; then
		echo "paused screen-off level=$ST" > "$STATUS"
		COOLING=0
		sleep 2
		continue
	fi

	case "$ST" in
		1) P6=$DAILY_P6;   P0=$DAILY_P0;   GATE=$DAILY_GATE;   TMO=$DAILY_TIMEOUT ;;
		2) P6=$PERF_P6;    P0=$PERF_P0;    GATE=$PERF_GATE;    TMO=$PERF_TIMEOUT ;;
		*) P6=$EXTREME_P6; P0=$EXTREME_P0; GATE=$EXTREME_GATE; TMO=$EXTREME_TIMEOUT ;;
	esac

	J=$(jt)

	# cpu-1-1-1 is a per-core junction sensor and it is SPIKY: measured swinging
	# 80 <-> 93 C inside one second, which made a 6 C hysteresis band narrower than
	# the noise and produced pause/resume oscillation four times in 13 seconds.
	# Decisions therefore run on an exponential moving average (tau ~2 s at 4 Hz),
	# and a resume additionally has to wait out THERMAL_DWELL.
	[ "${AVG:-0}" -eq 0 ] 2>/dev/null && AVG=$J
	AVG=$(( (AVG * 7 + J) / 8 ))

	# Thermal management is a STEP-DOWN with hysteresis, not an auto-off and not a
	# full release. A hard off would never come back on its own in an always-on
	# config; a full release would also drop the uclamp lift, and the guard would
	# re-clamp within seconds -- which is exactly what earns the multi-core score.
	# So above the gate only the CEILING drops, to COOL_P6/COOL_P0. The uclamp lift
	# and the CFB handling below continue to run.
	if [ "$COOLING" = 0 ] && [ "$AVG" -gt "$GATE" ] 2>/dev/null; then
		COOLING=1
		COOL_AT=$(now)
		log "THERMAL STEP-DOWN to $COOL_P6 at avg $((AVG/1000)) C / inst $((J/1000)) C (gate $((GATE/1000)) C)"
	elif [ "$COOLING" = 1 ] && [ "$AVG" -lt "$((GATE - THERMAL_HYST))" ] 2>/dev/null &&
	     [ "$(( $(now) - ${COOL_AT:-0} ))" -ge "$THERMAL_DWELL" ] 2>/dev/null; then
		COOLING=0
		log "THERMAL RESUME at avg $((AVG/1000)) C after $(( $(now) - COOL_AT ))s"
	fi

	if [ "$COOLING" = 1 ]; then
		P6=$COOL_P6; P0=$COOL_P0
	fi

	# Timeout is optional; 0 means stay on indefinitely.
	if [ "${TMO:-0}" -gt 0 ] 2>/dev/null; then
		read T0 < "$SINCE" 2>/dev/null || T0=$(now)
		EL=$(( $(now) - T0 ))
		if [ "$EL" -gt "$TMO" ]; then
			log "TIMEOUT AUTO-OFF after ${EL}s (limit ${TMO}s)"
			echo "timeout ${EL}s" > "$STATUS"
			echo 0 > "$STATE"
			continue
		fi
	else
		EL=0
	fi

	WANT="0:$P0 1:$P0 2:$P0 3:$P0 4:$P0 5:$P0 6:$P6 7:$P6"
	echo "$WANT" > "$NODE" 2>/dev/null

	if [ $((i % 8)) -eq 0 ]; then
		[ -r "$CFB" ] && {
			read cfb < "$CFB" 2>/dev/null
			[ "$cfb" != "0" ] && echo 0 > "$CFB" 2>/dev/null
		}
		refresh_pids
	fi

	for p in $PIDS; do
		uclampset -a -M 1024 -p "$p" >/dev/null 2>&1
	done

	if [ $((i % 8)) -eq 0 ]; then
		# verify rather than assume -- a write that silently loses is the whole
		# reason scaling_max_freq was the wrong node
		GOT=$(tr -s ' ' < "$NODE" 2>/dev/null | sed 's/ *$//')
		OK=no; [ "$GOT" = "$WANT" ] && OK=yes
		if [ "${TMO:-0}" -gt 0 ]; then LEFT="$((TMO-EL))s"; else LEFT="常开"; fi
		CD=""; [ "$COOLING" = 1 ] && CD=" STEPPED-DOWN(resume<$(( (GATE-THERMAL_HYST)/1000 ))C)"
		echo "level=$ST held=$OK cfb=$(cat $CFB 2>/dev/null) prime=$P6 junc=$((J/1000))C left=$LEFT pids=$(echo $PIDS | tr '\n' ' ')$CD" > "$STATUS"
	fi

	i=$((i+1))
	sleep 0.25
done
