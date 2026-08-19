#!/system/bin/sh
# Install Termux:Widget shortcuts onto this device.
# From a computer:
#   adb push mitigation/op13perf/shortcuts /data/local/tmp/op13perf-shortcuts
#   adb shell su -c 'sh /data/local/tmp/op13perf-shortcuts/install-shortcuts.sh'
#
# Idempotent: re-running overwrites the five widget scripts and the helper.
# The helper lives outside .shortcuts so Termux:Widget does not list it.

if [ "$(id -u)" != 0 ]; then
	echo "需要 root，请用: adb shell su -c 'sh <本脚本路径>'"
	exit 1
fi

HERE=$0
case "$HERE" in
	/*) ;;
	*) HERE=$(pwd)/$HERE ;;
esac
HERE=${HERE%/*}

TERMUX_HOME=/data/data/com.termux/files/home
DEST=$TERMUX_HOME/.shortcuts
LIBDIR=$TERMUX_HOME/.op13perf

if [ ! -d "$TERMUX_HOME" ]; then
	echo "找不到 $TERMUX_HOME —— Termux 没装？"
	exit 1
fi

# Read the uid off Termux's own home rather than hardcoding it: it changes when
# Termux is reinstalled or installed under a second Android user, and a wrong
# owner shows up as an empty widget list with no error anywhere.
TUID=$(stat -c %u "$TERMUX_HOME" 2>/dev/null)
case "$TUID" in
	''|*[!0-9]*) echo "读不到 $TERMUX_HOME 的属主 uid"; exit 1 ;;
esac
echo "Termux uid = $TUID"

mkdir -p "$DEST" "$LIBDIR"

if [ ! -f "$HERE/_common.sh" ]; then
	echo "缺少 $HERE/_common.sh"
	exit 1
fi
cp "$HERE/_common.sh" "$LIBDIR/_common.sh"
chown "$TUID:$TUID" "$LIBDIR/_common.sh"
chmod 644 "$LIBDIR/_common.sh"
chown "$TUID:$TUID" "$LIBDIR"
chmod 700 "$LIBDIR"

# Only the widget entries go in .shortcuts -- Termux:Widget lists whatever is in
# that directory, so the helper would otherwise appear as a dead row.
for f in \
	"0-原厂.sh" \
	"1-日常档.sh" \
	"2-高性能档.sh" \
	"3-极限档.sh" \
	"状态.sh"
do
	if [ ! -f "$HERE/$f" ]; then
		echo "缺少 $HERE/$f"
		exit 1
	fi
	cp "$HERE/$f" "$DEST/$f"
	chown "$TUID:$TUID" "$DEST/$f"
	chmod 755 "$DEST/$f"
done

chown "$TUID:$TUID" "$DEST"
chmod 700 "$DEST"

echo "已安装：$DEST （5 个入口） + $LIBDIR/_common.sh （属主 $TUID:$TUID）"
ls -ln "$DEST"
