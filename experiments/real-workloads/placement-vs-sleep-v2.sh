#!/system/bin/sh
# placement-vs-sleep-v2.sh
#
# Section 32 showed a spinning task keeps the prime cluster after being clamped
# while a duty-cycle task is displaced to mid. It carried a stated confound: the
# two variants ran at 106 and 80 cpu-ticks/s, so they were not matched on
# utilisation, and a task at ~78% duty could fit the mid cluster's effective
# capacity on utilisation alone.
#
# That confound cannot be removed by matching a sleeping task to a 100% spinner --
# a task that sleeps is not 100% by definition. The fix is a different comparison:
#
#   duty_slow   ~90% duty,  ~5 wakeups/s
#   duty_fast   ~90% duty, ~50 wakeups/s
#
# These two are matched on UTILISATION and differ ~10x in WAKEUP RATE. If wakeups
# drive displacement, duty_fast is displaced and duty_slow much less so, at equal
# load. `spin` is kept as the 100%/zero-wakeup reference.
#
# Improvements over v1:
#   * fork-free sleeping (`read -t` on a fifo), so variants match on fork rate too
#   * wakeups measured directly from voluntary_ctxt_switches, not assumed
#   * duty measured and reported, so "matched" is a checked claim not an intention
#   * distinct comm per variant, because the guard de-duplicates on (uid, comm)
#     (section 33) and a reused name silently produces a false null
#
# COOLING CONDITION: this run is taken with the 40 W OnePlus active cooler attached
# and running for its whole duration. That is an experimental condition, not a
# detail -- section 18 established that Android's thermal framework governs on skin
# temperature, so active cooling changes what the framework does as well as what the
# silicon does. Every temperature in the output is an actively-cooled temperature and
# is NOT comparable to the passively-cooled runs in sections 31-34.
#
# The operating point is deliberately NOT raised to exploit the cooler: it stays at
# 2649600/2400000, and the hard cooldown gate, 50 ms junction sub-sampling and all
# abort/restore paths remain in force. The cooler is here to keep the device far from
# the envelope, not to permit going nearer to it.
#
# Kernel writes: cpu_max_freq only, restored on every exit path.

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
P6=/sys/devices/system/cpu/cpufreq/policy6
P0=/sys/devices/system/cpu/cpufreq/policy0
DIR=/data/local/tmp/gzab
WORKER=$DIR/worker.sh
FIFO=$DIR/w.fifo
APPUID=10999
MARK=plsleep2
MID=2400000
PRIME=2649600
# Deliberately low. This experiment only needs prime to be a better core than mid,
# not a fast one: effective capacity is 1024*2649600/4320000 = 628 for prime against
# 792*2400000/3532800 = 538 for mid, so promotion is still correct, and the clamp
# value floor(614*2649600/4320000) = 376 still fits inside mid. The first attempt ran
# at 3283200 and a prime-pinned spin loop took the junction from 52 to 93 C in 26 s.
DUR=60
ABORT_J=88000
COOL_TO=42000
COOL_MAX=300

node_get() { cat $NODE 2>/dev/null | tr ' ' '\n' | grep "^$1:" | cut -d: -f2; }
read_psr() { sed 's/^.*) //' /proc/$1/stat 2>/dev/null | awk '{print $37}'; }
read_ucl() { awk '/^uclamp\.max /{print $NF; exit}' /proc/$1/sched 2>/dev/null; }
read_vcs() { awk '/^voluntary_ctxt_switches:/{print $2}' /proc/$1/status 2>/dev/null; }
read_cpu() { sed 's/^.*) //' /proc/$1/stat 2>/dev/null | awk '{print $12+$13}'; }
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
pin() {
  W=""; for c in 0 1 2 3 4 5; do W="$W $c:$MID"; done
  for c in 6 7; do W="$W $c:$PRIME"; done
  echo $W > $NODE 2>/dev/null
}

taskset -p 3f $$ >/dev/null 2>&1   # instrument off the measured cluster (trap 6)
svc power stayon usb 2>/dev/null

mkdir -p $DIR
chmod 755 $DIR
rm -f $FIFO; mkfifo $FIFO 2>/dev/null; chmod 666 $FIFO
# adb push runs as `shell` and $DIR is root-owned, so worker.sh is staged in
# /data/local/tmp and copied into place here, where we are root.
[ -f /data/local/tmp/worker.sh ] && cp /data/local/tmp/worker.sh $WORKER
chmod 755 $WORKER
[ -f "$WORKER" ] || { echo "FATAL: $WORKER missing"; cleanup; exit 5; }

COOLING="40W OnePlus active cooler, attached and running throughout"

echo "=== placement-vs-sleep-v2 $(date) ==="
echo "COOLING CONDITION: $COOLING"
echo "operating point:   mid=$MID prime=$PRIME (unchanged from the passive design)"
echo "harness affinity: $(taskset -p $$ 2>/dev/null | sed 's/.*: *//')"
echo "junction at start: $(cat $Z_J)  shell: $(cat $(zone_by_name shell_front))"

# --- does this shell support a fractional `read -t`? the whole design rests on it
echo
echo "--- capability check: fractional read -t ---"
T0=$(now); (exec 3<> $FIFO; read -t 0.05 x <&3); T1=$(now)
D=$(( (T1 - T0) * 10 ))
echo "read -t 0.05 took ${D}ms (expect ~50ms; a few ms means it did not block, ~0 means unsupported)"
if [ "$D" -lt 20 ] || [ "$D" -gt 250 ]; then
  echo "CAPABILITY=FAIL - fork-free sleeping is not behaving as required; results would not be interpretable."
  cleanup; exit 3
fi
echo "CAPABILITY=PASS"

# --- calibrate iterations per millisecond, at the pinned prime clock
pin; sleep 1
echo
echo "--- calibration ---"
echo "ceiling p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq)"
CALN=200000
T0=$(now); i=0; while [ $i -lt $CALN ]; do i=$((i+1)); done; T1=$(now)
CALMS=$(( (T1 - T0) * 10 ))
[ "$CALMS" -lt 1 ] && CALMS=1
IPMS=$(( CALN / CALMS ))
echo "$CALN iterations in ${CALMS}ms -> ~${IPMS} iterations/ms (on the mid cluster, harness is pinned there)"
[ "$IPMS" -lt 1 ] && { echo "calibration failed"; cleanup; exit 4; }

# 90% duty in both: busy:sleep = 9:1
N_SLOW=$(( IPMS * 180 ))   # ~180 ms busy, 20 ms sleep -> ~5 wakeups/s
S_SLOW=0.02
N_FAST=$(( IPMS * 18 ))    # ~18 ms busy,  2 ms sleep  -> ~50 wakeups/s
S_FAST=0.002
echo "duty_slow: $N_SLOW iters + ${S_SLOW}s sleep    duty_fast: $N_FAST iters + ${S_FAST}s sleep"

trial() {
  NAME="$1"; N="$2"; S="$3"
  echo
  echo "===== $NAME ====="
  # HARD gate. The first attempt used a best-effort cooldown that gave up after 90 s
  # and started a trial at 69 C; the junction then passed 104 C within a second, over
  # the 92 C abort and close to the 105 C trip. A cooldown that can be skipped is not
  # a safety limit.
  n=0
  while [ $n -lt $COOL_MAX ]; do
    j=$(cat $Z_J); [ "$j" -lt $COOL_TO ] && break
    n=$((n+5)); sleep 5
  done
  j=$(cat $Z_J)
  if [ "$j" -ge "$COOL_TO" ]; then
    echo "  !! did not cool below $COOL_TO within ${COOL_MAX}s (now $j) - ABORTING RUN"
    cleanup; exit 6
  fi
  echo "  cooled to $j after ${n}s  (shell $(cat $(zone_by_name shell_front)))"
  pin; sleep 1
  echo "  start j=$(cat $Z_J) p6max=$(cat $P6/scaling_max_freq)"

  BIN=$DIR/w_$NAME
  cp /system/bin/sh $BIN 2>/dev/null; chmod 755 $BIN

  # The marker must be a real argv entry. Written as `# $MARK` it is stripped as a
  # shell comment by su's own shell, so no process carries it, pgrep finds only the
  # idle su parent, and the trap-7 guard correctly refuses to take data.
  su $APPUID -c "taskset ff $BIN $WORKER $N $S $FIFO $MARK" &
  sleep 1

  # target must be the process actually burning CPU, not su's idle parent (trap 7)
  PID=""; BESTD=0
  CANDS=$(pgrep -u $APPUID -f "$MARK" 2>/dev/null)
  for c in $CANDS; do echo "$(read_cpu $c)" > $DIR/.t_$c; done
  sleep 1
  for c in $CANDS; do
    a=$(cat $DIR/.t_$c 2>/dev/null); b=$(read_cpu $c); rm -f $DIR/.t_$c
    [ -z "$a" ] || [ -z "$b" ] && continue
    d=$((b - a))
    if [ "$d" -gt "$BESTD" ]; then BESTD=$d; PID=$c; fi
  done
  if [ -z "$PID" ] || [ "$BESTD" -lt 10 ]; then
    echo "  !! no candidate burning CPU (best=$BESTD) - trial invalid"
    pkill -9 -f "$MARK" 2>/dev/null; return
  fi
  echo "  pid=$PID comm=$(cat /proc/$PID/comm) affinity=$(taskset -p $PID 2>/dev/null | sed 's/.*: *//')"

  ( while kill -0 $PID 2>/dev/null; do pin; sleep 0.5; done ) &
  PINPID=$!

  CSV=$DIR/pl2_$NAME.csv
  echo "t_ms,uclamp,psr,vcs,cpu,j" > $CSV
  T0=$(now); CLAMP_AT=""
  V0=$(read_vcs $PID); C0=$(read_cpu $PID)
  n=0
  while [ $n -lt $((DUR * 4)) ]; do
    kill -0 $PID 2>/dev/null || break
    U=$(read_ucl $PID); P=$(read_psr $PID)
    T=$(( ($(now) - T0) * 10 ))
    echo "$T,$U,$P,$(read_vcs $PID),$(read_cpu $PID),$(cat $Z_J)" >> $CSV
    [ -z "$CLAMP_AT" ] && [ -n "$U" ] && [ "$U" != "1024" ] && CLAMP_AT=$T
    j=$(cat $Z_J); [ "$j" -gt "$ABORT_J" ] && { echo "  !! thermal abort $j"; break; }
    # sub-sample the sensor between data points; the ramp is far faster than 250 ms
    k=0
    while [ $k -lt 5 ]; do
      sleep 0.05
      j=$(cat $Z_J)
      [ "$j" -gt "$ABORT_J" ] && { echo "  !! thermal abort $j"; break; }
      k=$((k+1))
    done
    [ "$j" -gt "$ABORT_J" ] && break
    n=$((n+1))
  done
  TEL=$(( ($(now) - T0) * 10 ))
  V1=$(read_vcs $PID); C1=$(read_cpu $PID)

  [ -n "$PINPID" ] && kill -9 $PINPID 2>/dev/null; PINPID=""
  pkill -9 -f "$MARK" 2>/dev/null
  rm -f $BIN

  if [ -n "$V0" ] && [ -n "$V1" ] && [ "$TEL" -gt 0 ]; then
    WPS=$(( (V1 - V0) * 1000 / TEL ))
    DUTY=$(( (C1 - C0) * 1000 / TEL ))   # ticks/s; 100 ticks/s == 100% of one CPU
    echo "  measured: wakeups/s=$WPS  duty=${DUTY}%  (over ${TEL}ms)"
  fi
  echo "  thermal envelope this trial: junction max $(awk -F, 'NR>1&&$6>m{m=$6}END{print m+0}' $CSV) (abort was $ABORT_J)"
  echo "  clamp landed at: ${CLAMP_AT:-never} ms"
  awk -F, -v ca="${CLAMP_AT:--1}" 'NR>1 {
      n++; if ($3==6||$3==7) pr++;
      if (ca>=0 && $1+0 >= ca+0) { na++; if ($3==6||$3==7) pra++ }
      if (ca>=0 && $1+0 <  ca+0) { nb++; if ($3==6||$3==7) prb++ }
    }
    END {
      printf "  samples=%d  prime_overall=%.1f%%\n", n, pr*100/n;
      if (nb>0) printf "  before clamp: n=%d prime=%.1f%%\n", nb, prb*100/nb;
      if (na>0) printf "  AFTER clamp:  n=%d prime=%.1f%%\n", na, pra*100/na;
    }' $CSV
}

trial spin 0 0
trial slow $N_SLOW $S_SLOW
trial fast $N_FAST $S_FAST

cleanup
rm -f $FIFO
echo
echo "Compare slow and fast: matched duty, ~10x different wakeup rate."
echo "PL2_DONE"
