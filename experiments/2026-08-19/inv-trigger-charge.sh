#!/system/bin/sh
# Does the URCC cluster inversion depend on the framework's charging state?
# The inversion is ACTIVE right now (prime 1689600 < mid 2400000), so this is a
# subtractive test: fake an unplug and see whether the prime cap is released.
# Fully reversible -- ends with `dumpsys battery reset`.
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq

samp() {  # samp <label> <seconds>
  n=0
  while [ $n -lt $2 ]; do
    printf '%s t=%ss %s | p6max=%s p0max=%s | plug=%s\n' \
      "$1" "$n" "$(cat $NODE 2>/dev/null | tr -s ' ')" \
      "$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)" \
      "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)" \
      "$(dumpsys battery 2>/dev/null | grep -m1 'USB powered' | tr -d ' ')"
    n=$((n+2)); sleep 2
  done
}

echo "### PHASE 1 baseline (plugged, as found)"
samp BASE 10

echo "### PHASE 2 fake unplug"
dumpsys battery unplug >/dev/null 2>&1
samp UNPLUG 40

echo "### PHASE 3 restore"
dumpsys battery reset >/dev/null 2>&1
samp RESET 20

echo "### final battery state"
dumpsys battery | grep -E 'USB powered|AC powered|status|level'
echo "### DONE"
