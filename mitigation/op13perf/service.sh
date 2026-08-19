#!/system/bin/sh
# Runs late_start service. The level entered at boot comes from BOOT_LEVEL in
# /data/adb/op13perf/conf: 0=off (stock), 1=daily, 2=performance, 3=extreme.
# 3 assumes the 40 W cooler is attached and the module cannot detect that, so it
# is a legal boot level but a poor one -- the default stays 1.
MODDIR=${0%/*}
STATEDIR=/data/adb/op13perf

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
sleep 20

mkdir -p "$STATEDIR"

BOOT_LEVEL=1
[ -f "$STATEDIR/conf" ] && . "$STATEDIR/conf"
case "$BOOT_LEVEL" in 1|2|3) : ;; *) BOOT_LEVEL=0 ;; esac

echo "$BOOT_LEVEL" > "$STATEDIR/state"
date +%s > "$STATEDIR/since"

case "$BOOT_LEVEL" in
	0) L="已关闭" ;;
	1) L="日常档" ;;
	2) L="高性能档" ;;
	3) L="极限档" ;;
esac
sed -i "s|^version=.*|version=v1.2.0-$L|" "$MODDIR/module.prop" 2>/dev/null

nohup "$MODDIR/perfd.sh" >/dev/null 2>&1 &
echo $! > "$STATEDIR/pid"
