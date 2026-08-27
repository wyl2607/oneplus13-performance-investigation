#!/system/bin/sh
# Host-side screen-on check (tools/run-r4-holdout.py, AdbDevice.screen_on).
# Pushed as a file rather than an inline `adb shell su -c '<script>'`
# argument for the same reason as host-thermal-check.sh: adb shell does not
# reliably preserve a multi-token piped script passed as a single argv
# element.
dumpsys display | grep -m1 mScreenState
