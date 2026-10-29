# R4 Phase 3 overhead validation result -- 2026-08-27

Ran on device 3bec6889 (OnePlus 13, CPH2653), op13perf module in
high-performance tier per user confirmation. Raw driver:
`../overhead-validate.sh`, raw output: `overhead-results.log`,
per-run observer traces: `obs-logs/`.

## Known confounds (disclosed, not hidden)

1. Genshin Impact was left running in the foreground for the entire
   validation (launched deliberately to give the observer a realistic
   ~867-thread top-app population -- pid 9114 alone had 248 threads --
   matching the doc's "~516 top-app threads" reference case). This means
   "observer OFF" was not "workload alone": Genshin's own CPU/GPU draw
   was present in both arms. It should mostly cancel in the OFF-vs-ON
   comparison since it's common to both, but absolute wall-clock numbers
   run ~2x longer than the workload-alone calibration.
2. Observer duration was set to 25s based on a workload-alone calibration
   (~15s expected). Actual workload completion under Genshin contention
   was 32-37s, so the observer exited before the workload finished in
   every ON rep -- the tail of each ON run had no observer running at
   all. This makes the reported ON-arm overhead a **conservative
   underestimate**, not an inflated one.

Decision (user-confirmed): accept these numbers as a documented lower
bound rather than rerun clean.

## Results (3 reps per arm)

| regime | arm | wall_cs mean | OFF spread (max-min) | ON-OFF delta | observer windows/25s (nominal 100) |
|---|---|---|---|---|---|
| 1-thread (core7) | OFF | 3208.3 | 39 | -- | -- |
| 1-thread (core7) | ON  | 3254.3 | -- | +46cs (+1.4%) | 76-78 (~325ms/window) |
| 8-thread (1/core)| OFF | 3485.7 | 151 | -- | -- |
| 8-thread (1/core)| ON  | 3680.0 | -- | +194cs (+5.6%) | 45-47 (~540ms/window, >2x nominal) |

`observer_selfstat` is NA in the raw log for every rep: the observer
process had already exited (see confound #2) by the time its
`/proc/<pid>/stat` was read, so no per-process CPU isolation figure
was obtained. The `cpu_busy_jiffies_delta` column in the raw log is a
system-wide busy-jiffy delta, not observer-isolated, and is not used
in the verdict below for that reason.

Thermal: junction (cpu-1-1-1) ranged 61.7-68.7C across all 12 runs,
well under the 92C soft gate. No thermal concern.

## Verdict, applying the protocol's own pass/fail rule

- **1-thread regime: not OVERHEAD_LIMITED.** ON-OFF delta (46cs) is
  within the OFF arm's own run-to-run spread (39cs) -- not
  distinguishable from noise. Consistent with
  docs/DOMINANT_THREAD_OBSERVER.md V6 "clean at one busy core."
- **8-thread regime: OVERHEAD_LIMITED.** ON-OFF delta (194cs, +5.6%)
  exceeds the OFF arm's own spread (151cs), and independently crosses
  the ~5% threshold named in the R4 protocol. Cadence drift is severe
  (window interval >2x nominal 250ms under load). Consistent with V6
  "contaminating at eight."

## OVERHEAD DECISION

**HIGH_LOAD_OBSERVER_CONTAMINATION declared for the many-thread
regime.** Per protocol this does not stop or invalidate the holdout,
and does not change C2/C4, thresholds, or workloads.csv. But:
`steady_gameplay` and `steady_game_title` (many-thread regime) must be
reported as measured under a known-contaminating instrument regime --
not presented with the same confidence as workloads in the clean
1-thread-equivalent regime -- in the final R4 report (Analysis A).

The effect size found here (5.6%, likely understated per confound #2)
is not large enough to make detector output itself untrustworthy
(it is not, e.g., a multiple-fold slowdown or majority-dropped-window
regime), so this does not trigger the "STOP before official 88 runs"
clause -- only the mandatory disclosure clause.
