#!/system/bin/sh
# All-core sustained load at the proposed ceilings. This is the run that decides whether a
# ceiling is safe for daily use — single-thread results are not sufficient evidence.
#
# Abort: junction > 95 C (trip point is 105 C) or either shell sensor > 42 C.

CFB=/sys/module/cpufreq_bouncing/parameters
P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6
Z27=/sys/class/thermal/thermal_zone27/temp   # cpu6 junction
Z28=/sys/class/thermal/thermal_zone28/temp   # cpu7 junction
Z30=/sys/class/thermal/thermal_zone30/temp   # cpuss-1-1
ZS1=/sys/class/thermal/thermal_zone63/temp   # shell_front
ZS2=/sys/class/thermal/thermal_zone65/temp   # shell_back
ABORT_J=95000
ABORT_SH=42000
DUR=40
CEIL0=2918400
CEIL6=3283200

restore() {
  pkill -f 999999999 2>/dev/null
  echo 1 > $CFB/enable
  echo 3532800 > $P0/scaling_max_freq
  echo 4320000 > $P6/scaling_max_freq
  svc power stayon false
}
trap 'echo "[trap] restoring"; restore; exit 1' INT TERM
svc power stayon usb

echo 0 > $CFB/enable
echo $CEIL0 > $P0/scaling_max_freq
echo $CEIL6 > $P6/scaling_max_freq
sleep 1
echo "ceilings: p0=$(cat $P0/scaling_max_freq) p6=$(cat $P6/scaling_max_freq)"
echo "ALL-CORE load, ${DUR}s"
echo "sec  p0cur p6cur  j6   j7  cluss front back"

i=0
while [ $i -lt 8 ]; do
  taskset $((1<<i)) /system/bin/sh -c 'i=0; while [ $i -lt 999999999 ]; do i=$((i+1)); done' &
  i=$((i+1))
done

n=0; REASON="completed"
while [ $n -lt $DUR ]; do
  j6=$(cat $Z27); j7=$(cat $Z28); cs=$(cat $Z30); s1=$(cat $ZS1); s2=$(cat $ZS2)
  [ $((n % 5)) -eq 0 ] && printf "%3ss %6s %6s %3sC %3sC %3sC %3sC %3sC\n" "$n" \
     "$(( $(cat $P0/scaling_cur_freq)/1000 ))" "$(( $(cat $P6/scaling_cur_freq)/1000 ))" \
     "$((j6/1000))" "$((j7/1000))" "$((cs/1000))" "$((s1/1000))" "$((s2/1000))"
  if [ "$j7" -gt "$ABORT_J" ] || [ "$j6" -gt "$ABORT_J" ]; then REASON="ABORT junction"; break; fi
  if [ "$s1" -gt "$ABORT_SH" ] || [ "$s2" -gt "$ABORT_SH" ]; then REASON="ABORT shell"; break; fi
  sleep 1; n=$((n+1))
done

pkill -f 999999999 2>/dev/null
echo "END after ${n}s: $REASON"
dumpsys thermalservice | grep -m1 "Thermal Status"
restore
echo "restored: cfb=$(cat $CFB/enable) p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq)"
