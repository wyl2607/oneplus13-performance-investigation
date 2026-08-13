#!/system/bin/sh
# OnePlus 13 (CPH2653) cpufreq_bouncing tune — Magisk service.d boot script.
#
# Raises the sustained ceiling above CFB's stock 2438400 (prime) / 2400000 (mid) clamp.
# Measured on the reference unit: single-thread junction 73 C, all-core plateau 89 C,
# shell 34-35 C, Thermal Status 0, Qualcomm LMH loop still active as the backstop.
# Validated: Geekbench 7 single-core 950 -> 1253 (+32%), multi-core 5220 -> 5945 (+14%).
#
# READ tune/README.md BEFORE INSTALLING. This permanently disables a vendor limiter.
#
# Install : cp oneplus13_cfb_tune.sh /data/adb/service.d/ && chmod 755 /data/adb/service.d/oneplus13_cfb_tune.sh
# Pause   : touch /data/adb/cfb_tune.off      (takes effect within one poll, and on next boot)
# Resume  : rm /data/adb/cfb_tune.off         (then reboot, or re-run this script)
# Remove  : rm /data/adb/service.d/oneplus13_cfb_tune.sh

E=/sys/module/cpufreq_bouncing/parameters/enable
P0=/sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq
P6=/sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq
A0=/sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies
A6=/sys/devices/system/cpu/cpufreq/policy6/scaling_available_frequencies
LOG=/data/adb/cfb_tune.log
LOCK=/data/adb/cfb_tune.pid
POLL=20

# Must be valid OPPs for this device. The script refuses to run otherwise.
CEIL0=2918400
CEIL6=3283200

[ -f /data/adb/cfb_tune.off ] && exit 0

# Single instance. A stale pid file from an unclean shutdown is ignored.
if [ -f "$LOCK" ] && kill -0 "$(cat $LOCK 2>/dev/null)" 2>/dev/null; then
  exit 0
fi

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
  sleep 40

  [ -f "$E" ] && [ -f "$P6" ] && [ -f "$P0" ] || {
      echo "$(date) FATAL nodes missing - wrong kernel or module gone, exiting" >> $LOG
      rm -f $LOCK; exit 0; }

  grep -qw "$CEIL6" $A6 || {
      echo "$(date) FATAL CEIL6 $CEIL6 not in policy6 OPP table, exiting" >> $LOG
      rm -f $LOCK; exit 0; }
  grep -qw "$CEIL0" $A0 || {
      echo "$(date) FATAL CEIL0 $CEIL0 not in policy0 OPP table, exiting" >> $LOG
      rm -f $LOCK; exit 0; }

  # Keep the log bounded — this process runs for the entire uptime.
  [ "$(wc -c < $LOG 2>/dev/null || echo 0)" -gt 65536 ] && : > $LOG

  echo "$(date) start cfb=$(cat $E) p0=$(cat $P0) p6=$(cat $P6) poll=${POLL}s" >> $LOG

  REENABLES=0
  # CFB is re-enabled by the system on every screen-on/wake event (docs/DATA.md section 8),
  # so this must be a watchdog rather than a one-shot. The ceilings are written every pass
  # too: it is idempotent, and while the screen is off URCC holds a lower freq_qos request
  # that still wins via min(), so screen-off power saving is unaffected.
  while true; do
    if [ -f /data/adb/cfb_tune.off ]; then
      echo 1 > $E
      echo "$(date) kill-switch present, CFB restored, exiting after $REENABLES re-enables" >> $LOG
      rm -f $LOCK; exit 0
    fi

    if [ "$(cat $E)" != "0" ]; then
      echo 0 > $E
      REENABLES=$((REENABLES+1))
      # Log only occasionally; this fires on every wake and would otherwise flood.
      [ $((REENABLES % 50)) -eq 1 ] && echo "$(date) re-disabled CFB (count=$REENABLES)" >> $LOG
    fi

    echo $CEIL0 > $P0
    echo $CEIL6 > $P6

    sleep $POLL
  done
) &

# $$ inside a subshell is the PARENT's pid in POSIX sh, so the lock must be written
# here, by the parent, from $!. Writing it inside the subshell records a pid that has
# already exited, which makes the single-instance check above always miss and lets
# duplicate watchdogs accumulate.
echo $! > $LOCK
