#!/system/bin/sh
# READ-ONLY GPU sampler. Modifies nothing. Run it, then start a GPU workload.
G=/sys/class/kgsl/kgsl-3d0
LOG=/data/local/tmp/gpu_sample.log
DUR=${1:-360}

# resolve the 'gpu' cooling device and the gpuss thermal zones dynamically
GCDEV=""
cd /sys/class/thermal
for c in cooling_device*; do
  [ "$(cat $c/type 2>/dev/null)" = "gpu" ] && GCDEV=/sys/class/thermal/$c && break
done
GZONES=""
for z in thermal_zone*; do
  case "$(cat $z/type 2>/dev/null)" in gpuss-*) GZONES="$GZONES /sys/class/thermal/$z/temp";; esac
done

{
  echo "# gpu cooling device: ${GCDEV:-NOT FOUND} (max_state=$(cat $GCDEV/max_state 2>/dev/null))"
  echo "# freq table MHz: $(cat $G/freq_table_mhz)"
  echo "# max_pwrlevel=$(cat $G/max_pwrlevel) min_pwrlevel=$(cat $G/min_pwrlevel) lm=$(cat $G/lm) bcl=$(cat $G/bcl)"
  echo "#"
  echo "# sec  gpuMHz busy% thermal_pwrlvl cdev throttling gpuTemp gpussMax cpu7j shell p6cur"
} > $LOG

n=0
while [ $n -lt $DUR ]; do
  gmax=0
  for z in $GZONES; do t=$(cat $z 2>/dev/null); [ "${t:-0}" -gt "$gmax" ] && gmax=$t; done
  printf "%5s %6s %5s %3s %4s %3s %7s %7s %5s %5s %6s\n" \
    "$n" \
    "$(( $(cat $G/gpuclk 2>/dev/null || echo 0)/1000000 ))" \
    "$(cat $G/gpu_busy_percentage 2>/dev/null | tr -d ' %')" \
    "$(cat $G/thermal_pwrlevel 2>/dev/null)" \
    "$(cat $GCDEV/cur_state 2>/dev/null)" \
    "$(cat $G/throttling 2>/dev/null)" \
    "$(( $(cat $G/temp 2>/dev/null || echo 0)/1000 ))" \
    "$((gmax/1000))" \
    "$(( $(cat /sys/class/thermal/thermal_zone28/temp)/1000 ))" \
    "$(( $(cat /sys/class/thermal/thermal_zone65/temp)/1000 ))" \
    "$(( $(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_cur_freq)/1000 ))" >> $LOG
  sleep 1
  n=$((n+1))
done
echo "# done" >> $LOG
