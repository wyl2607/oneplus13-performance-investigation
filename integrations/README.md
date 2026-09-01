# Upstream performance backends

This directory integrates external Android performance projects as **separate experimental backends**. No GPL-licensed upstream source is vendored into this MIT repository.

The goal is to reuse mature upstream components where they are stronger than the local implementation while keeping this repository's evidence-first experiment harness, device-specific OPlus limiter knowledge, thermal gates, cleanup verification, and stock restore as the safety boundary.

Initial candidates:

- `shadow3aaa/fas-rs` — frame-aware scheduling / eBPF frame signal.
- `imacte/yumi` — event-driven Rust daemon, FAS and CPU load governor.
- `reigadegr/thread-opt` — game-thread classification and affinity experiments.
- `KonaBess-Next/KonaBess-Next` — GPU calibration reference; not a runtime backend.

## Integration policy

1. Third-party projects remain separately installed and separately licensed.
2. This repository talks to them through adapters or experiment hooks; it does not copy their GPL source into the MIT tree.
3. No backend is allowed to become a boot-time default merely because it benchmarks well.
4. Every comparative run must identify the active backend, verify expected state, enforce the local thermal gate, and verify cleanup before another arm starts.
5. A backend can replace a local component only after repeated A/B evidence on the target device shows a measurable advantage and no regression in idle power, thermals, recovery, or compatibility.

## Planned ownership split

| Capability | Preferred source | Status |
|---|---|---|
| OPlus limiter diagnosis (URCC/CFB/task_overload) | local | keep |
| thermal fail-safe / stock restore | local | keep |
| experiment plans, randomisation, analysis | local | keep |
| frame signal / FAS | fas-rs or yumi | evaluate as replacement |
| low-overhead CPU-load signal | yumi | evaluate as replacement |
| game thread classification | thread-opt | evaluate as helper |
| GPU voltage/frequency calibration | KonaBess-Next | external lab tool |
| production policy engine | local adapter layer | keep until evidence supports replacement |

The next implementation step is a host-side backend runner with four arms (`stock`, `op13perf`, `fas-rs`, `yumi`) plus optional `thread-opt`, all feeding the same run schema.
