#!/system/bin/sh
# Why can't root unlink files in /data/local/tmp/gzab?
D=/data/local/tmp/gzab
echo "id: $(id)"
echo "selinux: $(getenforce 2>/dev/null)"
echo
echo "--- dir ---"
ls -ldZ $D 2>/dev/null || ls -ld $D
echo
echo "--- a file ---"
ls -lZ $D/gzsrc.dat 2>/dev/null || ls -l $D/gzsrc.dat
echo
echo "--- attrs ---"
lsattr -d $D 2>&1 | head -2
lsattr $D/gzsrc.dat 2>&1 | head -2
echo
echo "--- mount ---"
grep ' /data ' /proc/mounts 2>/dev/null | head -2
echo
echo "--- anything holding it open? ---"
for p in /proc/[0-9]*; do
  for f in $p/fd/*; do
    l=$(readlink "$f" 2>/dev/null)
    case "$l" in *gzab*) echo "$(basename $p) $(cat $p/comm 2>/dev/null) -> $l";; esac
  done
done 2>/dev/null | head -10
echo
echo "--- try one unlink verbosely ---"
rm -f $D/pl2_fast.csv 2>&1 && echo "unlink of pl2_fast.csv OK" || echo "unlink failed rc=$?"
echo
echo "RMDIAG_DONE"
