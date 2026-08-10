#!/system/bin/sh
# Single-thread equilibrium temperature at each candidate scaling_max_freq ceiling.
# Disables CFB for the duration so the userspace ceiling can bind, restores on every exit.
#
# Abort: junction > 95 C (trip point is 105 C) or shell > 42 C.

CFB=/sys/module/cpufreq_bouncing/parameters
P6=/sys/devices/system/cpu/cpufreq/policy6
Z27=/sys/class/thermal/thermal_zone27/temp   # cpu-1-1-0 (cpu6)
Z28=/sys/class/thermal/thermal_zone28/temp   # cpu-1-1-1 (cpu7)
ZSH=/sys/class/thermal/thermal_zone65/temp   # shell_back
ABORT_J=95000
ABORT_SH=42000
DUR=25
CEILINGS="2841600 3283200 3513600"

restore() {
  kill -9 $BP 2>/dev/null
  echo 1 > $CFB/enable
  echo 4320000 > $P6/scaling_max_freq
  svc power stayon false
}
trap 'echo "[trap] restoring"; restore; exit 1' INT TERM
svc power stayon usb

run_ceiling() {
  CEIL=$1
  echo 0 > $CFB/enable
  echo $CEIL > $P6/scaling_max_freq
  sleep 1
  echo "--- ceiling ${CEIL} (readback $(cat $P6/scaling_max_freq)) start j7=$(( $(cat $Z28)/1000 ))C ---"
  taskset 80 /system/bin/sh -c 'i=0; while [ $i -lt 999999999 ]; do i=$((i+1)); done' &
  BP=$!
  n=0; SUM=0; CNT=0; PEAK=0
  while [ $n -lt $DUR ]; do
    j7=$(cat $Z28); j6=$(cat $Z27); sh=$(cat $ZSH)
    [ $n -ge 10 ] && { SUM=$((SUM+j7)); CNT=$((CNT+1)); }   # average the settled window only
    [ "$j7" -gt "$PEAK" ] && PEAK=$j7
    [ $((n % 5)) -eq 0 ] && echo "   t+${n}s cur=$(( $(cat $P6/scaling_cur_freq)/1000 )) j6=$((j6/1000))C j7=$((j7/1000))C shell=$((sh/1000))C"
    if [ "$j7" -gt "$ABORT_J" ] || [ "$sh" -gt "$ABORT_SH" ]; then echo "   !! THERMAL ABORT"; break; fi
    sleep 1; n=$((n+1))
  done
  kill -9 $BP 2>/dev/null
  if [ $CNT -gt 0 ]; then
    echo "  => ceiling ${CEIL}: steady_avg_j7=$((SUM/CNT/1000))C peak=$((PEAK/1000))C"
  else
    echo "  => ceiling ${CEIL}: aborted early, peak=$((PEAK/1000))C"
  fi
  echo 1 > $CFB/enable
  echo 4320000 > $P6/scaling_max_freq
  echo "  cooldown 30s"; sleep 30
}

for c in $CEILINGS; do run_ceiling $c; done
restore
echo "FINAL cfb=$(cat $CFB/enable) p6max=$(cat $P6/scaling_max_freq)"
