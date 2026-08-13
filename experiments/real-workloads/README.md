# Real-workload harnesses

**Status: measured 2026-08-14.** The hypothesis this directory was built to test was that
sustained single-threaded app work — compile, decompress, video export — would behave like the
Geekbench single-core phase and gain from lifting the clamp.

**It does not.** See [`docs/DATA.md`](../../docs/DATA.md) sections 31, 32 and 34.

| Workload | Shape | Expected | **Measured** |
|---|---|---|---|
| `gzip -9`, single process, 30 s | sustained | affected | **not affected** — 1.4%, p~0.47 |
| App launch, scroll, short burst | < 2 s | not affected | not affected (section 20) |
| Video export / transcode | sustained | affected | still unmeasured |

The clamp *fires* on the gzip workload exactly as predicted — up to 81.5% of samples carry
`uclamp.max = 466` — but prime residency stays 98.9–100% in both arms. The guard clamps it and
never displaces it, so it costs only frequency.

Section 32 explains why: **displacement happens at wakeup**. A task that never sleeps keeps the
prime core it was already on. Geekbench's pool workers sleep between subtests and are re-placed
constantly, every time against a clamped utilisation.

The larger finding came from the third arm. URCC's cluster inversion — the device's stock
screen-on state — costs **39.7%** against the uclamp guard's **9.5%** (section 34). This
repository spent its effort on the smaller of the two limiters.

> The previous version of this file said "An expected result is not a result. Do not promote the
> middle column." That was right, and the middle column turned out to be wrong.

## Read the traps first

These harnesses produced wrong or unsafe results three times before they were trusted.
[`docs/METHODOLOGY.md`](../../docs/METHODOLOGY.md):

- **Trap 6** — the sampler ran on cpu6/7, which share a frequency domain with the workload, and
  held the clock at max in the *control* arm. Fixing it moved the measured effect from 6.8% to
  1.4%. Harnesses now `taskset -p 3f $$` and hand the workload `taskset ff`.
- **Trap 7** — `pgrep -f <marker>` matches `su`'s own command line, and `su` drops to the app
  uid, so the probe monitored an idle parent and returned a confident false null. Probes now
  validate that the target is *burning CPU*, not just that it can be read.
- **Trap 8** — a cooldown that timed out let a trial start at 69 °C; the junction reached
  104.6 °C against a 105 °C trip. Gates are now blocking, the sensor is sub-sampled at 50 ms, and
  the operating point is the mildest that still exercises the mechanism.

Also: the guard **de-duplicates on `(uid, comm)`** (section 33). A probe that reuses a process
name silently under-reports, and a null from one is not evidence.

## The test input, and how to restore it

The workload is `gzip -9` over a fixed **908 MiB** file. Two files are involved:

| File | Size | What it is |
|---|---|---|
| `gzsrc.dat` | 34 MiB | the seed corpus, `base64` of `/dev/urandom` |
| `big.dat` | 908 MiB | exactly **28 concatenated copies** of `gzsrc.dat` |

```
gzsrc.dat  md5 36384e218609ab330e90cd48aa69071b   33995938 bytes
big.dat    md5 5c85ba019ff07ae433e48db19dcf4f30  951886264 bytes
```

`big.dat` is a pure function of `gzsrc.dat`, so keeping the 34 MiB seed preserves
**byte-identical** reproduction of the 908 MiB input. Neither file is in git — 908 MiB is far
past what belongs in a repository, and 34 MiB would bloat every clone. The seed is kept
off-device at `C:\Users\yzwdm\oneplus13-testdata\gzsrc.dat`.

### Restore

```
adb push C:\Users\yzwdm\oneplus13-testdata\gzsrc.dat /data/local/tmp/gzsrc.dat
adb push tools/restore-testdata.sh /data/local/tmp/restore-testdata.sh
adb shell su -c "sh /data/local/tmp/restore-testdata.sh"
```

It rebuilds `big.dat` and verifies both checksums, refusing to proceed if either differs.

### If the seed is lost

`gzip-prep.sh` regenerates one from `/dev/urandom`. **It will not be the same file.**
Within-session A/B comparisons stay valid — both arms always compress the same bytes — but
absolute wall times will not be comparable to sections 31 and 34, because compressibility
differs between corpora. Re-baseline before comparing across sessions.

## Why the input is shaped this way

- **One long-lived single-threaded process.** Not a pipeline: a `cat` partner adds a second
  runnable thread to what is fundamentally a *placement* measurement. Not a loop of short
  processes: each starts unclamped, and the ~5 s clamp latency of section 27 is never reached.
- **908 MiB in one pass** rather than a small file compressed repeatedly. At gzip's 18 MiB/s that
  is ~30 s in a single process, and I/O demand stays two orders of magnitude below UFS
  sequential read, so the workload is CPU-bound.
- **`base64` text, not raw random bytes.** Deflate abandons incompressible input quickly; base64
  carries enough redundancy that match-search does real work.
- **Run under an app uid.** Root and system are exempt (section 27), so a root workload cannot
  reproduce what an app experiences.

## Script status

| Script | Status |
|---|---|
| `ab-real-workload.sh` | ran — section 31 |
| `ab-inversion-cost.sh` | ran — section 34, three arms |
| `probe-selftest.sh` | ran — validates the sampler against a `uclampset` positive control |
| `placement-vs-sleep.sh` | ran — section 32, with a stated utilisation confound |
| `placement-vs-sleep-v2.sh` + `worker.sh` | **not yet run to completion** |
| `gzip-prep.sh`, `calibrate.sh` | input construction and sizing |
| `compile.sh`, `decompress.sh`, `video-export.sh`, `common.sh` | older harnesses, never executed |

`placement-vs-sleep-v2.sh` removes section 32's confound. Matching a sleeping task against a
100% spinner is impossible by construction, so instead it compares two variants matched on
*utilisation* that differ ~10x in *wakeup rate*, sleeps without forking (`read -t` on a fifo so
both variants match on process-creation rate), and measures wakeups directly from
`voluntary_ctxt_switches` rather than assuming them.

`data/real-workload/placement-vs-sleep-v2.txt` is the **aborted** first attempt and contains no
usable placement result — two trials thermally aborted and the third was cut short. Trap 8 is
written against it. Do not read numbers out of it.

## Preconditions

Screen on. Cool start — and the gate must block, not warn. Record ceilings before *and during*:
URCC reclaims the pinned ceiling ~28 s into a loaded run, so harnesses re-assert at 2 Hz and
count per-sample violations. Do not `sed -i` the scripts on the device (trap 5). If you point a
script at a real package rather than uid 10999, force-stop it first so a previous clamp does not
ride in through the thread pool.
