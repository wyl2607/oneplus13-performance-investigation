#!/system/bin/sh
# Hypothesis: the URCC inversion is a sustained-load / die-temperature response.
#
# Pass the package that is burning CPU as RUNAWAY_PKG. On the device under test this
# was a third-party app pegging one core for 8+ minutes of CPU time; the package name
# is redacted here (docs/PRIVACY.md). Find yours with:
#   top -b -n 1 -q -k -%CPU -m 5
RUNAWAY_PKG="${RUNAWAY_PKG:?set RUNAWAY_PKG to the offending package}"
# $RUNAWAY_PKG has been pegging one core (8+ min CPU time) and
# the cores sit at 52-59 C with the shell at 37.8 C. Remove the load, watch the cap.
# Reversible: force-stop only; the app restarts when opened.
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq

hot() { cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1; }
cpu7() { for z in /sys/class/thermal/thermal_zone*; do
           [ "$(cat $z/type 2>/dev/null)" = "cpu-1-1-1" ] && cat $z/temp; done; }

samp() { n=0
  while [ $n -lt $2 ]; do
    printf '%s t=%3ss p6=%s p0=%s maxtemp=%s cpu7=%s load=%s\n' "$1" "$n" \
      "$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)" \
      "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)" \
      "$(hot)" "$(cpu7)" "$(cut -d' ' -f1 /proc/loadavg)"
    n=$((n+5)); sleep 5
  done; }

echo "### node as found"; cat $NODE
echo "### PHASE 1 with the runaway still running"
samp LOADED 20

echo "### PHASE 2 force-stop the runaway"
am force-stop $RUNAWAY_PKG
echo "stopped; still-hot processes over 5% CPU:"
top -b -n 1 -q -k -%CPU -m 5 2>/dev/null | awk '$5+0>5 || $9+0>5 {print}'
samp COOLING 180

echo "### node after"; cat $NODE
echo "### DONE"
