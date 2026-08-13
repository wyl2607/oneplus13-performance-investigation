#!/system/bin/sh
# Read-only: find who holds the prime ceiling at 1689600, and whether URCC
# still re-asserts. Writes nothing.

F=/proc/oplus_freqreq_monitor/fqm_dump

echo "=== all distinct requester comms in fqm_dump ==="
awk -F', ' 'NR>1 {print $11}' $F 2>/dev/null | sort | uniq -c | sort -rn

echo
echo "=== all distinct stacks ==="
awk -F', ' 'NR>1 {print $13}' $F 2>/dev/null | sort | uniq -c | sort -rn

echo
echo "=== any row mentioning msm_performance or urcc ==="
grep -i -e msm_performance -e urcc $F 2>/dev/null | head -20
echo "(count: $(grep -c -i -e msm_performance -e urcc $F 2>/dev/null))"

echo
echo "=== cluster1 rows, newest 15 by boot-ms ==="
awk -F', ' 'NR>1 && $4==1 {print $3", "$11", smallest_max="$7", this_max="$9}' $F 2>/dev/null | sort -t' ' -k1 -rn | head -15

echo
echo "=== does the node drift on its own? 6 reads over 30 s ==="
i=0
while [ $i -lt 6 ]; do
  echo "t=$(cut -d. -f1 /proc/uptime)s  node=$(cat /sys/kernel/msm_performance/parameters/cpu_max_freq | tr -s ' ')"
  echo "          p0max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) p6max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)"
  i=$((i+1))
  [ $i -lt 6 ] && sleep 5
done

echo
echo "=== urcc-related files / props ==="
ls -l /sys/kernel/msm_performance/parameters/ 2>/dev/null
getprop | grep -i -e urcc -e rcc 2>/dev/null

echo
echo "=== UrccWorker thread present? ==="
ps -AT -o PID,TID,NAME 2>/dev/null | grep -i -e urcc -e Urcc | head

echo
echo "HUNT_DONE"
