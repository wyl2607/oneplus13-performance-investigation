#!/system/bin/sh
# calibrate.sh - pick the workload and its size for the real-workload A/B.
#
# Requirement: ONE long-lived, single-threaded, CPU-bound process. Not a pipeline
# (a `cat` partner adds a second runnable thread and pollutes a placement
# measurement) and not a loop of short processes (each one starts unclamped, and
# the ~5 s clamp latency from section 27 would never be reached).
#
# Writes no kernel parameter.

DIR=/data/local/tmp/gzab
IN=$DIR/gzsrc.dat

now() { read a b < /proc/uptime; echo "${a%.*}${a#*.}"; }   # centiseconds

echo "=== calibrate $(date) ==="
echo "ceiling: p0max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) p6max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)"
echo "input:   $(wc -c < $IN) bytes"

cat $IN > /dev/null

echo
echo "--- gzip -9, one pass ---"
T0=$(now); gzip -9 -c $IN > /dev/null; T1=$(now)
GZ=$(( (T1 - T0) * 10 ))
echo "gzip_9_ms=$GZ  ($(( $(wc -c < $IN) / 1048576 * 1000 / GZ )) MiB/s)"

echo
echo "--- bzip2 -9, one pass ---"
T0=$(now); bzip2 -9 -c $IN > /dev/null; T1=$(now)
BZ=$(( (T1 - T0) * 10 ))
echo "bzip2_9_ms=$BZ  ($(( $(wc -c < $IN) / 1048576 * 1000 / BZ )) MiB/s)"

echo
echo "=== sizing for a ~50 s single-process run ==="
[ "$GZ" -gt 0 ] && echo "gzip:  need $(( 50000 / GZ ))x the input = $(( 50000 / GZ * $(wc -c < $IN) / 1048576 )) MiB on disk"
[ "$BZ" -gt 0 ] && echo "bzip2: need $(( 50000 / BZ ))x the input = $(( 50000 / BZ * $(wc -c < $IN) / 1048576 )) MiB on disk"
echo
echo "IO demand at those rates is 2 orders of magnitude below UFS sequential read,"
echo "so a larger on-disk input stays CPU-bound."
echo "CALIBRATE_DONE"
