#!/system/bin/sh
# Shared helpers for Termux:Widget shortcuts. Sourced, not executed.
# Level names come from desc.sh; do not hardcode them here.

MODDIR=/data/adb/modules/op13perf
STATEDIR=/data/adb/op13perf
STATE=$STATEDIR/state
STATUS=$STATEDIR/status
CONF=$STATEDIR/conf
PIDF=$STATEDIR/pid
DESC=$MODDIR/desc.sh
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
CFB=/sys/module/cpufreq_bouncing/parameters/enable

# Same check as action.sh: match /proc/<pid>/cmdline, not comm (15-char cap).
alive() {
	[ -f "$PIDF" ] || return 1
	read p < "$PIDF" 2>/dev/null || return 1
	[ -d "/proc/$p" ] || return 1
	tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q perfd.sh
}

ensure_daemon() {
	if ! alive; then
		nohup "$MODDIR/perfd.sh" >/dev/null 2>&1 &
		echo $! > "$PIDF"
		sleep 1
	fi
}

load_desc() {
	[ -f "$CONF" ] && . "$CONF"
	. "$DESC"
}

junc_c() {
	for z in /sys/class/thermal/thermal_zone*; do
		read t < "$z/type" 2>/dev/null || continue
		if [ "$t" = "cpu-1-1-1" ]; then
			echo $(( $(cat "$z/temp") / 1000 ))
			return 0
		fi
	done
	echo "?"
}

held_of() {
	held=no
	if [ -f "$STATUS" ]; then
		for w in $(cat "$STATUS"); do
			case "$w" in
				held=yes) held=yes ;;
				held=no) held=no ;;
			esac
		done
	fi
	echo "$held"
}

notify() {
	msg=$1
	toast=/data/data/com.termux/files/usr/bin/termux-toast
	if [ -x "$toast" ]; then
		"$toast" "$msg"
	fi
	printf '%s\n' "$msg"
}

# Re-exec via su so the widget process (uid 10575) can write /data/adb.
# Toast/echo stay in the unprivileged parent so termux-toast runs as Termux.
run_as_root() {
	self=$1
	case "$self" in
		/*) ;;
		*) self=$(pwd)/$self ;;
	esac
	if [ "$(id -u)" != 0 ]; then
		out=$(su -c "sh '$self'") || {
			notify "需要 root：请在 Magisk 弹窗中授权 Termux 后重试"
			exit 1
		}
		notify "$out"
		exit 0
	fi
}

do_switch() {
	target=$1
	ensure_daemon
	echo "$target" > "$STATE"
	# Daemon polls every 2 s while OFF; 5 s matches action.sh
	# (one full poll + one status refresh). Not re-measured via widget.
	sleep 5
	load_desc
	label=$(lvlname "$target")
	freq=$(tr -s ' ' < "$NODE" 2>/dev/null)
	j=$(junc_c)
	printf '%s\ncpu_max_freq: %s\n结温: %s C\n' "$label" "$freq" "$j"
}

do_status() {
	load_desc
	read cur < "$STATE" 2>/dev/null || cur=0
	case "$cur" in 1|2|3) : ;; *) cur=0 ;; esac
	label=$(lvlname "$cur")
	freq=$(tr -s ' ' < "$NODE" 2>/dev/null)
	j=$(junc_c)
	cfb=$(cat "$CFB" 2>/dev/null)
	if alive; then
		d=运行中
	else
		d=未运行
	fi
	printf '%s\nheld=%s\ncpu_max_freq: %s\n结温: %s C\ncfb=%s\n守护进程: %s\n' \
		"$label" "$(held_of)" "$freq" "$j" "$cfb" "$d"
}
