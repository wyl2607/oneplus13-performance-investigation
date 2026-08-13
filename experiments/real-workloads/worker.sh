#!/system/bin/sh
# worker.sh <iterations_per_burst> <sleep_seconds> <fifo>
#
# The workload body for placement-vs-sleep-v2.sh. Kept in its own file so the shell
# quoting survives `su <uid> -c ...` intact (METHODOLOGY trap 5).
#
# iterations_per_burst = 0 means spin forever and never sleep.
#
# Sleeping is done with `read -t` against a fifo opened read-write, which blocks for
# the timeout and then returns. This costs NO fork, unlike calling `sleep`, so the
# spinning and sleeping variants are matched on process-creation rate (both zero).
# The fifo is opened <> so that opening it does not block waiting for a writer.
N=$1
S=$2
F=$3

if [ "$N" = "0" ]; then
  i=0
  while : ; do i=$((i+1)); done
else
  exec 3<> "$F"
  while : ; do
    i=0
    while [ $i -lt $N ]; do i=$((i+1)); done
    read -t "$S" x <&3
  done
fi
