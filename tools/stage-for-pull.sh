#!/system/bin/sh
# Copy everything worth keeping out of the root-owned experiment directory into a
# shell-readable staging dir, so `adb pull` (which runs as `shell`) can fetch it.
# Copies only; deletes nothing.
SRC=/data/local/tmp/gzab
DST=/data/local/tmp/pullme

rm -rf $DST
mkdir -p $DST/csv

# every CSV produced by tonight's experiments
cp $SRC/*.csv $DST/csv/ 2>/dev/null
[ -d $SRC/results ]     && cp $SRC/results/*.csv $SRC/results/summary.txt $DST/csv/ 2>/dev/null
[ -d $SRC/results_inv ] && for f in $SRC/results_inv/*; do
  [ -f "$f" ] && cp "$f" "$DST/csv/inv_$(basename $f)"
done

# the 34 MiB seed corpus. big.dat is exactly 28 concatenated copies of this, so
# keeping the seed preserves byte-identical reproduction of the 908 MiB input.
cp $SRC/gzsrc.dat $DST/ 2>/dev/null

chmod -R 777 $DST
echo "staged to $DST:"
ls -la $DST
echo "csv count: $(ls $DST/csv | wc -l)"
echo "seed md5:  $(md5sum $DST/gzsrc.dat 2>/dev/null | cut -d' ' -f1)"
echo "STAGE_DONE"
