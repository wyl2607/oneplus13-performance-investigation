#!/system/bin/sh
# Magisk Action button: cycles 关 -> 日常 -> 极限 -> 关, then reports real state.
MODDIR=${0%/*}
STATEDIR=/data/adb/op13perf
STATE=$STATEDIR/state
SINCE=$STATEDIR/since
STATUS=$STATEDIR/status
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
case "$cur" in 1|2) : ;; *) cur=0 ;; esac
next=$(( (cur + 1) % 3 ))
date +%s > "$SINCE"
echo "$next" > "$STATE"

case "$next" in
	0) LABEL="已关闭";   DESC="[ 已关闭 ] 点 Action 循环切换 关 / 日常 / 极限。" ;;
	1) LABEL="日常档";   DESC="[ 日常档 ] 超大核 2918400，红线 85C，30 分钟自动关。" ;;
	2) LABEL="极限档";   DESC="[ 极限档 ] 超大核 3283200，红线 98C，15 分钟自动关。跑分/接散热用。" ;;
esac

# reflect state in the module list itself
sed -i "s|^description=.*|description=$DESC 解除 URCC 倒挂与 uclamp 钳位；重启后一定回到关闭。|" "$MODDIR/module.prop" 2>/dev/null
sed -i "s|^version=.*|version=v1.0.0-$LABEL|" "$MODDIR/module.prop" 2>/dev/null

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

if [ "$next" != 0 ]; then
	echo
	echo "提示：超大核上限要等前台有负载才会顶到目标值；空载时内核自己会降频，这是正常的。"
fi
