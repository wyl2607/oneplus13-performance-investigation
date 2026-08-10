#!/system/bin/sh
# OnePlus 13 (CPH2653) cpufreq_bouncing tune — Magisk service.d boot script.
#
# Raises the sustained ceiling above CFB's stock 2438400 (prime) / 2400000 (mid) clamp.
# Measured on the reference unit: single-thread junction 73 C, all-core plateau 89 C,
# shell 34-35 C, Thermal Status 0, Qualcomm LMH loop still active as the backstop.
#
# READ tune/README.md BEFORE INSTALLING. This permanently disables a vendor limiter.
#
# Install : cp oneplus13_cfb_tune.sh /data/adb/service.d/ && chmod 755 /data/adb/service.d/oneplus13_cfb_tune.sh
# Pause   : touch /data/adb/cfb_tune.off      (takes effect within 20 s, and on next boot)
# Remove  : rm /data/adb/service.d/oneplus13_cfb_tune.sh

E=/sys/module/cpufreq_bouncing/parameters/enable
P0=/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
P6=/sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq
A0=/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
A6=/sys/devices/system/cpu/cpufreq/policy6/scaling_available_frequencies
LOG=/data/adb/cfb_tune.log

# Must be valid OPPs for this device. Do not invent values.
CEIL0=2918400
CEIL6=3283200

[ -f /data/adb/cfb_tune.off ] && exit 0

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
  sleep 40

  [ -f "$E" ] && [ -f "$P6" ] && [ -f "$P0" ] || {
      echo "$(date) nodes missing - wrong kernel? aborting" >> $LOG; exit 0; }

  grep -qw "$CEIL6" $A6 || { echo "$(date) CEIL6 $CEIL6 not in OPP table, aborting" >> $LOG; exit 0; }
  grep -qw "$CEIL0" $A0 || { echo "$(date) CEIL0 $CEIL0 not in OPP table, aborting" >> $LOG; exit 0; }

  echo "$(date) start cfb=$(cat $E) p0=$(cat $P0) p6=$(cat $P6)" > $LOG

  # CFB is re-enabled by the system on every screen-on/wake event, so this must be a
  # watchdog rather than a one-shot. The ceilings are idempotent: when the screen is off,
  # URCC holds a lower freq_qos request and min() keeps screen-off power saving intact.
  while true; do
    if [ -f /data/adb/cfb_tune.off ]; then
      echo 1 > $E
      echo "$(date) kill-switch present, restored and exiting" >> $LOG
      exit 0
    fi
    [ "$(cat $E)" = "0" ] || echo 0 > $E
    echo $CEIL0 > $P0
    echo $CEIL6 > $P6
    sleep 20
  done
) &
