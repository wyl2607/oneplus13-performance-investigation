#!/system/bin/sh
# Read-only snapshot to explain a GB7 725 / 5942 run. Writes nothing.
echo "=== date ==="; date; uptime
echo "=== boot/uptime seconds ==="; cat /proc/uptime

echo "=== policy0 (cpu0-5) ==="
for f in scaling_cur_freq scaling_max_freq scaling_min_freq cpuinfo_max_freq scaling_governor; do
  printf '%s=%s\n' "$f" "$(cat /sys/devices/system/cpu/cpufreq/policy0/$f 2>/dev/null)"
done
echo "=== policy6 (cpu6-7 prime) ==="
for f in scaling_cur_freq scaling_max_freq scaling_min_freq cpuinfo_max_freq scaling_governor; do
  printf '%s=%s\n' "$f" "$(cat /sys/devices/system/cpu/cpufreq/policy6/$f 2>/dev/null)"
done

echo "=== per-cpu cur freq ==="
for c in 0 1 2 3 4 5 6 7; do
  printf 'cpu%s online=%s cur=%s\n' "$c" \
    "$(cat /sys/devices/system/cpu/cpu$c/online 2>/dev/null)" \
    "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null)"
done

echo "=== msm_performance cpu_max_freq (URCC-owned) ==="
cat /sys/kernel/msm_performance/parameters/cpu_max_freq 2>&1

echo "=== fqm_dump (freq_qos requesters) ==="
cat /proc/oplus_freqreq_monitor/fqm_dump 2>&1 | head -60

echo "=== cpufreq_bouncing config ==="
cat /sys/module/cpufreq_bouncing/parameters/enable 2>&1
cat /proc/cpufreq_bouncing/config 2>&1 | head -20

echo "=== task_overload ==="
cat /proc/task_overload/skip_goplus_enabled 2>&1
echo "--- abnormal_task (in-kernel, cleared on reboot) ---"
cat /proc/task_overload/abnormal_task 2>&1 | tail -60

echo "=== thermal ==="
dumpsys thermalservice 2>/dev/null | sed -n '1,25p'
for z in /sys/class/thermal/thermal_zone*; do
  t=$(cat $z/type 2>/dev/null); v=$(cat $z/temp 2>/dev/null)
  case "$t" in *cpu*|*soc*|*shell*|*skin*|*batt*) echo "$t=$v";; esac
done | sort -u | head -30

echo "=== battery / power mode ==="
dumpsys battery 2>/dev/null | sed -n '1,20p'
settings get global low_power 2>&1
cmd power get-mode 2>/dev/null
getprop | grep -iE 'perfmode|powersave|power_mode|hypnus|game' 2>&1 | head -20

echo "=== geekbench pkg state ==="
pm list packages 2>/dev/null | grep -i parkdale

echo "=== game_opt ==="
for n in cpu_max_freq dsu_freq disable_cpufreq_limit fake_cpu7_cpuinfo_max_freq; do
  printf '%s=%s\n' "$n" "$(cat /proc/game_opt/$n 2>/dev/null)"
done

echo "=== any mitigation loop running? ==="
ps -A -o PID,USER,NAME 2>/dev/null | grep -iE 'uclampset|cfb|tune|watchdog|unclamp' | grep -v grep

echo "=== cpu_capacity ==="
for c in 0 3 6 7; do printf 'cpu%s cap=%s\n' "$c" "$(cat /sys/devices/system/cpu/cpu$c/cpu_capacity 2>/dev/null)"; done
echo "=== DONE ==="
