#!/system/bin/sh
# placement-vs-sleep.sh
#
# Why does a 466 clamp drive Geekbench off the prime cluster (8% residency,
# section 26) but not gzip (99-100% residency, section 31)?
#
# Hypothesis: displacement happens at WAKEUP. Linux picks a CPU for a task in
# select_task_rq when the task wakes; that is where the clamped utilisation gets
# compared against cluster capacity. A task that never sleeps is never re-placed,
# so it keeps the prime core it was promoted to before the clamp landed, and the
# clamp costs it only frequency. Geekbench's pool workers sleep between subtests
# and are therefore re-placed constantly, every time against a clamped utilisation.
#
# Test: identical busy work under an app uid, unpinned, differing ONLY in whether
# the task sleeps periodically. Measure prime residency AFTER the clamp lands.
#
# Confound, stated up front: the duty-cycle variant forks a `sleep` child per
# cycle and the spin variant forks nothing, so the two are not matched on fork
# rate. The prediction being tested is a large placement difference, not a small one.
#
# Kernel writes: cpu_max_freq only (pinned, restored on exit).

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6
APPUID=10999
DUR=60
TARGET_MID=2918400
TARGET_PRIME=3283200

node_get() { cat $NODE 2>/dev/null | tr ' ' '\n' | grep "^$1:" | cut -d: -f2; }
read_psr() { sed 's/^.*) //' /proc/$1/stat 2>/dev/null | awk '{print $37}'; }
read_ucl() { awk '/^uclamp\.max /{print $NF; exit}' /proc/$1/sched 2>/dev/null; }

zone_by_name() {
  for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat $z/type 2>/dev/null)" = "$1" ] && { echo "$z/temp"; return 0; }
  done
  return 1
}
Z_J=$(zone_by_name cpu-1-1-1) || exit 2

ORIG0=$(node_get 0); ORIG6=$(node_get 6)
PINPID=""
cleanup() {
  [ -n "$PINPID" ] && kill -9 $PINPID 2>/dev/null
  PINPID=""
  pkill -9 -f 'plsleepprobe' 2>/dev/null
  W=""; for c in 0 1 2 3 4 5; do W="$W $c:$ORIG0"; done; for c in 6 7; do W="$W $c:$ORIG6"; done
  echo $W > $NODE 2>/dev/null
  svc power stayon false 2>/dev/null
}
trap 'cleanup; exit 130' INT TERM
pin() { W=""; for c in 0 1 2 3 4 5; do W="$W $c:$TARGET_MID"; done; for c in 6 7; do W="$W $c:$TARGET_PRIME"; done; echo $W > $NODE 2>/dev/null; }

# Keep the instrument off the cluster it measures (see ab-real-workload.sh).
taskset -p 3f $$ >/dev/null 2>&1
svc power stayon usb 2>/dev/null

echo "=== placement-vs-sleep $(date) ==="
echo "harness affinity: $(taskset -p $$ 2>/dev/null | sed 's/.*: *//')"

trial() {
  NAME="$1"; BODY="$2"
  echo
  echo "===== $NAME ====="
  n=0; while [ $n -lt 60 ]; do j=$(cat $Z_J); [ "$j" -lt 45000 ] && break; n=$((n+5)); sleep 5; done
  echo "  start junction=$(cat $Z_J)"
  pin; sleep 1
  echo "  ceiling p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq)"

  su $APPUID -c "taskset ff sh -c '$BODY # plsleepprobe'" &
  sleep 1

  # `su`'s own cmdline contains the marker, so pgrep -f matches the idle parent as
  # well as the shell doing the work -- taking the first match monitors a sleeping
  # process and yields a confident 0%-prime, never-clamped null. Pick the candidate
  # that is actually accumulating CPU time, and refuse to proceed if none is.
  PID=""
  BESTD=0
  CANDS=$(pgrep -u $APPUID -f plsleepprobe 2>/dev/null)
  for c in $CANDS; do
    a=$(sed 's/^.*) //' /proc/$c/stat 2>/dev/null | awk '{print $12+$13}')
    echo "$a" > /data/local/tmp/gzab/.t_$c
  done
  sleep 1
  for c in $CANDS; do
    a=$(cat /data/local/tmp/gzab/.t_$c 2>/dev/null)
    b=$(sed 's/^.*) //' /proc/$c/stat 2>/dev/null | awk '{print $12+$13}')
    [ -z "$a" ] || [ -z "$b" ] && continue
    d=$((b - a))
    echo "  candidate pid=$c cpu_ticks_in_1s=$d  ($(cat /proc/$c/comm 2>/dev/null))"
    if [ "$d" -gt "$BESTD" ]; then BESTD=$d; PID=$c; fi
    rm -f /data/local/tmp/gzab/.t_$c
  done
  if [ -z "$PID" ] || [ "$BESTD" -lt 20 ]; then
    echo "  !! no candidate is burning CPU (best=$BESTD ticks/s). Probe target invalid, skipping trial."
    pkill -9 -f 'plsleepprobe' 2>/dev/null
    return
  fi
  echo "  pid=$PID comm=$(cat /proc/$PID/comm 2>/dev/null) cpu_ticks_in_1s=$BESTD affinity=$(taskset -p $PID 2>/dev/null | sed 's/.*: *//')"

  ( while kill -0 $PID 2>/dev/null; do pin; sleep 0.5; done ) &
  PINPID=$!

  CSV=/data/local/tmp/gzab/plsleep_$NAME.csv
  echo "t_ms,uclamp,psr" > $CSV
  T0=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
  CLAMP_AT=""
  n=0
  while [ $n -lt $((DUR*4)) ]; do
    kill -0 $PID 2>/dev/null || break
    U=$(read_ucl $PID); P=$(read_psr $PID)
    T=$(( ($(cut -d' ' -f1 /proc/uptime | tr -d '.') - T0) * 10 ))
    echo "$T,$U,$P" >> $CSV
    [ -z "$CLAMP_AT" ] && [ -n "$U" ] && [ "$U" != "1024" ] && CLAMP_AT=$T
    j=$(cat $Z_J); [ "$j" -gt 92000 ] && { echo "  !! thermal abort $j"; break; }
    n=$((n+1)); sleep 0.25
  done

  [ -n "$PINPID" ] && kill -9 $PINPID 2>/dev/null; PINPID=""
  pkill -9 -f 'plsleepprobe' 2>/dev/null

  echo "  clamp landed at: ${CLAMP_AT:-never} ms"
  awk -F, -v ca="${CLAMP_AT:--1}" 'NR>1 {
      n++; if ($3==6||$3==7) pr++;
      if (ca>=0 && $1+0 >= ca+0) { na++; if ($3==6||$3==7) pra++ }
      if (ca>=0 && $1+0 <  ca+0) { nb++; if ($3==6||$3==7) prb++ }
    }
    END {
      printf "  samples=%d  prime_residency_overall=%.1f%%\n", n, pr*100/n;
      if (nb>0) printf "  before clamp: n=%d prime=%.1f%%\n", nb, prb*100/nb;
      if (na>0) printf "  AFTER clamp:  n=%d prime=%.1f%%\n", na, pra*100/na;
    }' $CSV
  echo "  uclamp values seen: $(awk -F, 'NR>1{print $2}' $CSV | sort -u | tr '\n' ' ')"
}

# Never sleeps: one continuously runnable task.
trial spin 'i=0; while : ; do i=$((i+1)); done'

# Sleeps ~10 ms per cycle, so it is re-placed by select_task_rq on every wakeup.
#
# The iteration count matters. A first attempt used 3000, which gave only ~54%
# duty; a task at 54% utilisation fits the mid cluster on utilisation alone, so it
# was never promoted to prime and never clamped, and the trial tested nothing.
# 40000 iterations puts the busy phase near 190 ms against a ~15 ms sleep, for
# >90% duty -- high enough to be promoted, while still waking ~5 times a second.
# The reported cpu_ticks_in_1s must be close to the spin variant's for the
# comparison to be about sleeping rather than about load.
trial duty 'while : ; do i=0; while [ $i -lt 40000 ]; do i=$((i+1)); done; sleep 0.01; done'

cleanup
echo
echo "PLSLEEP_DONE"
