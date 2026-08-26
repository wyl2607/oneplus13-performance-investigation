# Geekbench 7 reproducibility harness

This directory defines the host-side part of a repeatable two-arm Geekbench 7
comparison. It is deliberately useful before a phone is connected: run order,
CSV schema, validation and statistics can all be developed and tested offline.

The problem it addresses is already measured in this repository. A shipped
configuration produced 1054 and 978 in two same-evening runs, a 7.5% spread,
while an apparent 2--5% ceiling effect disappeared under alternating
replication. A single higher score is therefore not evidence for a tuning
change.

## 1. Generate the run order

```sh
python3 tools/make-gb7-repro-plan.py \
  --blocks 4 \
  --arm-a control \
  --arm-b candidate \
  -o /tmp/gb7-plan.csv
```

The sequence alternates `ABBA` and `BAAB` blocks. Four blocks produce 16 runs,
eight per arm. Each block has two runs from each arm, which makes slow drift
less able to look like an arm effect.

## 2. Record results

Start from `results-schema.csv` or merge the generated plan with the same
columns. The required analysis fields are:

- `run_id`, `block`, `order`, `arm`
- `single_score`, `multi_score`

Optional fields are currently understood by the analyser:

- `initial_junction_c`, `peak_junction_c`
- `prime_residency_pct`
- `walt_demand_p50`
- `wake_p50_us`

Do not invent a missing measurement. Leave the cell empty and keep the
corresponding conclusion `TODO: unmeasured`.

A future device-side collector may fill these columns, but this host-side
framework does not launch Geekbench, write a kernel node, change uclamp, or
alter a performance profile.

## 3. Analyse

```sh
python3 tools/analyze-gb7-repro.py results.csv
python3 tools/analyze-gb7-repro.py results.csv --json
```

The primary comparison is the distribution of **within-block B - A means**.
The tool reports a two-sided 95% Student-t interval over those block effects.
It also reports a Welch interval over all individual runs as a secondary view.

Default verdict rule:

- `PASS`: paired effect is at least +3% and its 95% interval is above zero.
- `REGRESSION`: paired effect is at least -3% and its 95% interval is below zero.
- `INCONCLUSIVE`: everything else, including fewer than two complete balanced
  blocks.

`--min-effect-pct` changes the practical-effect threshold. Statistical
separation alone is intentionally not enough: a tiny repeatable difference can
still be irrelevant for a profile decision.

The analyser warns if mean initial junction temperature differs by more than
2 C between arms. That warning does not correct a thermal confound; it marks
the run for review.

## Scope

This harness decides whether a candidate changed the measured score under the
recorded conditions. It does not by itself establish the kernel mechanism.
Scheduler placement and uclamp questions remain separate causal experiments.
