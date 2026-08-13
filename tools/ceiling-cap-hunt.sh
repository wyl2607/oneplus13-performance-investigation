#!/system/bin/sh
# Who holds the prime cluster at 3283200? formula-points.sh could not pin above it
# even though the msm_performance node accepted the value.
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
P6=/sys/devices/system/cpu/cpufreq/policy6
F=/proc/oplus_freqreq_monitor/fqm_dump

echo "=== before ==="
echo "node: $(cat $NODE)"
echo "p6max=$(cat $P6/scaling_max_freq) hwmax=$(cat $P6/cpuinfo_max_freq)"

echo
echo "=== writing 6:4320000 7:4320000 (mid left alone) ==="
W=""; for c in 0 1 2 3 4 5; do W="$W $c:$(cat $NODE | tr ' ' '\n' | grep '^0:' | cut -d: -f2)"; done
for c in 6 7; do W="$W $c:4320000"; done
echo $W > $NODE
sleep 1
echo "node: $(cat $NODE)"
echo "p6max=$(cat $P6/scaling_max_freq)   <- if below 4320000, another requester holds it"

echo
echo "=== cluster-1 rows in fqm_dump, newest 12 ==="
awk -F', ' 'NR>1 && $4==1 {print $3"  "$11"  this_max="$9"  aggregate_smallest_max="$7"  "$13}' $F 2>/dev/null \
  | sort -rn | head -12

echo
echo "=== cooling devices with non-zero state ==="
for c in /sys/class/thermal/cooling_device*; do
  s=$(cat $c/cur_state 2>/dev/null)
  [ "$s" = "0" ] || echo "$(cat $c/type 2>/dev/null) cur_state=$s max=$(cat $c/max_state 2>/dev/null)"
done

echo
echo "=== thermal ==="
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat $z/type 2>/dev/null)
  case "$t" in cpu-1-1-1|shell_front) echo "$t $(cat $z/temp 2>/dev/null)" ;; esac
done
echo "Thermal Status: $(dumpsys thermalservice 2>/dev/null | grep -m1 'Thermal Status')"

echo
echo "=== cfb ==="
echo "enable=$(cat /sys/module/cpufreq_bouncing/parameters/enable 2>/dev/null)"
echo "config: $(cat /sys/module/cpufreq_bouncing/parameters/config 2>/dev/null | head -3)"

echo
echo "=== game_opt ==="
cat /proc/game_opt/cpu_max_freq 2>/dev/null

echo
echo "=== restoring node to 3283200 then to stock-ish ==="
W=""; for c in 0 1 2 3 4 5; do W="$W $c:2400000"; done; for c in 6 7; do W="$W $c:1689600"; done
echo $W > $NODE
sleep 1
echo "node: $(cat $NODE)"
echo "p6max=$(cat $P6/scaling_max_freq)"
echo "CAPHUNT_DONE"
