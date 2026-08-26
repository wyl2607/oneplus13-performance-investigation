# S2d Phase 1: `--trace-freq` overhead A/B

4 runs, uclamp.min=512 (the most active arm -- worst case for scheduler
load), 15 s duration each, ABBA order (noFreq, withFreq, withFreq, noFreq)
so any thermal/order drift affects both conditions symmetrically.

| run | condition | complete cycles | trace entries | overrun/dropped |
|---|---|---|---|---|
| ohab-r01 | noFreq | 578 | 9499 | 0 / 0 |
| ohab-r02 | withFreq | 582 | 13731 | 0 / 0 |
| ohab-r03 | withFreq | 580 | 14156 | 0 / 0 |
| ohab-r04 | noFreq | 584 | 9476 | 0 / 0 |

- Mean cycles, noFreq: (578+584)/2 = **581.0**
- Mean cycles, withFreq: (582+580)/2 = **581.0**
- Difference: **0.0%** -- no detectable perturbation, well under the ~3-5%
  budget.
- `power:cpu_frequency` adds ~4200-4650 extra trace entries over 15s
  (~280-310/s, systemwide across all 8 CPUs, since the event carries no pid
  and cannot be filtered) -- absorbed cleanly by the existing 4096 KB/CPU
  buffer with zero overrun, zero dropped, zero commit_overrun in every run.

**Decision: `--trace-freq` is validated for the full threshold ladder.**
No fallback to `time_in_state`-only or to `scaling_cur_freq` polling was
needed.
