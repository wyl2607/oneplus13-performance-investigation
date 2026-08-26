# Adaptive burst controller — offline control design

Status: **control-state simulation only; no performance claim and no device write**.

## FOLLOW-UP STATUS (added after S2b/S2c/S2d)

This directory and its two hypotheses (C2/C4 below) were written before any
of S2b-S2d ran. Since then, on-device:

- **S2b** (PR #15) established that `uclamp.min` causally changes scheduler
  placement -- but **not** through the mechanism `tools/simulate-burst-policy.py`
  assumes. `pred_demand` stayed ~100-120 in both arms of a 16-run block
  design and moved in the wrong direction under the clamp, directly
  falsifying the "clamp inflates WALT's demand estimate" identity. See
  `docs/S2B_DEVICE_RESULTS.md`.
- **S2c** (PR #16) localized the real mechanism to the placement-stage
  capacity/candidate check (`start_cpu`/`candidate_mask` in
  `find_best_target`), ruled out the explicit `misfit` flag as the main
  path, and found the effective threshold is a step function somewhere in
  `(448, 512]`, not a dose-response curve. See `docs/S2C_PLACEMENT_MECHANISM.md`,
  `docs/S2C_MINIMUM_CLAMP.md`.
- **S2d** narrowed that threshold to `(504, 512]` and directly measured
  (via `time_in_state`, not derived) that most of the cycle-rate gain below
  the threshold comes from a DVFS/frequency-floor effect, not placement.
  See `docs/S2D_THRESHOLD_DVFS.md`.

Full synthesis: `docs/S2_RESEARCH_SUMMARY.md`.

**`tools/simulate-burst-policy.py` is retained as a HISTORICAL_COUNTERFACTUAL
/ negative-control artifact, not a validated policy simulator** -- see its
own module docstring for the falsification detail. The C2/C4 detector
hypotheses below are still un-holdout-tested; that work (the 88-run C2/C4
holdout) is explicitly the *next* stage, not part of S2b-S2d.

The scheduler investigation points toward short foreground bursts as the next
interesting regime, but the project does not yet have a validated production
detector or a validated `uclamp.min -> WALT placement` transfer function.
Building a real module before those two pieces exist would hide assumptions
inside production code.

This directory therefore starts with the parts that can be validated offline:
**bounded controller timing / safety state, real-workload feature analysis, and
frozen detector hypotheses for later holdout validation**.

## State machine

`tools/simulate-burst-controller.py` replays a time-ordered CSV with:

- `burst_signal` — 0/1 signal from a future detector;
- `junction_c` — temperature used by the safety gate;
- `foreground` — optional 0/1 eligibility gate;
- `screen_on` — optional 0/1 eligibility gate.

The tool has three states:

```text
IDLE -> BOOST -> COOLDOWN -> IDLE
```

A boost requires consecutive positive signal samples. Once active, it is bounded
by all of:

- minimum hold time;
- maximum boost time;
- immediate thermal abort;
- immediate foreground/screen eligibility abort;
- cooldown before another boost can begin.

The replay output records every transition and reason. It deliberately does not
contain a uclamp value, a predicted score or a claimed power saving.

## Real-workload feature layer

`tools/extract-observer-features.py`,
`tools/summarize-observer-features.py`, and
`tools/build-observer-manifest-report.py` re-derive workload shape from the
historical S1 observer-v2 captures pinned in `s1-source-manifest.csv`.

CI verifies every source blob SHA and byte size before analysis. The current
findings and candidate screen are documented in:

- `S1_REAL_WORKLOAD_FINDINGS.md`;
- `../burst-detector-holdout/README.md` for the next frozen-rule holdout.

The S1 screen carries **two hypotheses**, not a selected detector:

- C2 temporal transition (`ROTATION_OR_LEADER`);
- C4 static interaction shape (`INTERACTION_SHAPE`).

C4 separates the committed interaction traces from compute/wake most strongly in
sample, while C2 has a temporal-rotation guard that is more plausible against a
steady multi-thread renderer. Neither is production-ready.

## Why the detector is not wired into the module

S1 showed that real foreground work is often several-thread with a rotating
leader, while the synthetic wake-heavy pair is a mechanism test. The 250 ms shell
observer is also a research instrument with too much latency and overhead for a
production burst controller.

The controller therefore still consumes an abstract `burst_signal`. The next
valid steps are:

1. frozen-rule holdout on unseen multi-thread negatives and interaction traces;
2. identify a lower-overhead event/signal source;
3. finish S2b to determine whether any scheduler action is causally justified;
4. only then connect a validated detector to a device-side controller.

## Example

Given a replay CSV matching `input-schema.csv`:

```sh
python tools/simulate-burst-controller.py replay.csv \
  --trigger-samples 2 \
  --min-hold-ms 20 \
  --max-boost-ms 50 \
  --cooldown-ms 30 \
  --thermal-gate-c 88 \
  --json
```

Those numbers are an invocation example, not a proposed production profile.
Controller parameters remain experimental until replayed against real workload
traces and then measured on-device.

## Boundary with the admission model

`tools/simulate-burst-policy.py` is a separate hypothesis-only performance
counterfactual. It originally asked what prime admission might look like
**if** clamp affected WALT placement by inflating `pred_demand` -- S2b has
since run and falsified exactly that identity (see FOLLOW-UP STATUS above),
so this simulator's predictions do not describe the mechanism S2b/S2c/S2d
actually found. This controller replay does not use that assumption. It
validates only control-state timing.

Do not wire either simulator or either S1 detector candidate into
`mitigation/op13perf/perfd.sh` before the C2/C4 holdout and real-app pilot
are complete.
