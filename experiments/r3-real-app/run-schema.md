# R3 run log schema

One log per run, written by `run-one.sh` to `--out` (kept under
`experiments/r3-real-app/raw/`, gitignored — raw logs carry the real package
name in `#META`/`#AM_START` lines and are never committed). Lines:

```
#META run_id=<id> workload=<id> arm=control|512 mechanism=process|active-set|none
#META screen=<dumpsys display mScreenState line>
S|<uptime_cs>|j=<junction milli-C>|s=<shell milli-C>|all_busy=<jiffies>|prime_busy=<jiffies>|fg_threads=<n>|clamped_threads=<n>
EVENT|event_id=<run_id>|phase=start|t_ms=<ms>
EVENT|event_id=<run_id>|phase=end|t_ms=<ms>
#AM_START <raw `am start -W` output, including TotalTime/WaitTime>
#GFXINFO_BEGIN
<filtered dumpsys gfxinfo lines: Total frames rendered, Janky frames, percentiles>
#GFXINFO_END
RESULT run_id=<id> workload=<id> arm=<arm> mechanism=<mechanism> wall_cs=<n> event_ms=<n|NA> status=<OK|...> out=<path> tis0_before=<path> tis0_after=<path> tis6_before=<path> tis6_after=<path>
```

Alongside `--out`, four `time_in_state` snapshot files
(`<out>.tis{0,6}.{before,after}`) and, for `active-set` runs, `<out>.activeset`
(one line per tick: the space-separated tid list clamped that tick — this is
the source for `clamped_thread_count` and `clamp_ticks/total_ticks`).

`status` values: `OK`, `NO_TOTALTIME_PARSED` (am start's output didn't match
the expected `TotalTime:` line — treat the run's latency field as missing,
not zero), `RUN_ABORT_THERMAL_92` (soft gate, this run only), `SESSION_STOP_
THERMAL_95` (hard gate, stop the whole session), `THERMAL_ABOVE_SOFT_GATE_AT_
START` (preflight refused to start).

`tools/analyze-r3-real-app.py` is the only consumer of this format. It is
also the point where `APP_A`/`APP_B`/`APP_C` sanitization happens before
anything derived from these logs is committed — see
`docs/R3_REAL_APP_PILOT.md#app-privacy`.
