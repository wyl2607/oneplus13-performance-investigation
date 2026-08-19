#!/system/bin/sh
# Magisk Action button: cycles 关 -> 日常 -> 高性能 -> 极限 -> 关, then reports real state.
MODDIR=${0%/*}
STATEDIR=/data/adb/op13perf
STATE=$STATEDIR/state
SINCE=$STATEDIR/since
STATUS=$STATEDIR/status
CONF=$STATEDIR/conf
PIDF=$STATEDIR/pid
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq

mkdir -p "$STATEDIR"
[ -f "$STATE" ] || echo 0 > "$STATE"

# Verify the daemon by its cmdline, not by the pid alone -- a bare pid file
# survives a reboot and pid reuse then makes a dead daemon look alive.
alive() {
	[ -f "$PIDF" ] || return 1
	read p < "$PIDF" 2>/dev/null || return 1
	[ -d "/proc/$p" ] || return 1
	tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q perfd.sh
}

if ! alive; then
	nohup "$MODDIR/perfd.sh" >/dev/null 2>&1 &
	echo $! > "$PIDF"
	sleep 1
fi

read cur < "$STATE" 2>/dev/null || cur=0
case "$cur" in 1|2|3) : ;; *) cur=0 ;; esac
next=$(( (cur + 1) % 4 ))
date +%s > "$SINCE"
echo "$next" > "$STATE"

# Level label and description come from desc.sh, which reads the conf the daemon
# reads. Three hand-maintained copies of these numbers is exactly how README,
# action.sh and perfd.sh ended up disagreeing on every single value.
[ -f "$CONF" ] && . "$CONF"
. "$MODDIR/desc.sh"

LABEL=$(lvlname "$next")
write_prop "$next" "$MODDIR/module.prop"

echo "切换为：$LABEL"
echo

# The daemon polls every 2 s while OFF, so 2 s here races it and prints the old
# state. Wait past one full poll plus a status refresh before reporting.
sleep 5
echo "--- 实际内核状态 ---"
echo "cpu_max_freq : $(tr -s ' ' < $NODE 2>/dev/null)"
echo "policy6 上限 : $(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq 2>/dev/null)"
echo "policy0 上限 : $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null)"
for z in /sys/class/thermal/thermal_zone*; do
	read t < "$z/type" 2>/dev/null || continue
	[ "$t" = "cpu-1-1-1" ] && echo "结温         : $(( $(cat $z/temp) / 1000 )) C"
done
echo "守护进程     : $(alive && echo 运行中 || echo 未运行)"
[ -f "$STATUS" ] && echo "上报         : $(cat $STATUS)"

if [ "$next" = 3 ]; then
	echo
	echo "警告：极限档假定 40W 散热器已接上，模块无法自己检测。裸机跑这一档只会更快"
	echo "撞红线退让，成绩不会更好。"
fi

if [ "$next" != 0 ]; then
	echo
	echo "提示：超大核上限要等前台有负载才会顶到目标值；空载时内核自己会降频，这是正常的。"
fi
