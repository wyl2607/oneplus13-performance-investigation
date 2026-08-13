#!/system/bin/sh
# restore-testdata.sh
#
# Rebuild the real-workload test input on the device from the 34 MiB seed corpus.
# big.dat is exactly 28 concatenated copies of gzsrc.dat, so this reproduces the
# 908 MiB input byte-for-byte -- the wall times in DATA.md sections 31 and 34 are
# only comparable against this exact file.
#
# usage:
#   adb push C:\Users\yzwdm\oneplus13-testdata\gzsrc.dat /data/local/tmp/gzsrc.dat
#   adb shell su -c "sh /data/local/tmp/restore-testdata.sh"

DIR=/data/local/tmp/gzab
SRC=$DIR/gzsrc.dat
BIG=$DIR/big.dat
STAGED=/data/local/tmp/gzsrc.dat
REPEAT=28

MD5_SRC=36384e218609ab330e90cd48aa69071b
MD5_BIG=5c85ba019ff07ae433e48db19dcf4f30

mkdir -p $DIR
chmod 755 $DIR

if [ ! -f "$SRC" ]; then
  if [ -f "$STAGED" ]; then
    echo "moving staged seed into place"
    cp $STAGED $SRC
  else
    echo "FATAL: no seed at $SRC and none staged at $STAGED"
    echo "push it first:  adb push gzsrc.dat $STAGED"
    exit 2
  fi
fi
chmod 644 $SRC

GOT=$(md5sum $SRC | cut -d' ' -f1)
if [ "$GOT" != "$MD5_SRC" ]; then
  echo "FATAL: seed checksum mismatch"
  echo "  expected $MD5_SRC"
  echo "  got      $GOT"
  echo "A different seed produces a different workload. Absolute wall times will not be"
  echo "comparable to DATA.md sections 31 and 34. Refusing to build silently."
  exit 3
fi
echo "seed OK: $GOT"

echo "building ${REPEAT}x concatenated input (this writes ~908 MiB)..."
: > $BIG
n=0
while [ $n -lt $REPEAT ]; do
  cat $SRC >> $BIG
  n=$((n+1))
done
chmod 644 $BIG

GOTB=$(md5sum $BIG | cut -d' ' -f1)
echo "big.dat: $(wc -c < $BIG) bytes  md5=$GOTB"
if [ "$GOTB" != "$MD5_BIG" ]; then
  echo "FATAL: rebuilt input does not match the recorded checksum"
  echo "  expected $MD5_BIG"
  exit 4
fi

echo "RESTORE_OK - input matches the corpus used for DATA.md sections 31 and 34"
