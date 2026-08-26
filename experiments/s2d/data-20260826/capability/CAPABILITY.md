# S2d Phase 1: frequency telemetry capability survey

Probed on-device (CPH2653, kernel `6.6.118-android15-8-g2e6b9c3812c5`) before
any S2d data collection. Raw probe output: `probe-raw.log` in this directory.

## Available evidence, in priority order

1. **`power:cpu_frequency` tracepoint** -- EXISTS
   (`/sys/kernel/tracing/events/power/cpu_frequency/format`). Fields:
   `state` (the new frequency in kHz) and `cpu_id`. **No pid field** -- this
   is a systemwide event, one per real DVFS transition on any CPU, and
   cannot be filtered to our target thread. Also found sibling
   `power:cpu_frequency_limits` (min/max/cpu_id, fires on limit changes, not
   useful for steady-state residency).

2. **cpufreq policy stats** -- EXISTS at both clusters:
   - `policy0` (mid, `related_cpus=0 1 2 3 4 5`): `stats/time_in_state`,
     `stats/total_trans`, `stats/trans_table` all present and non-empty.
   - `policy6` (prime, `related_cpus=6 7`): same three files present.
   `time_in_state` is a table of `freq_khz cumulative_jiffies`, monotonic
   since boot (or since last `stats/reset`). A before/after snapshot per run
   gives an exact, **zero-overhead** per-cluster residency delta -- no
   tracing, no extra kernel work, just two sysfs reads.

3. **WALT-specific frequency tracepoints** -- EXISTS, in the `schedwalt`
   group already used by `scheduler-event-tracer.sh`:
   - `waltgov_next_freq`: per-CPU governor decision (`cpu`, `util`, `max`,
     `raw_freq`, `freq`, `policy_min_freq`, `policy_max_freq`,
     `cached_raw_freq`, `need_freq_update`, `final_freq`, `reason`, ...).
     Also no pid field -- fires per governor evaluation, not per task.
   - `sched_freq_uncap`, `ipc_freq`: cluster-level (`id`/cluster, `nr_big`,
     `winning_cpu`, `winning_freq`, ipc counters) -- secondary, not used
     this round.
   No separate Qualcomm/MSM cpufreq tracepoint group exists beyond
   `clk_qcom`/`interconnect_qcom` (not frequency-selection events).

4. **`scaling_cur_freq` polling** -- available as a fallback, not needed
   (options 1-3 all exist).

## Decision

- **Primary per-run metric: `time_in_state` delta**, per cluster (policy0 /
  policy6), snapshotted immediately before and after each run. Zero
  overhead, directly gives the "policy0/policy6 frequency residency"
  fields the task asked for, and needs no A/B validation since it adds no
  tracer load at all.
- **Secondary, trace-level metric: `power:cpu_frequency`**, added as a new
  **opt-in** `--freq` flag to `tools/scheduler-event-tracer.sh` (default
  off, so every existing S2b/S2c invocation and its recorded output is
  unaffected). This is the only way to get transition timestamps
  correlatable against the traced thread's own wake cycles (for "frequency
  immediately around the traced burst"). Because it cannot be pid-filtered,
  its overhead and event volume are validated with the required A/B before
  it is trusted for any S2d run (see `overhead-ab.md` in this directory).
- `waltgov_next_freq` was considered as an alternative to `cpu_frequency`
  (already in the `schedwalt` group the tracer enables) but rejected for
  this round: it fires on every governor *evaluation*, not just on actual
  transitions, so its volume is harder to bound than `cpu_frequency`'s
  transition-only semantics, and `cpu_frequency` already answers the
  "frequency around the burst" question. Left as a documented option for a
  future session if `cpu_frequency` proves too coarse.
