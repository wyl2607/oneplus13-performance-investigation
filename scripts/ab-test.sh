#!/system/bin/sh
# The causation test: identical workload, identical thermal starting point, CFB on vs off.
# Run this before believing any parameter-value correlation.

CFB=/sys/module/cpufreq_bouncing/parameters
P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6
Z28=/sys/class/thermal/thermal_zone28/temp
ZSH=/sys/class/thermal/thermal_zone65/temp
ABORT_J=95000
ABORT_SH=42000
ITERS=8000000

restore() { kill -9 $BP 2>/dev/null; echo 1 > $CFB/enable; svc power stayon false; }
trap 'echo "[trap] restoring"; restore; exit 1' INT TERM
svc power stayon usb

now() { cut -d' ' -f1 /proc/uptime | tr -d '.'; }   # centiseconds; date +%s%N is broken on toybox

bench() {
  echo "  [$1] start p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq) j7=$(( $(cat $Z28)/1000 ))C"
  T0=$(now)
  taskset 80 /system/bin/sh -c 'i=0; while [ $i -lt '"$ITERS"' ]; do i=$((i+1)); done' &
  BP=$!
  n=0
  while kill -0 $BP 2>/dev/null; do
    j7=$(cat $Z28); sh=$(cat $ZSH)
    echo "   t+${n}s cur=$(( $(cat $P6/scaling_cur_freq)/1000 )) max=$(( $(cat $P6/scaling_max_freq)/1000 )) j7=$((j7/1000))C shell=$((sh/1000))C"
    if [ "$j7" -gt "$ABORT_J" ] || [ "$sh" -gt "$ABORT_SH" ]; then
      echo "   !! THERMAL ABORT"; kill -9 $BP 2>/dev/null; restore; exit 2
    fi
    sleep 1; n=$((n+1))
  done
  wait $BP 2>/dev/null
  echo "  [$1] elapsed_ms=$(( ($(now)-T0)*10 ))"
}

echo "===== PHASE A : CFB enabled (stock) ====="
echo 1 > $CFB/enable
bench A_stock

echo "cooldown 30s"; sleep 30

echo "===== PHASE B : CFB disabled ====="
echo 0 > $CFB/enable
bench B_nocfb

restore
echo "restored: cfb=$(cat $CFB/enable)"
