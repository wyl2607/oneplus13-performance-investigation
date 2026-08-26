# Adaptive burst controller — offline control design

Status: **control-state simulation only; no performance claim and no device write**.

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
counterfactual. It asks what prime admission might look like **if** S2b proves
that clamp affects WALT placement. This controller replay does not use that
assumption. It validates only control-state timing.

Do not wire either simulator or either S1 detector candidate into
`mitigation/op13perf/perfd.sh` before S2b and holdout validation are complete.
