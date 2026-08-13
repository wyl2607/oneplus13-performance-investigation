#!/system/bin/sh
#
# compile.sh - stock vs unclamp harness for a single-threaded compile.
#
# WRITE ONLY AS A HARNESS. Do not treat a run as evidence until a capture
# is in data/. Result is currently TODO: unmeasured.
#
# The compiler is the workload. It must run as an app uid (default 10999).
# A missing compiler is a hard error, not a reason to substitute a loop.
#
# usage: sh compile.sh <stock|unclamp> [uid]

HERE=$(dirname "$0")
. "$HERE/common.sh"

ARM="$1"
UID="${2:-10999}"
if [ -z "$ARM" ]; then
	say "usage: sh compile.sh <stock|unclamp> [uid]"
	exit 2
fi

CC=""
for c in clang gcc cc /data/local/tmp/clang /system/bin/clang /system/bin/gcc; do
	if command -v "$c" >/dev/null 2>&1; then
		CC=$(command -v "$c")
		break
	fi
	if [ -x "$c" ]; then
		CC=$c
		break
	fi
done
if [ -z "$CC" ]; then
	say "ERROR: no clang/gcc/cc on this device. not substituting a busy loop."
	say "the compile workload is TODO: unmeasured"
	exit 2
fi

WORKDIR=/data/local/tmp/rw-work
mkdir -p "$WORKDIR" 2>/dev/null
chmod 777 "$WORKDIR" 2>/dev/null
SRC=$WORKDIR/w.c
OUT=$WORKDIR/w.out
rm -f "$OUT"

# Enough functions that a -O2 compile is seconds, not milliseconds.
# Generated here so the tree does not ship a dummy source as a "result".
{
	printf '%s\n' 'int acc;'
	i=0
	while [ "$i" -lt 400 ]; do
		printf 'int f%d(int x){return x*%d+x/((%d%%7)+1);}\n' "$i" "$i" "$i"
		i=$((i + 1))
	done
	printf '%s\n' 'int main(void){int s=0;int i;for(i=0;i<400;i++)s+=f0(i);return s;}'
} > "$SRC"
chmod 644 "$SRC"

say "compiler=$CC"
# 180 s is a bound, not a measurement of how long this takes.
run_workload "$ARM" compile "$UID" 180 "$CC -O2 -o $OUT $SRC"
