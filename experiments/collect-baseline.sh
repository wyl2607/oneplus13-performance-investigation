#!/system/bin/sh
# Read-only full state dump used to produce docs/DATA.md.

P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6

echo "########## display / power ##########"
dumpsys display | grep -m1 mScreenState
dumpsys power | grep -m1 mWakefulness=

echo
echo "########## cpufreq ##########"
for p in $P0 $P6; do
  echo "--- $(basename $p) cpus=$(cat $p/related_cpus)"
  echo "cpuinfo_max = $(cat $p/cpuinfo_max_freq)"
  echo "scaling_max = $(cat $p/scaling_max_freq)"
  echo "scaling_cur = $(cat $p/scaling_cur_freq)"
  echo "governor    = $(cat $p/scaling_governor)"
  echo "OPP table   : $(cat $p/scaling_available_frequencies)"
  echo "time_in_state:"; cat $p/stats/time_in_state
done

echo
echo "########## cpufreq_bouncing ##########"
cat /sys/module/cpufreq_bouncing/parameters/config
for p in enable decay freq_qos_check sleep_range_ms core_boost_lat_ns self_activate core_ctl_check; do
  echo "$p = $(cat /sys/module/cpufreq_bouncing/parameters/$p 2>/dev/null)"
done

echo
echo "########## msm_performance ##########"
for f in /sys/kernel/msm_performance/parameters/*; do
  echo "$(basename $f) = $(cat $f 2>/dev/null)"
done

echo
echo "########## thermal ##########"
dumpsys thermalservice | grep -m1 "Thermal Status"
echo "-- hottest zones --"
cd /sys/class/thermal
for z in thermal_zone*; do
  t=$(cat $z/temp 2>/dev/null); n=$(cat $z/type 2>/dev/null)
  [ -n "$t" ] && echo "$t $n $z"
done | sort -rn | head -20
echo "-- non-zero cooling devices --"
for c in cooling_device*; do
  s=$(cat $c/cur_state 2>/dev/null)
  [ "$s" != "0" ] && echo "$(cat $c/type) cur=$s max=$(cat $c/max_state)"
done
echo "(none listed above means every cooling device is at cur_state=0)"

echo
echo "########## freq_qos requesters ##########"
echo "-- non-cpufreq_bouncing entries --"
grep -v cpufreq_bouncing /proc/oplus_freqreq_monitor/fqm_dump 2>/dev/null | tail -15
