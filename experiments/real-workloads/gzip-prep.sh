#!/system/bin/sh
# gzip-prep.sh - build the deterministic input for the real-workload A/B, and
# calibrate how many passes give a run long enough to be clamped.
#
# The input is generated ONCE and reused by every arm of every repetition, so both
# arms compress byte-identical data. It is base64 text: compressible enough that
# gzip -9 does real match-search work, unlike random binary which deflate abandons.
#
# Writes no kernel parameter.

DIR=/data/local/tmp/gzab
IN=$DIR/gzsrc.dat
MB=24

mkdir -p $DIR

if [ -f "$IN" ]; then
  echo "input already exists"
else
  echo "generating input (${MB} MiB urandom -> base64)..."
  dd if=/dev/urandom bs=1048576 count=$MB 2>/dev/null | base64 > $IN
fi
chmod 755 $DIR
chmod 644 $IN
echo "input: $IN"
echo "size:  $(wc -c < $IN) bytes"
echo "sum:   $(md5sum $IN | cut -d' ' -f1)"

echo
echo "--- warm page cache ---"
cat $IN > /dev/null
cat $IN > /dev/null

now() { read a b < /proc/uptime; echo "${a%.*}${a#*.}"; }   # centiseconds

echo
echo "--- calibrate: 1 pass, as root, at the current ceiling ---"
echo "current p0max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) p6max=$(cat /sys/devices/system/cpu/cpufreq/policy6/scaling_max_freq)"
T0=$(now)
gzip -9 -c $IN > /dev/null
T1=$(now)
EL=$(( (T1 - T0) * 10 ))
echo "1 pass elapsed_ms=$EL"

if [ "$EL" -gt 0 ]; then
  echo "passes for ~45 s: $(( 45000 / EL ))"
  echo "passes for ~60 s: $(( 60000 / EL ))"
fi

echo "PREP_DONE"
