#!/system/bin/sh
# urcc-demand-probe.sh
#
# Hypothesis: URCC's prime ceiling of 1689600 is not a stuck request but a
# demand-following policy. It ramps a cluster's ceiling down when that cluster
# is idle, and nothing can occupy the prime cluster because oplus_bsp_task_overload
# clamps app threads off it (section 27). If so, real prime demand should raise it.
#
# Writes NO kernel parameter. It reads sysfs, toggles the display, and runs a
# root-owned busy loop. Root is exempt from the task_overload clamp (section 27),
# so a root loop is the only way to put genuine sustained load on the prime cluster.
#
# Phase 0  baseline
# Phase 1  POSITIVE CONTROL - screen off/on, which section 28 established moves
#          this node (6:1689600 -> 6:2649600). If the probe cannot see that, no
#          null result from phase 2 is admissible.
# Phase 2  root busy loop pinned to cpu6+cpu7
# Phase 3  recovery after the load stops

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6
ABORT_J=90000

zone_by_name() {
  for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat $z/type 2>/dev/null)" = "$1" ] && { echo "$z/temp"; return 0; }
  done
  return 1
}
Z_J=$(zone_by_name cpu-1-1-1) || { echo "FATAL: junction zone not found"; exit 2; }
Z_S=$(zone_by_name shell_front) || { echo "FATAL: shell zone not found"; exit 2; }

PIDS=""
cleanup() {
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null
  PIDS=""
  svc power stayon false 2>/dev/null
}
trap 'echo "!! interrupted"; cleanup; exit 130' INT TERM

# node6 = the prime entry of the msm_performance node
node6() { cat $NODE 2>/dev/null | tr ' ' '\n' | grep '^6:' | cut -d: -f2; }
node0() { cat $NODE 2>/dev/null | tr ' ' '\n' | grep '^0:' | cut -d: -f2; }

sample() {
  echo "$1 t=$(cut -d. -f1 /proc/uptime) node0=$(node0) node6=$(node6) p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq) c6cur=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq) c4cur=$(cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq) j=$(cat $Z_J) shell=$(cat $Z_S)"
}

watch_for() {   # watch_for <tag> <seconds> <interval>
  n=0
  while [ $n -lt $2 ]; do
    j=$(cat $Z_J)
    if [ "$j" -gt $ABORT_J ]; then
      echo "!! THERMAL ABORT j=$j"
      cleanup
      exit 3
    fi
    sample "$1"
    n=$((n+$3))
    sleep $3
  done
}

echo "=== urcc-demand-probe start $(date) ==="
echo "junction zone: $Z_J   shell zone: $Z_S"
svc power stayon usb 2>/dev/null

echo
echo "--- PHASE 0: baseline, 15 s ---"
BASE6=$(node6)
echo "baseline node6=$BASE6"
watch_for P0 15 5

echo
echo "--- PHASE 1: POSITIVE CONTROL, screen off ---"
svc power stayon false 2>/dev/null
input keyevent 26
sleep 2
echo "wakefulness=$(dumpsys power | grep -m1 'mWakefulness=' | tr -d ' ')"
watch_for P1off 20 5
OFF6=$(node6)

echo
echo "--- PHASE 1: screen back on ---"
input keyevent 26
sleep 1
input keyevent 82
sleep 2
svc power stayon usb 2>/dev/null
echo "wakefulness=$(dumpsys power | grep -m1 'mWakefulness=' | tr -d ' ')"
watch_for P1on 30 5
ON6=$(node6)

echo
echo "POSITIVE CONTROL RESULT: baseline=$BASE6 screenoff=$OFF6 screenon_settled=$ON6"
if [ "$OFF6" = "$BASE6" ]; then
  echo "POSITIVE_CONTROL=FAIL  the node did not move for a change known to move it."
  echo "Phase 2 results are NOT admissible. Aborting."
  cleanup
  exit 4
fi
echo "POSITIVE_CONTROL=PASS  the probe can see this node change."

echo
echo "--- PHASE 2: root busy loop pinned to cpu6+cpu7, 75 s ---"
echo "uid=$(id -u)  (root is exempt from task_overload, section 27)"
taskset c0 sh -c 'while : ; do : ; done' &
PIDS="$!"
taskset c0 sh -c 'while : ; do : ; done' &
PIDS="$PIDS $!"
echo "workers: $PIDS"
sleep 1
for p in $PIDS; do
  echo "worker $p affinity=$(taskset -p $p 2>/dev/null) uclamp_max=$(grep -m1 'uclamp.max' /proc/$p/sched 2>/dev/null)"
done
watch_for P2load 75 5
LOAD6=$(node6)

echo
echo "--- PHASE 3: stop load, 30 s recovery ---"
cleanup
watch_for P3rec 30 5
REC6=$(node6)

echo
echo "=== RESULT ==="
echo "baseline node6   = $BASE6"
echo "screen-off node6 = $OFF6      (positive control)"
echo "screen-on node6  = $ON6"
echo "under prime load = $LOAD6"
echo "after load       = $REC6"
if [ "$LOAD6" -gt "$ON6" ] 2>/dev/null; then
  echo "VERDICT: prime demand RAISED the URCC ceiling. The inversion is demand-driven."
else
  echo "VERDICT: prime demand did NOT raise the URCC ceiling within 75 s."
fi
echo "PROBE_DONE"
