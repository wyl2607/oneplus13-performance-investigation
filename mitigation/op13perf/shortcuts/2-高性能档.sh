#!/data/data/com.termux/files/usr/bin/sh
# Termux:Widget execs this file directly, so the shebang must point at an
# interpreter Termux itself can load. #!/system/bin/sh makes its loader try to
# read the script as ELF and fail with "bad ELF magic: 23212f73" -- that hex is
# the characters #!/s. The root half still runs under /system/bin/sh, because
# run_as_root re-execs via `su -c "sh <path>"`, which ignores the shebang.
. /data/data/com.termux/files/home/.op13perf/_common.sh
run_as_root "$0"
do_switch 2
