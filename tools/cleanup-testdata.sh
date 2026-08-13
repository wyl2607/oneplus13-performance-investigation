#!/system/bin/sh
# Remove the real-workload test corpus and per-run captures from the device.
# Everything here is reproducible: the scripts are in the repo, the CSVs are pulled
# into data/real-workload/, and big.dat rebuilds byte-identically from the 34 MiB
# seed via tools/restore-testdata.sh.
#
# Kills any surviving experiment process first. A busy loop holding a file open does
# not block unlink on Linux, but a surviving busy loop is its own problem -- three of
# them ran unnoticed for 15 minutes after an aborted run because the cleanup pkill
# pattern did not match the binary names that run actually used.
D=/data/local/tmp/gzab

echo "--- killing any surviving experiment processes ---"
for pat in plsleep plsleep2 plsleepprobe gzabrun gzabinv gzabprobe fpprobe trigprobe_busy; do
  pkill -9 -f "$pat" 2>/dev/null
done
# also by binary name, which is what actually survived last time
for n in w_spin w_slow w_fast; do pkill -9 -x "$n" 2>/dev/null; done
pkill -9 -u 10999 gzip 2>/dev/null
sleep 1
LEFT=$(ps -A -o PID,USER,NAME 2>/dev/null | grep -E 'w_spin|w_slow|w_fast|gzip|spin_' | grep -v grep)
if [ -n "$LEFT" ]; then
  echo "STILL RUNNING:"
  echo "$LEFT"
else
  echo "none left"
fi

echo
echo "--- before ---"
du -sh $D 2>/dev/null

echo
echo "--- removing ---"
rm -rf $D 2>&1

echo
echo "--- after ---"
if [ -d "$D" ]; then
  echo "STILL PRESENT:"
  ls -la $D
else
  echo "$D removed"
fi
df -h /data | tail -1
echo "CLEANUP_DONE"
