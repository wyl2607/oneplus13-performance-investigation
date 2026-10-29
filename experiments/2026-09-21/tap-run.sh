#!/bin/bash
# Tap Geekbench's "Run CPU Benchmark" by its real bounds, whatever the rotation.
# A hardcoded coordinate silently missed once and produced a 6-minute run that
# never happened (junction stayed at 31 C), so the button is located every time.
set -e
adb shell 'uiautomator dump /sdcard/ui.xml >/dev/null 2>&1'
BOUNDS=$(adb shell 'cat /sdcard/ui.xml' \
  | tr '<' '\n' \
  | grep 'id/runCpuBenchmarks' \
  | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' \
  | head -1)
[ -n "$BOUNDS" ] || { echo "RUN BUTTON NOT FOUND - is Geekbench on its home screen?"; exit 3; }
read X1 Y1 X2 Y2 <<<"$(echo "$BOUNDS" | grep -o '[0-9]\+' | tr '\n' ' ')"
CX=$(( (X1 + X2) / 2 )); CY=$(( (Y1 + Y2) / 2 ))
echo "button $BOUNDS -> tap ($CX,$CY)"
adb shell "input tap $CX $CY"
