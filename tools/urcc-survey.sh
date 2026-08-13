#!/system/bin/sh
# Read-only survey of the URCC / msm_performance ceiling state.
# Writes nothing. Section 28 blocker: prime ceiling held below mid ceiling.

P=/sys/kernel/msm_performance/parameters

echo "=== uptime / clock ==="
cat /proc/uptime
date

echo
echo "=== msm_performance parameters (name = value, perms) ==="
for f in $P/*; do
  [ -f "$f" ] || continue
  printf '%s  %s  ' "$(basename $f)" "$(ls -l $f | awk '{print $1" "$3" "$4}')"
  cat "$f" 2>/dev/null | head -2
  echo
done

echo
echo "=== per-policy cpufreq ==="
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
  echo "$(basename $pol) cur=$(cat $pol/scaling_cur_freq) max=$(cat $pol/scaling_max_freq) min=$(cat $pol/scaling_min_freq) hwmax=$(cat $pol/cpuinfo_max_freq) gov=$(cat $pol/scaling_governor)"
done

echo
echo "=== display / power ==="
dumpsys display 2>/dev/null | grep -m2 'mScreenState'
dumpsys power 2>/dev/null | grep -m1 'mWakefulness='

echo
echo "=== URCC service / process ==="
getprop | grep -i urcc
echo "--- ps ---"
ps -A -o PID,USER,NAME 2>/dev/null | grep -i urcc

echo
echo "=== freq_qos requesters (fqm_dump, last 40) ==="
tail -40 /proc/oplus_freqreq_monitor/fqm_dump 2>/dev/null

echo
echo "=== thermal (by name, junction + shell) ==="
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat $z/type 2>/dev/null)
  case "$t" in
    cpu-1-1-1|cpu-1-0-0|shell_front|shell_frame|shell_back)
      echo "$t $(cat $z/temp 2>/dev/null)" ;;
  esac
done
echo "Thermal Status: $(dumpsys thermalservice 2>/dev/null | grep -m1 'Thermal Status')"

echo
echo "=== cooling devices non-zero ==="
for c in /sys/class/thermal/cooling_device*; do
  s=$(cat $c/cur_state 2>/dev/null)
  [ "$s" = "0" ] || echo "$(cat $c/type 2>/dev/null) cur_state=$s"
done

echo
echo "=== cpufreq_bouncing ==="
for f in /sys/module/cpufreq_bouncing/parameters/*; do
  echo "$(basename $f)=$(cat $f 2>/dev/null | head -1)"
done

echo
echo "SURVEY_DONE"
