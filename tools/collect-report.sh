#!/system/bin/sh
# Read-only. Changes nothing. Collects the one data point needed to determine whether
# cpufreq_bouncing's limit_level is stock for the OnePlus 13 or specific to one unit.
#
#   adb push contribute-comparison.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/contribute-comparison.sh'
#
# Paste the output into an issue. No serial number, IMEI, or carrier data is collected.

echo "=== build ==="
getprop ro.build.fingerprint
getprop ro.build.version.security_patch
getprop ro.product.vendor.name
getprop ro.board.platform
echo "kernel: $(cut -d' ' -f3 /proc/version)"

echo
echo "=== cpufreq_bouncing ==="
if [ -f /sys/module/cpufreq_bouncing/parameters/config ]; then
  echo "scmversion: $(cat /sys/module/cpufreq_bouncing/scmversion 2>/dev/null)"
  echo "enable: $(cat /sys/module/cpufreq_bouncing/parameters/enable 2>/dev/null)"
  echo "freq_qos_check: $(cat /sys/module/cpufreq_bouncing/parameters/freq_qos_check 2>/dev/null)"
  echo "decay: $(cat /sys/module/cpufreq_bouncing/parameters/decay 2>/dev/null)"
  grep -E "^clus|limit_freq|limit_level|limit_thres|max_freq|min_freq" \
      /sys/module/cpufreq_bouncing/parameters/config
else
  echo "module not present"
fi

echo
echo "=== cpufreq policies ==="
for p in /sys/devices/system/cpu/cpufreq/policy*; do
  echo "$(basename $p): cpus=$(cat $p/related_cpus)"
  echo "  cpuinfo_max=$(cat $p/cpuinfo_max_freq)  scaling_max=$(cat $p/scaling_max_freq)"
  echo "  governor=$(cat $p/scaling_governor)  driver=$(cat $p/scaling_driver)"
done

echo
echo "=== display state (matters — see docs/METHODOLOGY.md) ==="
dumpsys display 2>/dev/null | grep -m1 mScreenState
dumpsys power 2>/dev/null | grep -m1 mWakefulness=

echo
echo "=== thermal ==="
dumpsys thermalservice 2>/dev/null | grep -m1 "Thermal Status"
cd /sys/class/thermal 2>/dev/null && for z in thermal_zone*; do
  t=$(cat $z/temp 2>/dev/null); n=$(cat $z/type 2>/dev/null)
  case "$n" in cpu-1-1-1|shell_back|shell_front) echo "  $n = $t";; esac
done

echo
echo "=== msm_performance (screen-state dependent) ==="
cat /sys/kernel/msm_performance/parameters/cpu_max_freq 2>/dev/null || echo "n/a"
