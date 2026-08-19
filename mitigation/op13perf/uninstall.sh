#!/system/bin/sh
# Nothing this module touches is persistent, so removal only has to stop the
# daemon: URCC reclaims cpu_max_freq and the guard re-clamps on its own.
STATEDIR=/data/adb/op13perf
[ -f "$STATEDIR/state" ] && echo 0 > "$STATEDIR/state"
if [ -f "$STATEDIR/pid" ]; then
	read p < "$STATEDIR/pid" 2>/dev/null
	[ -n "$p" ] && [ -d "/proc/$p" ] && \
		tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q perfd.sh && kill "$p"
fi
sleep 1
rm -rf "$STATEDIR"
