#!/system/bin/sh
#
# video-export.sh - stock vs unclamp harness for a transcode / export.
#
# WRITE ONLY AS A HARNESS. Result is currently TODO: unmeasured.
#
# Default: ffmpeg lavfi testsrc -> libx264, if ffmpeg is present.
# Override with `-- <command>` when the device has a different encoder
# (or an app-driven export you can launch as this uid).
#
# usage:
#   sh video-export.sh <stock|unclamp> [uid]
#   sh video-export.sh <stock|unclamp> [uid] -- ffmpeg ...
#   sh video-export.sh <stock|unclamp> [uid] -- /path/to/export.sh

HERE=$(dirname "$0")
. "$HERE/common.sh"

ARM="$1"
shift
if [ -z "$ARM" ]; then
	say "usage: sh video-export.sh <stock|unclamp> [uid] [-- command ...]"
	exit 2
fi

UID=10999
if [ -n "$1" ] && [ "$1" != "--" ]; then
	case "$1" in
		*[!0-9]*)
			say "ERROR: uid must be numeric, got: $1"
			exit 2
			;;
		*) UID=$1; shift ;;
	esac
fi
if [ "$1" = "--" ]; then
	shift
	CMD="$*"
	if [ -z "$CMD" ]; then
		say "ERROR: -- requires a command"
		exit 2
	fi
else
	FF=""
	for c in ffmpeg /data/local/tmp/ffmpeg /system/bin/ffmpeg; do
		if command -v "$c" >/dev/null 2>&1; then
			FF=$(command -v "$c")
			break
		fi
		if [ -x "$c" ]; then
			FF=$c
			break
		fi
	done
	if [ -z "$FF" ]; then
		say "ERROR: ffmpeg not found and no `-- <command>` given."
		say "not substituting a busy loop. video-export is TODO: unmeasured"
		exit 2
	fi
	WORKDIR=/data/local/tmp/rw-work
	mkdir -p "$WORKDIR" 2>/dev/null
	chmod 777 "$WORKDIR" 2>/dev/null
	OUT=$WORKDIR/export.mp4
	rm -f "$OUT"
	# 10 s of 720p is a starting point, not a measured duration.
	SRC='testsrc=duration=10:size=1280x720:rate=30'
	CMD="$FF -y -f lavfi -i $SRC -c:v libx264 -preset medium $OUT"
fi

say "cmd=$CMD"
# 300 s bound: a 10 s encode should finish well inside it; an app-driven
# export might not, in which case raise the bound at the call site.
run_workload "$ARM" video-export "$UID" 300 "$CMD"
