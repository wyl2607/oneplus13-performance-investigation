# R4 live holdout status

PRE_REGISTERED_MAIN_SHA=db14ee567e6ea778693491ddc110d968e82c5653
PLAN_SHA256=8fb9935f7fa059e146a8e64ae8ae2cdf076c23ea2918d65c1f6e331c7920a5c9

This branch (`experiment/r4-holdout-live`) carries live-device run
records and analyzer output only. It does not modify r4-plan.csv,
r4-plan.sha256, C2/C4 expressions or thresholds, workload labels, or
analyzer decision logic -- see the freeze rule in the PR description
and `experiments/burst-detector-holdout/LIVE_SESSION_CHECKLIST.md`.

## Session state

- Overhead validation: **done** (2026-08-27) -- see `overhead-2026-08-27/RESULT.md`.
  Verdict: 1-thread regime not OVERHEAD_LIMITED; 8-thread regime
  OVERHEAD_LIMITED (+5.6% wall-time, likely a conservative lower bound
  due to a disclosed methodology confound). HIGH_LOAD_OBSERVER_CONTAMINATION
  declared for the many-thread regime; does not stop the holdout, but
  steady_gameplay / steady_game_title must be reported as measured under
  a known-contaminating instrument regime.
- Smoke: not started
- Official 88-run holdout: 0 / 88 complete
- Analysis: not run
