#!/system/bin/sh
#
# decompress.sh - stock vs unclamp harness for a single-threaded gunzip.
#
# WRITE ONLY AS A HARNESS. Result is currently TODO: unmeasured.
#
# usage: sh decompress.sh <stock|unclamp> [uid]

HERE=$(dirname "$0")
. "$HERE/common.sh"

ARM="$1"
UID="${2:-10999}"
if [ -z "$ARM" ]; then
	say "usage: sh decompress.sh <stock|unclamp> [uid]"
	exit 2
fi

GZ=""
for c in gzip /system/bin/gzip toybox; do
	if command -v "$c" >/dev/null 2>&1; then
		GZ=$(command -v "$c")
		break
	fi
done
if [ -z "$GZ" ]; then
	say "ERROR: no gzip on this device. not substituting a busy loop."
	say "the decompress workload is TODO: unmeasured"
	exit 2
fi

WORKDIR=/data/local/tmp/rw-work
mkdir -p "$WORKDIR" 2>/dev/null
chmod 777 "$WORKDIR" 2>/dev/null
BLOB=$WORKDIR/blob
BLOB_GZ=$WORKDIR/blob.gz
BLOB_OUT=$WORKDIR/blob.out
rm -f "$BLOB" "$BLOB_GZ" "$BLOB_OUT"

# 8 MiB of urandom so gzip cannot collapse it to nothing. Generated on
# device; not a checked-in payload.
if ! dd if=/dev/urandom of="$BLOB" bs=1024 count=8192 2>/dev/null; then
	say "ERROR: could not create input blob"
	exit 2
fi
if [ "$GZ" = "$(command -v toybox 2>/dev/null)" ]; then
	toybox gzip -c "$BLOB" > "$BLOB_GZ" || { say "ERROR: gzip failed"; exit 2; }
	CMD="toybox gzip -d -c $BLOB_GZ > $BLOB_OUT"
else
	"$GZ" -c "$BLOB" > "$BLOB_GZ" || { say "ERROR: gzip failed"; exit 2; }
	CMD="$GZ -d -c $BLOB_GZ > $BLOB_OUT"
fi
chmod 644 "$BLOB_GZ"
rm -f "$BLOB"

say "gzip=$GZ"
run_workload "$ARM" decompress "$UID" 180 "$CMD"
