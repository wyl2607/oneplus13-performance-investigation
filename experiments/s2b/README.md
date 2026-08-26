# S2b experiment specification — uclamp.min and WALT prime admission

Status: **design only; TODO: unmeasured**.

S2a measured a demand-dependent crossover in prime first-run share. The old
planned `uclamp.min` matrix (128 / 256 / 384) sits below the interesting region,
so S2b should first answer a narrower causal question:

> Does raising a foreground worker's requested minimum utilisation high enough
> change WALT's cluster search / misfit decision and therefore prime admission?

This directory contains no claimed device result. It is the protocol to run
when a device is available again.

## First comparison

Start with the smallest contrast that can falsify the lever:

- A: `uclamp.min = 0`
- B: `uclamp.min = 512`

Use an alternating `ABBA` / `BAAB` order and at least four blocks before adding
more values. If 512 moves the causal placement fields, later experiments can
map 640 and 768. If it does not, do not silently widen the sweep and call the
whole mechanism disproven: inspect effective uclamp at enqueue and WALT's own
fields first.

`arms.csv` records the planned values. Every result field is intentionally blank
until measured.

## Required event-level evidence

For each wake/placement cycle, preserve enough information to derive:

1. requested/effective `uclamp.min` at or immediately around enqueue;
2. WALT task util / predicted demand;
3. `sched_find_best_target` start cluster and candidate mask;
4. enqueue `misfit` state where exposed by the trace;
5. selected CPU and first-run CPU;
6. wake -> first-run latency;
7. migrations before first run;
8. initial and peak junction temperature for the arm/run.

`cycles-schema.csv` defines the first offline interchange schema. One row is one
wake/placement cycle, but a cycle is **not** treated as an independent
experimental replicate.

The result should distinguish these hypotheses instead of collapsing them into
one score:

- **H1:** requested `uclamp.min` changes the utilisation WALT uses for placement;
- **H2:** the request is present but the placement calculation ignores it;
- **H3:** requested and effective clamp differ at the decision instant;
- **H4:** prime admission changes, but wake latency or temperature cost makes the
  setting unsuitable as a general burst policy.

## Offline analyzer

`tools/analyze-s2b.py` reduces cycle rows to **run-level summaries first**, then
computes B-A effects within blocks and a 95% Student-t interval across blocks.
This is deliberate: hundreds of wakes in one run share the same thermal,
background-load and scheduler state, so treating every wake as an independent
trial would create pseudoreplication and overstate significance.

Example once data exists:

```sh
python tools/analyze-s2b.py experiments/s2b/results.csv
python tools/analyze-s2b.py experiments/s2b/results.csv --json
```

The mechanism gate can return:

- `PLACEMENT_EFFECT` — effective clamp separated, prime first-run share cleared
  the practical gate, and at least one causal placement field (start cluster or
  candidate mask) moved with it;
- `CLAMP_NOT_SEPARATED` — requested arms existed but the effective clamp at the
  decision instant did not separate enough to test the mechanism;
- `NO_DETECTED_PLACEMENT_EFFECT` — effective clamp separated, but the prime
  effect stayed below the practical threshold;
- `INCONCLUSIVE` — too few complete blocks or the interval still crosses the
  decision boundary.

Defaults are intentionally conservative: at least two complete A/B blocks are
needed for any settled classification, the practical prime-share gate is 10
percentage points, and the effective-clamp separation gate is 128. The actual
device protocol still asks for at least four alternating blocks before changing
any profile.

The analyzer also warns when average initial junction temperature differs by
more than 2 C between arms or when a run contains fewer than 20 wake cycles.

## Relationship to the offline admission model

`experiments/walt-prime-model/` contains a descriptive model of the existing S2a
burst sweep. It estimates the **measured WALT demand -> prime admission**
crossover, not the `uclamp.min -> WALT demand` link. S2b is what decides whether
that missing link exists.

The model therefore cannot be used as evidence that 512 will work. It is useful
only for choosing an experiment that crosses the region S2a showed to be
interesting and for checking whether a later S2b result is qualitatively
consistent with the old demand sweep.

## Safety / scope

S2b is not a production-profile change. It should live on an experiment branch
until the device run is replicated and reviewed. Do not change Daily,
Performance or Extreme values from this protocol.

The eventual device-side harness should restore the previous requested clamp on
exit and on INT/TERM. The offline code added in this phase performs no device
writes.
