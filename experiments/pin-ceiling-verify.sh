#!/system/bin/sh
# pin-ceiling-verify.sh
#
# Bounded test of ONE question: does writing msm_performance's own cpu_max_freq
# node raise the prime ceiling out of URCC's inverted state, and if so, does URCC
# re-assert -- spontaneously, and after user input?
#
# This DOES write a kernel parameter. It is non-persistent (reboot clears it), it
# updates the value of the request URCC already owns rather than adding a new
# requester, and the original value is restored on every exit path including trap.
#
# It runs no workload. Raising an idle cluster's ceiling costs nothing thermally;
# frequency is demand-driven and there is no demand here.

NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq
P0=/sys/devices/system/cpu/cpufreq/policy0
P6=/sys/devices/system/cpu/cpufreq/policy6

TARGET_MID=2918400
TARGET_PRIME=3283200

node_get() { cat $NODE 2>/dev/null | tr ' ' '\n' | grep "^$1:" | cut -d: -f2; }

ORIG=$(cat $NODE 2>/dev/null)
ORIG0=$(node_get 0)
ORIG6=$(node_get 6)

restore() {
  # Write back the exact per-cpu values that were there on entry.
  W=""
  for c in 0 1 2 3 4 5; do W="$W $c:$ORIG0"; done
  for c in 6 7; do W="$W $c:$ORIG6"; done
  echo $W > $NODE 2>/dev/null
  svc power stayon false 2>/dev/null
}
trap 'echo "[trap] restoring"; restore; exit 130' INT TERM

echo "=== pin-ceiling-verify $(date) ==="
echo "ORIGINAL node: $ORIG"
echo "ORIGINAL p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq)"
echo

echo "--- tool availability ---"
echo "uclampset: $(command -v uclampset || echo MISSING)"
echo "gzip:      $(command -v gzip || echo MISSING)"
echo "taskset:   $(command -v taskset || echo MISSING)"
echo "cfb enable=$(cat /sys/module/cpufreq_bouncing/parameters/enable 2>/dev/null)"
echo

svc power stayon usb 2>/dev/null
sleep 1

echo "--- WRITE: mid=$TARGET_MID prime=$TARGET_PRIME ---"
W=""
for c in 0 1 2 3 4 5; do W="$W $c:$TARGET_MID"; done
for c in 6 7; do W="$W $c:$TARGET_PRIME"; done
echo "writing:$W"
echo $W > $NODE
RC=$?
echo "write rc=$RC"
sleep 1
echo "readback node: $(cat $NODE)"
echo "readback p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq)"

N6=$(node_get 6)
P6MAX=$(cat $P6/scaling_max_freq)
if [ "$N6" != "$TARGET_PRIME" ]; then
  echo "RESULT=NODE_REJECTED   the node did not take the value."
  restore; exit 4
fi
if [ "$P6MAX" != "$TARGET_PRIME" ]; then
  echo "RESULT=NODE_TOOK_BUT_QOS_STILL_LOWER  node=$N6 but policy6 max=$P6MAX"
  echo "  -> another freq_qos requester is still holding below it."
else
  echo "RESULT=PIN_EFFECTIVE  prime ceiling raised $ORIG6 -> $P6MAX"
fi

echo
echo "--- HOLD TEST A: 60 s undisturbed, no input, screen on ---"
n=0
DRIFT_A=none
while [ $n -lt 60 ]; do
  cur6=$(node_get 6); pm6=$(cat $P6/scaling_max_freq)
  [ "$cur6" != "$TARGET_PRIME" ] && [ "$DRIFT_A" = "none" ] && DRIFT_A="t=${n}s node6->$cur6"
  [ $((n % 10)) -eq 0 ] && echo "  t=${n}s node6=$cur6 p6max=$pm6 node0=$(node_get 0) p0max=$(cat $P0/scaling_max_freq)"
  n=$((n+2)); sleep 2
done
echo "spontaneous drift: $DRIFT_A"

echo
echo "--- HOLD TEST B: after a user input event ---"
input keyevent 4 2>/dev/null   # BACK, the most harmless event that still triggers input boost
echo "sent keyevent BACK"
n=0
DRIFT_B=none
while [ $n -lt 40 ]; do
  cur6=$(node_get 6)
  [ "$cur6" != "$TARGET_PRIME" ] && [ "$DRIFT_B" = "none" ] && DRIFT_B="t=${n}s node6->$cur6"
  echo "  t=${n}s node6=$cur6 p6max=$(cat $P6/scaling_max_freq)"
  n=$((n+4)); sleep 4
done
echo "drift after input: $DRIFT_B"

echo
echo "--- RESTORE ---"
restore
sleep 1
echo "restored node: $(cat $NODE)"
echo "restored p0max=$(cat $P0/scaling_max_freq) p6max=$(cat $P6/scaling_max_freq)"
echo
echo "SUMMARY  pin_effective=$([ "$P6MAX" = "$TARGET_PRIME" ] && echo yes || echo no)  drift_idle=$DRIFT_A  drift_after_input=$DRIFT_B"
echo "VERIFY_DONE"
