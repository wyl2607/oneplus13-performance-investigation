#!/system/bin/sh
# ab-inversion-cost.sh
#
# THREE arms, because section 31 measured the uclamp guard while holding URCC's
# cluster inversion constant, and never measured what that inversion itself costs.
# It is the device's stock screen-on steady state (section 29), so it is what the
# owner actually lives with every day, and it caps the two fastest cores BELOW the
# mid cores.
#
#   S  stock      -- URCC's inverted ceiling left in place, no uclamp intervention
#   A  pinned     -- ceiling pinned 2918400/3283200, no uclamp intervention
#   B  pinned+ucl -- ceiling pinned, uclamp.max held at 1024
#
# S->A isolates the inversion. A->B isolates the uclamp guard. S->B is the total.
#
# Note that S and A are expected to differ in *placement* as well as clock: with
# prime capped below mid, the scheduler correctly declines to promote, so arm S
# should run on the mid cluster (section 30).
#
# Design notes, each one earned:
#
#  * ONE long-lived single-threaded process. Not a pipeline (a `cat` partner adds a
#    second runnable thread to a placement measurement) and not a loop of short
#    processes (each starts unclamped, and the ~5 s clamp latency of section 27
#    would never be reached).
#  * App uid. Root and system are exempt from the guard (section 27), so a root
#    workload cannot reproduce what an app experiences.
#  * The ceiling is PINNED TO THE SAME VALUE IN BOTH ARMS via msm_performance's own
#    node. URCC's screen-on steady state inverts the clusters (section 29), which
#    would otherwise make prime placement a penalty and invert the whole result.
#    Pinning makes URCC a controlled constant, not a variable under test.
#  * Interleaved order ABBABAAB, 4 runs per arm, so thermal drift and cache state
#    cannot align with the arm.
#  * The sampler is the one validated by probe-selftest.sh, which passed a uclampset
#    positive control before this script was allowed to take any data.
#
# Kernel writes: cpu_max_freq (restored on every exit path) and uclampset on its own
# child in arm B. Nothing persists across a reboot.

DIR=/data/local/tmp/gzab
BIG=$DIR/big.dat
OUT=$DIR/results_inv
APPUID=10999
MARK=gzabinv

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6
TOL=/proc/task_overload/abnormal_task

TARGET_MID=2918400
TARGET_PRIME=3283200
ORDER="S A B B A S A S B"
# usage: sh ab-inversion-cost.sh [arm ...]   e.g. `sh ab-inversion-cost.sh S A B` to smoke test
[ -n "$*" ] && ORDER="$*"

ABORT_J=95000
ABORT_SH=42000
COOL_TO=45000
COOL_MAX=180

node_get() { cat $NODE 2>/dev/null | tr ' ' '\n' | grep "^$1:" | cut -d: -f2; }
now() { read a b < /proc/uptime; echo "${a%.*}${a#*.}"; }   # centiseconds

zone_by_name() {
  for z in /sys/class/thermal/thermal_zone*; do
    [ "$(cat $z/type 2>/dev/null)" = "$1" ] && { echo "$z/temp"; return 0; }
  done
  return 1
}
Z_J=$(zone_by_name cpu-1-1-1) || { echo "FATAL: junction zone not found"; exit 2; }
Z_S=$(zone_by_name shell_front) || { echo "FATAL: shell zone not found"; exit 2; }

ORIG0=$(node_get 0)
ORIG6=$(node_get 6)

UCLPID=""
PINPID=""
restore() {
  [ -n "$UCLPID" ] && kill -9 $UCLPID 2>/dev/null
  [ -n "$PINPID" ] && kill -9 $PINPID 2>/dev/null
  UCLPID=""; PINPID=""
  pkill -9 -f "$MARK" 2>/dev/null
  pkill -9 -u $APPUID gzip 2>/dev/null
  W=""
  for c in 0 1 2 3 4 5; do W="$W $c:$ORIG0"; done
  for c in 6 7; do W="$W $c:$ORIG6"; done
  echo $W > $NODE 2>/dev/null
  svc power stayon false 2>/dev/null
}
trap 'echo "[trap] restoring"; restore; exit 130' INT TERM

# Arm S re-asserts URCC's OWN stock values rather than skipping the loop entirely.
# Writing back the value URCC already holds is a no-op in effect, but it keeps the
# process structure identical across arms and guards against URCC drifting mid-run.
WANT_MID=$TARGET_MID
WANT_PRIME=$TARGET_PRIME
pin() {
  W=""
  for c in 0 1 2 3 4 5; do W="$W $c:$WANT_MID"; done
  for c in 6 7; do W="$W $c:$WANT_PRIME"; done
  echo $W > $NODE 2>/dev/null
}

read_psr() { sed 's/^.*) //' /proc/$1/stat 2>/dev/null | awk '{print $37}'; }
read_ucl() { awk '/^uclamp\.max /{print $NF; exit}' /proc/$1/sched 2>/dev/null; }

mkdir -p $OUT
rm -f $OUT/*.csv $OUT/summary.txt 2>/dev/null

# Keep the instrument off the cluster it is measuring.
#
# cpu6 and cpu7 share one cpufreq policy, so ANY unclamped task on either core sets
# the clock for both. This sampler spawns ~15 short-lived root processes per 250 ms
# tick; left unpinned, EAS puts that burst on the prime cores and holds policy6 at
# its ceiling no matter what the workload asks for. The first 8-run attempt showed
# exactly that: two control runs stayed at 3283200 while clamped to 466, which a
# task demanding 466/1024 * 4320000 = 1966 MHz cannot do on its own.
#
# Arm B additionally carries a uclampset loop, so the contamination was not even
# symmetric between arms. Pin the harness to the mid cluster and give the workload
# back its full mask explicitly.
taskset -p 3f $$ >/dev/null 2>&1
echo "harness affinity: $(taskset -p $$ 2>/dev/null)"

echo "=== ab-real-workload $(date) ==="
echo "input:  $BIG  $(wc -c < $BIG) bytes  md5=$(md5sum $BIG | cut -d' ' -f1)"
echo "uid:    $APPUID"
echo "pin:    mid=$TARGET_MID prime=$TARGET_PRIME  (both arms)"
echo "order:  $ORDER"
echo "orig node: mid=$ORIG0 prime=$ORIG6"
echo "cfb enable=$(cat /sys/module/cpufreq_bouncing/parameters/enable 2>/dev/null)"
echo "junction zone=$Z_J shell zone=$Z_S"
svc power stayon usb 2>/dev/null

cooldown() {
  n=0
  while [ $n -lt $COOL_MAX ]; do
    j=$(cat $Z_J)
    [ "$j" -lt "$COOL_TO" ] && break
    n=$((n+5)); sleep 5
  done
  echo "  cooled to $(cat $Z_J) after ${n}s"
}

RUN=0
for ARM in $ORDER; do
  RUN=$((RUN+1))
  CSV=$OUT/run${RUN}_${ARM}.csv
  echo
  echo "===== RUN $RUN  ARM $ARM ====="

  if [ "$ARM" = "S" ]; then
    WANT_MID=$ORIG0; WANT_PRIME=$ORIG6
  else
    WANT_MID=$TARGET_MID; WANT_PRIME=$TARGET_PRIME
  fi

  echo "  cooldown..."
  cooldown

  pin
  sleep 1
  PN6=$(node_get 6); PP6=$(cat $P6/scaling_max_freq); PP0=$(cat $P0/scaling_max_freq)
  echo "  ceiling: node6=$PN6 p6max=$PP6 p0max=$PP0 (want mid=$WANT_MID prime=$WANT_PRIME)"
  if [ "$PP6" != "$WANT_PRIME" ] || [ "$PP0" != "$WANT_MID" ]; then
    echo "  !! CEILING NOT AS INTENDED - run marked INVALID"
    echo "RUN|$RUN|$ARM|INVALID|ceiling_wrong|p0max=$PP0|p6max=$PP6" >> $OUT/summary.txt
    continue
  fi

  TOLB=$(wc -l < $TOL 2>/dev/null || echo 0)

  # taskset ff undoes the harness's own 3f mask for the workload only, so the
  # workload is free to use all 8 cores while the instrument stays on mid.
  su $APPUID -c "taskset ff sh -c 'gzip -9 -c $BIG > /dev/null # $MARK'" &
  T0=$(now)

  PID=""; n=0
  while [ $n -lt 40 ]; do
    PID=$(pgrep -u $APPUID -x gzip 2>/dev/null | head -1)
    [ -n "$PID" ] && break
    n=$((n+1)); sleep 0.25
  done
  if [ -z "$PID" ]; then
    echo "  !! workload did not start - INVALID"
    echo "RUN|$RUN|$ARM|INVALID|no_workload_pid" >> $OUT/summary.txt
    restore; pin; continue
  fi
  # Restart the clock at pid discovery. T0 includes `su` process setup, which is
  # jitter of order a second on a ~40 s run and is not part of the workload.
  TP=$(now)
  WAFF=$(taskset -p $PID 2>/dev/null | sed 's/.*: *//')
  echo "  gzip pid=$PID  affinity=$WAFF  (spawn overhead $(( (TP-T0)*10 ))ms, excluded)"
  if [ "$WAFF" != "ff" ]; then
    echo "  !! workload affinity is '$WAFF', not ff - it cannot reach prime. INVALID"
    echo "RUN|$RUN|$ARM|INVALID|bad_workload_affinity=$WAFF" >> $OUT/summary.txt
    pkill -9 -f "$MARK" 2>/dev/null; pkill -9 -u $APPUID gzip 2>/dev/null
    continue
  fi

  # URCC reclaims this node ~28 s into a loaded run -- it holds indefinitely while
  # idle but not under load, which silently cost arm A 8 s at the inverted ceiling
  # in the first smoke pair. Re-assert for the duration, in BOTH arms equally.
  ( while kill -0 $PID 2>/dev/null; do
      pin
      sleep 0.5
    done ) &
  PINPID=$!

  if [ "$ARM" = "B" ]; then
    ( while kill -0 $PID 2>/dev/null; do
        uclampset -a -M 1024 -p $PID 2>/dev/null
        sleep 0.25
      done ) &
    UCLPID=$!
    echo "  arm B: uclampset loop pid=$UCLPID"
  fi

  echo "t_ms,uclamp_max,psr,p0max,p6max,node6,cur_freq,j,shell" > $CSV
  ABORTED=no
  while kill -0 $PID 2>/dev/null; do
    J=$(cat $Z_J); SH=$(cat $Z_S)
    if [ "$J" -gt "$ABORT_J" ] || [ "$SH" -gt "$ABORT_SH" ]; then
      echo "  !! THERMAL ABORT j=$J shell=$SH"
      ABORTED=yes
      break
    fi
    PSR=$(read_psr $PID)
    case "$PSR" in ''|*[!0-7]*) PSR=-1 ;; esac
    if [ "$PSR" -ge 0 ] 2>/dev/null; then
      CF=$(cat /sys/devices/system/cpu/cpu$PSR/cpufreq/scaling_cur_freq 2>/dev/null)
    else
      CF=0
    fi
    U=$(read_ucl $PID); [ -z "$U" ] && U=NA
    echo "$(( ($(now)-TP)*10 )),$U,$PSR,$(cat $P0/scaling_max_freq),$(cat $P6/scaling_max_freq),$(node_get 6),$CF,$J,$SH" >> $CSV
    sleep 0.25
  done
  EL=$(( ($(now)-TP)*10 ))

  [ -n "$UCLPID" ] && kill -9 $UCLPID 2>/dev/null
  [ -n "$PINPID" ] && kill -9 $PINPID 2>/dev/null
  UCLPID=""; PINPID=""
  pkill -9 -f "$MARK" 2>/dev/null
  pkill -9 -u $APPUID gzip 2>/dev/null

  TOLA=$(wc -l < $TOL 2>/dev/null || echo 0)
  NEWROWS=$((TOLA - TOLB))

  STATS=$(awk -F, -v tp="$WANT_PRIME" -v tm="$WANT_MID" 'NR>1 {
      n++;
      if ($3==6 || $3==7) prime++;
      if ($2=="NA") next_u=1; else {
        if ($2+0 != 1024) clamped++;
        if (minu=="" || $2+0 < minu+0) minu=$2;
      }
      fsum+=$7; if ($8>jmax) jmax=$8;
      if ($5+0 != tp+0 || $4+0 != tm+0) ceilbad++;
    }
    END {
      if (n==0) { print "0|0|0|0|0|0|0"; exit }
      printf "%d|%.1f|%.1f|%s|%.0f|%d|%d", n, prime*100/n, clamped*100/n, (minu==""?"NA":minu), fsum/n, jmax, ceilbad
    }' $CSV)

  echo "  elapsed_ms=$EL aborted=$ABORTED new_abnormal_task_rows=$NEWROWS"
  echo "  samples|prime%|clamped%|min_uclamp|mean_freq|jmax|ceiling_violations = $STATS"
  echo "RUN|$RUN|$ARM|$([ "$ABORTED" = "yes" ] && echo ABORTED || echo OK)|elapsed_ms=$EL|$STATS|newrows=$NEWROWS" >> $OUT/summary.txt
done

restore

echo
echo "===== SUMMARY ====="
cat $OUT/summary.txt
echo
echo "----- per-arm aggregate (valid, non-aborted runs only) -----"
awk -F'|' '$4=="OK" {
    split($5,e,"="); ms=e[2];
    arm=$3;
    n[arm]++; tot[arm]+=ms;
    if (best[arm]=="" || ms<best[arm]) best[arm]=ms;
    if (worst[arm]=="" || ms>worst[arm]) worst[arm]=ms;
  }
  END {
    for (a in n) printf "ARM %s: n=%d mean_ms=%.0f best_ms=%d worst_ms=%d\n", a, n[a], tot[a]/n[a], best[a], worst[a];
    meanS=(n["S"]>0)?tot["S"]/n["S"]:0;
    meanA=(n["A"]>0)?tot["A"]/n["A"]:0;
    meanB=(n["B"]>0)?tot["B"]/n["B"]:0;
    print "";
    if (meanS>0 && meanA>0) printf "S->A  removing the URCC inversion : %.1f%% faster\n", (meanS-meanA)*100/meanS;
    if (meanA>0 && meanB>0) printf "A->B  lifting the uclamp guard    : %.1f%% faster\n", (meanA-meanB)*100/meanA;
    if (meanS>0 && meanB>0) printf "S->B  both together              : %.1f%% faster\n", (meanS-meanB)*100/meanS;
  }' $OUT/summary.txt

echo
echo "restored node: $(cat $NODE)"
echo "AB_DONE"
