#!/system/bin/sh
# probe-selftest.sh
#
# Builds the large deterministic input, then PROVES the sampler can observe a
# uclamp clamp on the real workload process before that sampler is ever used to
# take data.
#
# This exists because the previous round's workload_clamp_probe.sh reported "no
# effect" while monitoring an idle parent shell. A null result from an unvalidated
# probe is worthless. The rule: set a known clamp with uclampset, confirm the probe
# reads it back, remove it, confirm the probe sees it go.
#
# Writes no cpufreq/kernel tunable. It does call uclampset on its own child, which
# is the same first-party tool section 26 used, and only on a process it spawned.

DIR=/data/local/tmp/gzab
SRC=$DIR/gzsrc.dat
BIG=$DIR/big.dat
REPEAT=28
APPUID=10999
MARK=gzabprobe

fail() { echo "SELFTEST=FAIL  $1"; cleanup; exit 1; }
cleanup() {
  pkill -9 -f "$MARK" 2>/dev/null
  pkill -9 -u $APPUID gzip 2>/dev/null
}
trap 'echo "[trap]"; cleanup; exit 130' INT TERM

echo "=== probe-selftest $(date) ==="

# ---------------------------------------------------------------- build input
if [ -f "$BIG" ] && [ "$(wc -c < $BIG)" -gt 900000000 ]; then
  echo "big input already present: $(wc -c < $BIG) bytes"
else
  echo "building ${REPEAT}x concatenated input..."
  : > $BIG
  n=0
  while [ $n -lt $REPEAT ]; do cat $SRC >> $BIG; n=$((n+1)); done
  chmod 644 $BIG
  echo "built: $(wc -c < $BIG) bytes"
fi
echo "sum: $(md5sum $BIG | cut -d' ' -f1)"

# --------------------------------------------------------- start the workload
echo
echo "--- starting workload under app uid $APPUID ---"
su $APPUID -c "sh -c 'gzip -9 -c $BIG > /dev/null # $MARK'" &
WRAP=$!
sleep 2

PID=""
n=0
while [ $n -lt 20 ]; do
  PID=$(pgrep -u $APPUID -x gzip 2>/dev/null | head -1)
  [ -n "$PID" ] && break
  n=$((n+1)); sleep 0.5
done
[ -z "$PID" ] && fail "could not find a gzip process under uid $APPUID"
echo "gzip pid=$PID  uid=$(awk '/^Uid:/{print $2}' /proc/$PID/status)"
[ "$(awk '/^Uid:/{print $2}' /proc/$PID/status)" = "$APPUID" ] || fail "gzip is not running as $APPUID"

# ------------------------------------------------- validate the field parsing
echo
echo "--- raw /proc/$PID/stat ---"
cat /proc/$PID/stat
echo "--- uclamp lines in /proc/$PID/sched ---"
grep -i uclamp /proc/$PID/sched

# processor is field 39 of /proc/pid/stat; after stripping "pid (comm) " the
# remainder starts at field 3, so the index is 39-2 = 37.
read_psr() { sed 's/^.*) //' /proc/$1/stat 2>/dev/null | awk '{print $37}'; }
read_ucl() { awk '/^uclamp\.max /{print $NF; exit}' /proc/$1/sched 2>/dev/null; }
read_eff() { awk '/^effective uclamp\.max /{print $NF; exit}' /proc/$1/sched 2>/dev/null; }

PSR=$(read_psr $PID)
echo
echo "parsed processor=$PSR"
case "$PSR" in
  0|1|2|3|4|5|6|7) echo "  processor parse OK" ;;
  *) fail "processor parsed as '$PSR', not a valid cpu id -- stat field index is wrong" ;;
esac

U0=$(read_ucl $PID)
E0=$(read_eff $PID)
echo "parsed uclamp.max=$U0  effective=$E0"
[ -z "$U0" ] && fail "could not parse uclamp.max"

# ------------------------------------------------------- THE POSITIVE CONTROL
echo
echo "=== POSITIVE CONTROL ==="
echo "setting a known clamp of 300 with uclampset..."
uclampset -a -M 300 -p $PID 2>&1
sleep 1
U1=$(read_ucl $PID); E1=$(read_eff $PID)
echo "probe reads uclamp.max=$U1 effective=$E1  (expected 300)"
[ "$U1" = "300" ] || fail "probe did NOT see the known clamp of 300 (read '$U1'). No null result from this probe would be admissible."

echo "removing the clamp (back to 1024)..."
uclampset -a -M 1024 -p $PID 2>&1
sleep 1
U2=$(read_ucl $PID); E2=$(read_eff $PID)
echo "probe reads uclamp.max=$U2 effective=$E2  (expected 1024)"
[ "$U2" = "1024" ] || fail "probe did not see the clamp removed (read '$U2')"

echo "POSITIVE_CONTROL=PASS  the probe observes both the application and the removal of a clamp."

# ---------------------------------- does the module clamp this workload at all?
echo
echo "=== does oplus_bsp_task_overload clamp this workload on its own? ==="
echo "watching for up to 60 s, sampling at 500 ms"
T0=$(cut -d' ' -f1 /proc/uptime | tr -d '.')
NAT=none
n=0
while [ $n -lt 120 ]; do
  kill -0 $PID 2>/dev/null || { echo "  workload exited at sample $n"; break; }
  U=$(read_ucl $PID)
  if [ -n "$U" ] && [ "$U" != "1024" ]; then
    EL=$(( ($(cut -d' ' -f1 /proc/uptime | tr -d '.') - T0) * 10 ))
    NAT="$U at ${EL}ms, psr=$(read_psr $PID)"
    echo "  CLAMPED: uclamp.max=$U after ${EL}ms  psr=$(read_psr $PID)"
    echo "  abnormal_task tail: $(tail -1 /proc/task_overload/abnormal_task 2>/dev/null | sed 's/[0-9]\{5\}/UID/2')"
    break
  fi
  [ $((n % 20)) -eq 0 ] && echo "  t=$((n/2))s uclamp.max=$U psr=$(read_psr $PID) p6max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)"
  n=$((n+1)); sleep 0.5
done
echo "natural clamp: $NAT"

cleanup
echo
echo "SELFTEST=PASS"
echo "SELFTEST_DONE"
