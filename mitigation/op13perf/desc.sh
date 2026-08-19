#!/system/bin/sh
# The module list's label and description are written by two scripts -- action.sh
# on a switch and service.sh at boot. They are generated here, from the conf the
# daemon itself reads, so there is one source of these numbers. Three hand-kept
# copies is how README, action.sh and perfd.sh came to disagree on every field.
# Sourced, not executed. Expects the conf to be sourced already.

lvlname() {
	case "$1" in 1) echo "日常档" ;; 2) echo "高性能档" ;; 3) echo "极限档" ;; *) echo "已关闭" ;; esac
}

_tmo() { [ "${1:-0}" -gt 0 ] 2>/dev/null && echo "$(( $1 / 60 )) 分钟自动关" || echo "常开"; }

lvldesc() {
	case "$1" in
		1) echo "[ 日常档·裸机 ] 超大核 ${DAILY_P6}，红线 $(( ${DAILY_GATE:-0} / 1000 ))C，$(_tmo ${DAILY_TIMEOUT:-0})。" ;;
		2) echo "[ 高性能档·裸机短时 ] 超大核 ${PERF_P6}，红线 $(( ${PERF_GATE:-0} / 1000 ))C，$(_tmo ${PERF_TIMEOUT:-0})。" ;;
		3) echo "[ 极限档·须接 40W 散热器 ] 超大核 ${EXTREME_P6}，红线 $(( ${EXTREME_GATE:-0} / 1000 ))C，$(_tmo ${EXTREME_TIMEOUT:-0})。" ;;
		*) echo "[ 已关闭 ] 点 Action 循环切换 关 / 日常 / 高性能 / 极限。" ;;
	esac
}

# Writes both fields together. They live in one file and drifted apart precisely
# because two scripts each wrote only the field it cared about.
write_prop() {
	_l=$1; _p=$2
	sed -i "s|^version=.*|version=v1.2.0-$(lvlname "$_l")|" "$_p" 2>/dev/null
	sed -i "s|^description=.*|description=$(lvldesc "$_l") 解除 URCC 倒挂与 uclamp 钳位；重启后回到「$(lvlname "${BOOT_LEVEL:-1}")」(BOOT_LEVEL=${BOOT_LEVEL:-1})。|" "$_p" 2>/dev/null
}
