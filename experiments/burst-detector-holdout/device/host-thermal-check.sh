#!/system/bin/sh
# Host-side thermal preflight read (tools/run-r4-holdout.py, AdbDevice.thermal_milli_c).
#
# Must run as a pushed file, not an inline multi-word `adb shell su -c
# '<script>'` argument: adb's shell subcommand does not reliably preserve a
# multi-token script (for/case/done) as a single argv element end to end, and
# a `for z in ...; do ... done` sent that way came back
# "syntax error: unexpected 'do'" -- silently defeating the host-side
# thermal preflight, since a failed read parses as (None, None) and the
# caller treats that as "no reading, skip the check" rather than an error.
# Reuses zone_by_name/rd from common.sh rather than re-deriving the same
# thermal-zone-by-type lookup.

DIR=$(dirname "$0")
. "$DIR/common.sh"

_j=$(zone_by_name "$J_ZONE_TYPE") && { rd "$_j"; echo "J:$R"; }
_s=$(zone_by_name "$S_ZONE_TYPE") && { rd "$_s"; echo "S:$R"; }
