#!/system/bin/sh
# Confirm the device is back to stock after an experiment run.
#
# The first version of this script searched only for the marker strings used by the
# harnesses that existed when it was written. A later experiment used a different
# marker AND launched its workers under renamed binaries, so three busy loops ran
# unnoticed for 15 minutes while this script reported "clean". It now checks by
# CPU-burn as well as by name, which is the property that actually matters.

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6

echo "=== ceilings ==="
echo "node:  $(cat $NODE 2>/dev/null)"
echo "p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq)"
echo "cfb enable=$(cat /sys/module/cpufreq_bouncing/parameters/enable 2>&1)"
echo "screen: $(dumpsys power 2>/dev/null | grep -m1 mWakefulness=)"
echo "(screen-off policy is 1996800/2649600; screen-on stock is 2400000/1689600)"

echo
echo "=== experiment processes by name ==="
FOUND=0
for pat in plsleep plsleep2 plsleepprobe gzabrun gzabinv gzabprobe fpprobe trigprobe_busy w_spin w_slow w_fast spin_; do
  for p in $(pgrep -f "$pat" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    echo "  pid=$p comm=$(cat /proc/$p/comm 2>/dev/null) pat=$pat"
    FOUND=1
  done
done
[ "$FOUND" = "0" ] && echo "  none"

echo
echo "=== any non-system process burning CPU (the check that actually matters) ==="
# Sample every task's utime+stime over 1 s and report anything above 20% of a core.
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  u=$(cat /proc/$p/uid_map 2>/dev/null >/dev/null; awk '/^Uid:/{print $2}' /proc/$p/status 2>/dev/null)
  [ -z "$u" ] && continue
  [ "$u" -lt 10000 ] 2>/dev/null && continue          # skip system/root services
  t=$(sed 's/^.*) //' /proc/$p/stat 2>/dev/null | awk '{print $12+$13}')
  [ -n "$t" ] && echo "$p $t" >> /data/local/tmp/.vc_snap
done
sleep 1
BUSY=0
while read p t0; do
  t1=$(sed 's/^.*) //' /proc/$p/stat 2>/dev/null | awk '{print $12+$13}')
  [ -z "$t1" ] && continue
  d=$((t1 - t0))
  if [ "$d" -gt 20 ]; then
    echo "  BUSY pid=$p comm=$(cat /proc/$p/comm 2>/dev/null) uid=$(awk '/^Uid:/{print $2}' /proc/$p/status 2>/dev/null) ticks/s=$d"
    BUSY=1
  fi
done < /data/local/tmp/.vc_snap
rm -f /data/local/tmp/.vc_snap
[ "$BUSY" = "0" ] && echo "  none above 20% of a core"

echo
echo "=== thermal ==="
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat $z/type 2>/dev/null)
  case "$t" in cpu-1-1-1|shell_front) echo "  $t $(cat $z/temp 2>/dev/null)" ;; esac
done
echo "  $(dumpsys thermalservice 2>/dev/null | grep -m1 'Thermal Status')"

echo
echo "=== test data ==="
du -sh /data/local/tmp/gzab 2>/dev/null || echo "  /data/local/tmp/gzab absent (rebuild: tools/restore-testdata.sh)"
echo "CLEAN_CHECK_DONE"
