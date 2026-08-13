#!/system/bin/sh
# Confirm the device is back to stock after an experiment run.
echo "node:  $(cat /sys/kernel/msm_performance/parameters/cpu_max_freq)"
echo "p0max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) p6max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)"
echo "cfb enable=$(cat /sys/module/cpufreq_bouncing/parameters/enable 2>&1)"
echo "--- leftover experiment processes (excluding this script) ---"
for p in $(pgrep -f plsleepprobe 2>/dev/null; pgrep -f gzabrun 2>/dev/null; pgrep -f gzabprobe 2>/dev/null); do
  [ "$p" = "$$" ] && continue
  echo "pid=$p comm=$(cat /proc/$p/comm 2>/dev/null) cmdline=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-90)"
done
echo "--- app-uid gzip ---"
pgrep -x gzip 2>/dev/null | wc -l
echo "--- uclamp of any surviving app task ---"
echo "stayon: $(dumpsys power 2>/dev/null | grep -m1 mWakefulness=)"
echo "CLEAN_CHECK_DONE"
