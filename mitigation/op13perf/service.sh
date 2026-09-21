#!/system/bin/sh
# Runs late_start service. The level entered at boot comes from BOOT_LEVEL in
# /data/adb/op13perf/conf: 0=off (stock), 1=daily, 2=performance, 3=extreme.
# 3 assumes the 40 W cooler is attached and the module cannot detect that, so it
# is a legal boot level but a poor one. The default is 2: DATA.md section 45
# measured level 2 bare-device at +16.53% single / +11.33% multi over level 1
# with the step-down never firing in eight runs.
MODDIR=${0%/*}
STATEDIR=/data/adb/op13perf

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 20

mkdir -p "$STATEDIR"

BOOT_LEVEL=2
[ -f "$STATEDIR/conf" ] && . "$STATEDIR/conf"
case "$BOOT_LEVEL" in 1|2|3) : ;; *) BOOT_LEVEL=0 ;; esac

echo "$BOOT_LEVEL" > "$STATEDIR/state"
date +%s > "$STATEDIR/since"

# Write both fields. Writing only version left the description showing whatever
# level was last selected before the reboot.
. "$MODDIR/desc.sh"
write_prop "$BOOT_LEVEL" "$MODDIR/module.prop"

nohup "$MODDIR/perfd.sh" >/dev/null 2>&1 &
echo $! > "$STATEDIR/pid"
