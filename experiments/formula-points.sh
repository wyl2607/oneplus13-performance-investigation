#!/system/bin/sh
# formula-points.sh
#
# Test  limit_flag = floor(0.6 * 1024 * prime_cur_freq / 4320000)  at frequencies
# WE choose rather than the four CFB happened to hand us.
#
# Section 25 graded the formula HIGHLY LIKELY on four points spanning limit_flag
# 346-466 -- a narrow band, and not independently chosen. Pinning msm_performance's
# node (section 30) makes the prime clock settable, so the model can be tested by
# extrapolation instead of interpolation. Predicted values here span 172-581.
#
# Method: pin prime to F, run an app-uid spin loop pinned to the prime pair (root
# and system are exempt, and the guard only fires on prime -- section 27), wait for
# the clamp, read the value back.
#
# Kernel writes: cpu_max_freq only, restored on every exit path. Aborts at 90 C.

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
P6=/sys/devices/system/cpu/cpufreq/policy6
P0=/sys/devices/system/cpu/cpufreq/policy0
TOL=/proc/task_overload/abnormal_task
APPUID=10999
MARK=fpprobe
MID=2918400
ABORT_J=90000
MAXWAIT=120

POINTS="1209600 1689600 2246400 2841600"
# Points above 3283200 are unreachable: the user's installed tune watchdog
# (/data/adb/service.d/oneplus13_cfb_tune.sh) holds scaling_max_freq there, and
# cpufreq takes min() across requesters. Raising it means editing an installed
# system script, which is the owner's call, so those points are simply not taken.
[ -n "$*" ] && POINTS="$*"

node_get() { cat $NODE 2>/dev/null | tr ' ' '\n' | grep "^$1:" | cut -d: -f2; }
read_ucl() { awk '/^uclamp\.max /{print $NF; exit}' /proc/$1/sched 2>/dev/null; }
now() { read a b < /proc/uptime; echo "${a%.*}${a#*.}"; }

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
  pkill -9 -f "$MARK" 2>/dev/null
  W=""; for c in 0 1 2 3 4 5; do W="$W $c:$ORIG0"; done; for c in 6 7; do W="$W $c:$ORIG6"; done
  echo $W > $NODE 2>/dev/null
  svc power stayon false 2>/dev/null
}
trap 'cleanup; exit 130' INT TERM

CUR_F=""
pin() {
  W=""; for c in 0 1 2 3 4 5; do W="$W $c:$MID"; done
  for c in 6 7; do W="$W $c:$CUR_F"; done
  echo $W > $NODE 2>/dev/null
}

# Instrument stays off the cluster under measurement (METHODOLOGY trap 6).
taskset -p 3f $$ >/dev/null 2>&1
svc power stayon usb 2>/dev/null

echo "=== formula-points $(date) ==="
echo "harness affinity: $(taskset -p $$ 2>/dev/null | sed 's/.*: *//')"
echo "orig node: mid=$ORIG0 prime=$ORIG6"
echo
printf '%-10s %-10s %-9s %-9s %-8s %s\n' TARGET_F CLAMP_F OBSERVED PREDICTED DELTA SECONDS
RESULTS=""

for F in $POINTS; do
  CUR_F=$F

  n=0; while [ $n -lt 90 ]; do j=$(cat $Z_J); [ "$j" -lt 45000 ] && break; n=$((n+5)); sleep 5; done

  pin; sleep 1
  GOT=$(cat $P6/scaling_max_freq)
  if [ "$GOT" != "$F" ]; then
    printf '%-10s %-10s %-9s %-9s %-8s %s\n' "$F" "-" "-" "-" "-" "PIN_FAILED(p6max=$GOT)"
    continue
  fi

  # Distinct comm per trial. The first run showed a success/timeout/success/timeout
  # pattern in which every failure directly followed a success, consistent with the
  # guard de-duplicating on (uid, comm) -- every probe was called `sh`. Give each
  # trial its own binary name so that cannot be the reason a point is missing.
  BIN=/data/local/tmp/gzab/spin_$F
  cp /system/bin/sh $BIN 2>/dev/null
  chmod 755 $BIN 2>/dev/null
  su $APPUID -c "taskset c0 $BIN -c 'i=0; while : ; do i=\$((i+1)); done # $MARK'" &
  sleep 1

  # Pick the candidate actually burning CPU -- `su` shares the marker in its own
  # cmdline and drops to the app uid, so a naive head -1 monitors the idle parent
  # (METHODOLOGY trap 7).
  PID=""; BESTD=0
  CANDS=$(pgrep -u $APPUID -f "$MARK" 2>/dev/null)
  for c in $CANDS; do
    echo "$(sed 's/^.*) //' /proc/$c/stat 2>/dev/null | awk '{print $12+$13}')" > /data/local/tmp/.fp_$c
  done
  sleep 1
  for c in $CANDS; do
    a=$(cat /data/local/tmp/.fp_$c 2>/dev/null)
    b=$(sed 's/^.*) //' /proc/$c/stat 2>/dev/null | awk '{print $12+$13}')
    rm -f /data/local/tmp/.fp_$c
    [ -z "$a" ] || [ -z "$b" ] && continue
    d=$((b - a))
    if [ "$d" -gt "$BESTD" ]; then BESTD=$d; PID=$c; fi
  done
  if [ -z "$PID" ] || [ "$BESTD" -lt 20 ]; then
    printf '%-10s %-10s %-9s %-9s %-8s %s\n' "$F" "-" "-" "-" "-" "NO_BUSY_TARGET(best=$BESTD)"
    pkill -9 -f "$MARK" 2>/dev/null
    continue
  fi

  ( while kill -0 $PID 2>/dev/null; do pin; sleep 0.5; done ) &
  PINPID=$!

  T0=$(now); U=1024; CLAMPF=""; RES=TIMEOUT
  while : ; do
    EL=$(( ($(now) - T0) * 10 ))
    U=$(read_ucl $PID)
    if [ -n "$U" ] && [ "$U" != "1024" ]; then
      CLAMPF=$(cat $P6/scaling_cur_freq)
      RES=CLAMPED
      break
    fi
    j=$(cat $Z_J)
    [ "$j" -gt "$ABORT_J" ] && { RES="THERMAL_ABORT_$j"; break; }
    [ "$EL" -ge $((MAXWAIT * 1000)) ] && break
    sleep 0.1
  done
  SECS=$(( EL / 1000 )).$(( (EL % 1000) / 100 ))

  [ -n "$PINPID" ] && kill -9 $PINPID 2>/dev/null; PINPID=""
  pkill -9 -f "$MARK" 2>/dev/null
  rm -f $BIN 2>/dev/null
  sleep 20

  if [ "$RES" = "CLAMPED" ]; then
    PRED=$(awk -v f="$F" 'BEGIN{printf "%d", int(0.6*1024*f/4320000)}')
    D=$((U - PRED))
    printf '%-10s %-10s %-9s %-9s %-8s %s\n' "$F" "$CLAMPF" "$U" "$PRED" "$D" "$SECS"
    RESULTS="$RESULTS
$F,$CLAMPF,$U,$PRED,$D"
    echo "    abnormal_task: $(tail -1 $TOL 2>/dev/null | awk '{$2="10xxx"; print}')"
  else
    printf '%-10s %-10s %-9s %-9s %-8s %s\n' "$F" "-" "-" "-" "-" "$RES after ${SECS}s"
  fi
done

cleanup

echo
echo "=== fit ==="
echo "$RESULTS" | awk -F, 'NF==5 {
    n++; sx+=$1; sy+=$3; sxy+=$1*$3; sxx+=$1*$1;
    if ($5>mx || mx=="") mx=$5; if ($5<mn || mn=="") mn=$5;
    ad+=($5<0?-$5:$5);
  }
  END {
    if (n<2) { print "not enough points"; exit }
    slope=(n*sxy - sx*sy)/(n*sxx - sx*sx);
    icept=(sy - slope*sx)/n;
    printf "points=%d\n", n;
    printf "observed slope   = %.9f  (model 0.6*1024/4320000 = %.9f)\n", slope, 0.6*1024/4320000;
    printf "observed intercept = %.2f  (model 0)\n", icept;
    printf "residual vs floor(model): min=%d max=%d mean_abs=%.2f\n", mn, mx, ad/n;
  }'
echo "restored node: $(cat $NODE)"
echo "FORMULA_DONE"
