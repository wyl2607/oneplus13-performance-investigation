#!/system/bin/sh
# Sustained all-core thermal characterisation. Default 900 s.
#
#   sh sustained-load.sh [seconds] [label]
#
# Thermal zones are resolved BY NAME. Indices are reassigned across reboots — see
# docs/METHODOLOGY.md trap 3, where a hardcoded index aborted a run on a sensor that was
# not the shell at all.
#
# Read-only with respect to the tune. Only touches the screen wakelock, which it restores.

DUR=${1:-900}
LBL=${2:-run}
LOG=/data/local/tmp/sustained.log
ABORT_J=95000
ABORT_SH=45000
MARK=8888ALLCORE8888          # unique enough to match, and absent from this script's own args

zone_by_name() {
  for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat $z/type 2>/dev/null)" = "$1" ] && { echo "$z/temp"; return 0; }
  done
  return 1
}
Z_J6=$(zone_by_name cpu-1-1-0)   || { echo "sensor cpu-1-1-0 not found"; exit 2; }
Z_J7=$(zone_by_name cpu-1-1-1)   || { echo "sensor cpu-1-1-1 not found"; exit 2; }
Z_CS=$(zone_by_name cpuss-1-1)   || { echo "sensor cpuss-1-1 not found"; exit 2; }
Z_S1=$(zone_by_name shell_front) || { echo "sensor shell_front not found"; exit 2; }
Z_S2=$(zone_by_name shell_back)  || { echo "sensor shell_back not found"; exit 2; }

P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6
BAT=/sys/class/power_supply/battery

PIDS=""
kill_load() {
  # Killing by recorded pid, not pkill -f: the pattern would also match the invoking
  # shell's own command line, and pkill left half the workers alive when this was tried.
  for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
  PIDS=""
}
restore() { kill_load; svc power stayon false; echo "RESTORED $(date)" >> $LOG; }
trap 'echo TRAP >> $LOG; restore; exit 1' INT TERM

svc power stayon usb
input keyevent KEYCODE_WAKEUP
sleep 3

: > $LOG
echo "start $(date) label=$LBL dur=${DUR}s" >> $LOG
echo "zones j6=$Z_J6 j7=$Z_J7 cluss=$Z_CS front=$Z_S1 back=$Z_S2" >> $LOG
echo "cfb=$(cat /sys/module/cpufreq_bouncing/parameters/enable) p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq)" >> $LOG
echo "sec p0cur p6cur j6 j7 cluss front back batt tstat" >> $LOG

i=0
while [ $i -lt 8 ]; do
  taskset $((1<<i)) /system/bin/sh -c 'i=0; while [ $i -lt 999999999 ]; do i=$((i+1)); done # '"$MARK" &
  PIDS="$PIDS $!"
  i=$((i+1))
done

n=0; TS=0
while [ $n -lt $DUR ]; do
  j6=$(cat $Z_J6); j7=$(cat $Z_J7); cs=$(cat $Z_CS); s1=$(cat $Z_S1); s2=$(cat $Z_S2)
  [ $((n % 60)) -eq 0 ] && TS=$(dumpsys thermalservice 2>/dev/null | grep -m1 "Thermal Status" | tr -dc '0-9')
  echo "$n $(( $(cat $P0/scaling_cur_freq)/1000 )) $(( $(cat $P6/scaling_cur_freq)/1000 )) $((j6/1000)) $((j7/1000)) $((cs/1000)) $((s1/1000)) $((s2/1000)) $(( $(cat $BAT/temp)/10 )) $TS" >> $LOG
  if [ "$j7" -gt "$ABORT_J" ] || [ "$j6" -gt "$ABORT_J" ]; then echo "ABORT junction at ${n}s" >> $LOG; break; fi
  if [ "$s1" -gt "$ABORT_SH" ] || [ "$s2" -gt "$ABORT_SH" ]; then echo "ABORT shell at ${n}s" >> $LOG; break; fi
  sleep 5; n=$((n+5))
done
echo "END at ${n}s" >> $LOG
restore

# Verify the workers are actually gone rather than assuming it.
sleep 2
LEFT=$(ps -A -o ARGS 2>/dev/null | grep -c "$MARK")
echo "workers remaining after restore: $((LEFT>0?LEFT-1:0))" >> $LOG
