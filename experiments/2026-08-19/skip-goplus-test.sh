#!/system/bin/sh
# Does /proc/task_overload/skip_goplus_enabled turn the uclamp guard off?
# If yes it replaces the 250 ms uclampset loop with one write.
#
# Positive control FIRST: prove a spinner gets clamped at the current setting,
# then flip the node and repeat with a DIFFERENT process name (the guard
# de-duplicates on (uid, comm), so reusing a name silently under-reports).
#
# Teardown kills by uid, not by name -- the `# marker` trick is stripped as a
# shell comment before exec and has silently leaked loops before.
TOL=/proc/task_overload/abnormal_task
NODE=/proc/task_overload/skip_goplus_enabled
UID_T=10999
J_ABORT=90000
TMP=/data/local/tmp/sg

Z_J=NA
for z in /sys/class/thermal/thermal_zone*; do
  read t < "$z/type" 2>/dev/null || continue
  [ "$t" = "cpu-1-1-1" ] && Z_J="$z/temp"
done
jt() { [ "$Z_J" = NA ] && echo 0 || cat "$Z_J"; }

teardown() {
  for p in $(ps -A -o PID,USER 2>/dev/null | awk -v u=u0_a999 '$2==u {print $1}'); do
    kill -9 "$p" 2>/dev/null
  done
  pkill -9 -u $UID_T 2>/dev/null
  sleep 1
}
trap 'teardown; rm -rf $TMP' EXIT INT TERM

rm -rf $TMP; mkdir -p $TMP; chmod 777 $TMP
cp /system/bin/sh $TMP/spinAAA; cp /system/bin/sh $TMP/spinBBB
chmod 755 $TMP/spinAAA $TMP/spinBBB

# one spinner, pinned to the prime cluster (cpu6,7) where the guard fires
trial() {  # trial <binary> <label>
  BEFORE=$(wc -l < $TOL)
  J0=$(jt)
  su $UID_T -c "taskset c0 $1 -c 'while :; do :; done'" &
  W=$!
  sleep 2
  TID=$(ps -A -T -o PID,TID,USER,NAME 2>/dev/null | awk -v n="$(basename $1)" '$4==n {print $2; exit}')
  echo "$2: spinner tid=${TID:-NONE}"
  n=0; RES=NOT_CLAMPED; UCF=1024
  while [ $n -lt 40 ]; do
    J=$(jt)
    if [ "$J" -gt $J_ABORT ] 2>/dev/null; then echo "$2: THERMAL ABORT at $J"; RES=ABORT; break; fi
    AFTER=$(wc -l < $TOL)
    if [ "$AFTER" -gt "$BEFORE" ]; then RES=CLAMPED; break; fi
    n=$((n+1)); sleep 1
  done
  # what CPU did it actually run on, and is it actually burning CPU?
  if [ -n "$TID" ]; then
    CPU=$(awk '{print $39}' /proc/$TID/stat 2>/dev/null)
    TICKS=$(awk '{print $14+$15}' /proc/$TID/stat 2>/dev/null)
    echo "$2: last_cpu=$CPU cpu_ticks=$TICKS (must be >0 or the probe never ran)"
  fi
  echo "$2: result=$RES after ${n}s  junction ${J0}->$(jt)"
  echo "$2: new rows:"; tail -n +$((BEFORE)) $TOL | tail -3
  teardown
  sleep 3
}

echo "### node reads: $(cat $NODE)"
echo "### prime ceiling: $(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)"
echo
echo "=== TRIAL 1 : positive control, node as shipped ==="
trial $TMP/spinAAA CTRL

echo
echo "=== flip the node ==="
echo 1 > $NODE 2>&1; echo "write '1' -> reads: $(cat $NODE)"
echo "skip_goplus_enabled=1" > $NODE 2>&1; echo "write 'skip_goplus_enabled=1' -> reads: $(cat $NODE)"
echo
echo "=== TRIAL 2 : same load, different comm, node flipped ==="
trial $TMP/spinBBB TEST

echo
echo "=== restore ==="
echo 0 > $NODE 2>&1; echo "skip_goplus_enabled=0" > $NODE 2>&1
echo "node now: $(cat $NODE)"
echo "=== leak check: anything under the test uid still burning CPU? ==="
ps -A -o PID,USER,NAME 2>/dev/null | grep -E 'spinAAA|spinBBB|u0_a999' | grep -v grep || echo "clean"
echo "### DONE"
