# Offline WALT prime-admission model

This directory is descriptive analysis only. It does not change a device and it
does not claim that `uclamp.min` changes WALT's placement input.

## Source evidence

`s2a-pr13-burst-sweep.csv` is an exact transcription of the aggregate burst-sweep
table recorded on the draft `feature/scheduler-event-tracer` branch in
`data/2026-08-22/s2a-wake-path.txt` / PR #13. It is copied here so the offline
model can be tested without making PR #14 depend on merging #13. It is not a new
measurement.

The seven measured points are WALT predicted demand versus prime first-run share.
The model intentionally ignores burst size as a causal input: S2a changed burst
size only to move task demand, while the next experiment needs to hold workload
constant and change `uclamp.min`.

## Model

`tools/fit-prime-admission.py` applies weighted non-decreasing isotonic regression
(PAVA), then piecewise-linear interpolation between measured demand points. This
provides a compact descriptive crossover curve without fitting a high-parameter
sigmoid to seven observations.

Example:

```sh
python tools/fit-prime-admission.py \
  experiments/walt-prime-model/s2a-pr13-burst-sweep.csv \
  --predict 512 --predict 640
```

With the current S2a input, the measured demand domain is 158..616. The tool
**refuses to extrapolate** outside that range. A request for 640 or 768 is marked
`OUT_OF_MODEL_DOMAIN` rather than extending the last observed prime share as if
it were evidence.

Within the measured domain the descriptive interpolation puts the 50% prime
admission crossover at about demand 519 and the 80% point at about 609. Those
are summaries of the S2a demand sweep only. They do not establish that setting
`uclamp.min` to the same number will produce that demand or admission rate.

The output always states that the `uclamp.min` counterfactual is unvalidated.
The curve describes **measured WALT demand -> measured prime admission**, not
`uclamp.min -> prime admission`.

## Burst-policy simulator

`tools/simulate-burst-policy.py` can explore a hypothetical bounded boost against
a supplied workload demand distribution. By default it refuses to run because
the required link is the exact unknown S2b is designed to measure.

To run a hypothesis-only counterfactual, the caller must explicitly pass:

```text
--assume-clamp-visible-to-walt
```

That flag means: for exploration only, assume WALT placement behaves as though
its demand input were `max(observed_demand, requested_uclamp_min)`. The result is
labelled `HYPOTHESIS_ONLY` and `s2b_validated=false`; it must not be used to
change Daily / Performance / Extreme.

The simulator inherits the same measured-domain guard. If a workload or a
candidate clamp would require extrapolation, that arm is marked
`OUT_OF_MODEL_DOMAIN` and gets no predicted prime share.

Once S2b is measured, either replace this assumption with the measured transfer
function or remove the simulator if the lever is falsified.
