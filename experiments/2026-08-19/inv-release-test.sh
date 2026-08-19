#!/system/bin/sh
# The prime cap is latched at 1689600 across a fake unplug and across removing the
# runaway load. What, short of a reboot, releases it? Escalating, all reversible.
NODE=/sys/kernel/msm_performance/parameters/cpu_max_freq

samp() { n=0
  while [ $n -lt $2 ]; do
    printf '%s t=%3ss p6=%s p0=%s node=%s\n' "$1" "$n" \
      "$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)" \
      "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq)" \
      "$(cat $NODE | tr -s ' ' | cut -c1-80)"
    n=$((n+3)); sleep 3
  done; }

echo "### display state"
dumpsys power 2>/dev/null | grep -m4 -E 'mWakefulness|Display Power|mScreenOn'
echo "### urcc service state"
getprop init.svc.vendor.urcc-hal-aidl

echo "### PHASE A wake the screen + inject input (documented ramp trigger)"
input keyevent KEYCODE_WAKEUP; sleep 1; input swipe 500 1500 500 900 200
samp WAKE 30

echo "### PHASE B restart the URCC HAL"
setprop ctl.restart vendor.urcc-hal-aidl
sleep 2; getprop init.svc.vendor.urcc-hal-aidl
samp RESTART 45

echo "### PHASE C wake + input again, with a freshly restarted HAL"
input keyevent KEYCODE_WAKEUP; sleep 1; input swipe 500 1500 500 900 200
samp WAKE2 30

echo "### final"
getprop init.svc.vendor.urcc-hal-aidl
cat $NODE
echo "### DONE"
