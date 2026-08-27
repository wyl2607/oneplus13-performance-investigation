# R4 live session checklist

Read this immediately before starting a real 88-run holdout session with
`tools/run-r4-holdout.py` (no `--simulate`). Everything here must be true
before the first run, not fixed up after a failure partway through.

## Before starting

- [ ] Phone physically present and USB cable stable for the expected session
      length (all 88 runs, plus any thermal cooldown waits, in one sitting --
      checkpoint/resume exists for interruptions, not as a reason to plan on
      one).
- [ ] `adb devices` shows the phone as `device`, not `unauthorized` or
      `offline`.
- [ ] Screen unlocked and ON. The driver will pause and re-prompt if it finds
      the screen off before a run, but starting unlocked avoids the first
      pause.
- [ ] Charging state recorded (plugged in vs battery) -- write it down; it is
      not currently captured automatically and a charging-state change
      mid-session is a confound worth knowing about after the fact.
- [ ] No pending app updates or background installs on the device (Play
      Store auto-update, OS update, etc.) -- any of these can steal CPU/IO
      mid-run and are exactly the kind of unmarked confound
      `docs/METHODOLOGY.md`'s traps warn about.
- [ ] Thermal baseline acceptable: junction temperature well under the 92 C
      soft gate before run 1. A device that starts hot spends the first
      several runs in cooldown waits instead of collecting data.
- [ ] `experiments/burst-detector-holdout/app-manifest.local.csv` exists and
      every slot (`APP_A`..`APP_D`) has a real, installed package filled in
      (copy `app-manifest.example.csv` if it does not exist yet).
- [ ] `mitigation/op13perf` is installed and its daemon is running (module
      list shows it active) -- the runner controls it by writing
      `/data/adb/op13perf/state` and verifying `/data/adb/op13perf/status`;
      if the daemon is not running, every run will report
      `MODULE_SET_FAILED` and the session will stop after run 1.
- [ ] Phase 7's overhead validation (`OVERHEAD_VALIDATION.md`) has been run
      at least once on this device and its result is on hand to annotate the
      final report, even if it flags `steady_gameplay`/`steady_game_title` as
      `OVERHEAD_LIMITED`.
- [ ] Gameplay / video / download content prepared for the four
      HUMAN_ASSISTED workloads (see below) -- know in advance what game,
      what video, and what download you will use, so the pause prompt is not
      the first time you think about it.

## Human-assisted workloads

The driver automates 7 of the 11 workloads end-to-end (`app_launch_cold`,
`app_launch_warm`, `app_switch`, `browser_scroll`, `camera_launch`,
`synthetic_compute`, `synthetic_wake`). It **pauses and waits for you** on
these 4, once per run each repeat touches them (4 repeats x 2 module states
= 8 pauses per workload, 32 total):

- `steady_game_title` -- have a real game ready to bring to its title/menu
  screen.
- `steady_gameplay` -- have a real game ready to play, if the device/session
  time allows it; separate from the title-screen capture above.
- `video_playback` -- have local or streamed video ready to play.
- `background_download` -- have a real download or sync ready to start,
  with the foreground app staying on something stable.

At each pause the driver prints `PREPARE_WORKLOAD <id> (run <run_id>)` and
the workload's `notes` from `workloads.csv`, then waits for Enter. Typing
`skip` marks that run invalid (kept, replaced later, never silently
dropped) and moves on; typing `abort` stops the whole session cleanly.

## During the session

- [ ] Do not touch the device except to satisfy a `PREPARE_WORKLOAD` prompt
      or a screen-unlock prompt.
- [ ] If the terminal running the driver needs to be interrupted (Ctrl-C,
      laptop sleep, etc.), that is fine -- `session-state.json` checkpoints
      after every run. Resume with the same command; it will not re-run or
      overwrite anything completed.
- [ ] A `SESSION STOPPED` message means exactly that: a boost-exit /
      module-verify failure, a hard thermal breach, or an operator abort.
      Do not immediately re-run with `--acknowledge-stop` without first
      reading the reason and, for `CLEANUP_VERIFY_FAILED` or
      `MODULE_SET_FAILED`, manually confirming the device is actually clean
      (`experiments/r3-real-app/check-uclamp.sh`, `cat
      /data/adb/op13perf/status`) before trusting it again.

## After the session

- [ ] Record the final `session-state.json` counts (`completed` / `invalid`)
      in the R4 report alongside the plan's sha256 and the runner's commit
      SHA (both already stored in `session-state.json`).
- [ ] Run `tools/analyze-r4-holdout.py` and fill in the human-only fields of
      its `final_verdict_template` (`device_clean`, `pr_url`, `verdict`) by
      hand -- the analyzer deliberately leaves these null.
