#!/system/bin/sh
now() { read a b < /proc/uptime; echo "${a%.*}${a#*.}"; }
N=1000000
t0=$(now)
taskset 80 sh -c "i=0; while [ \$i -lt $N ]; do i=\$((i+1)); done"
t1=$(now)
echo "N=$N elapsed_cs=$((t1-t0))"
