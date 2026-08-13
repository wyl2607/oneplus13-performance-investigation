# Privacy — what is in this repository, and what was removed

This project publishes traces taken from a personal phone. Everything below was checked
rather than assumed.

## Deliberately kept — needed for reproducibility

`CPH2653` · `OP5D55L1` · `SM8750` · kernel and build version · fingerprint prefix · CFB module
`scmversion`. These identify a *model and firmware*, not a person or a handset.

## Removed before publication

| Item | Action |
|---|---|
| Local build paths containing a Windows username | replaced with neutral text |
| One third-party package name observed being clamped | generalised to "an unrelated third-party app" |
| Real application UIDs (`10xxx`, `10xxx`, …) | redacted to `10xxx` |

App UIDs plus thread names amount to a partial inventory of installed apps. The analysis only
ever needs to distinguish **app** (`uid >= 10000`) from **root/system** (`0`, `1000`), so
redacting the specific values costs nothing. `10999` is kept: it is a synthetic UID created
for the trigger experiments and corresponds to no installed app.

## Checked for and absent

ADB device serial · IMEI · Android ID · MAC addresses · IP addresses · account emails ·
API tokens · SSH keys · passwords · raw `bugreport` · shell history · Magisk configuration.

Verified across the **full git history**, not only the current tree:

```sh
for pat in <serial> <username> ghp_ github_pat_ "BEGIN.*PRIVATE KEY" password android_id; do
  git log --all -S"$pat" --oneline
done
```

The only history hits were the username and package name above, both introduced and later
removed by commits in this repository. They remain reachable in old commit objects.

## Raw logs are not published

`.gitignore` excludes `*.log`. `logcat` captures in particular can contain other applications'
private content and are never committed. What is in `data/` is filtered, per-thread scheduler
and frequency telemetry.

## If you contribute a report

`tools/collect-report.sh` and `tools/diagnose.sh` are read-only and collect no identifiers.
Redact UIDs above 10000 in anything you paste if you would rather not publish which apps you
have installed.

## History rewrite, and a disclosure

The published history was rewritten with `git filter-branch` before release. Two passes were
needed, and the second one was a mistake worth recording.

The first pass scrubbed the build path and the package name. It **missed the application
UIDs**, because those had only been redacted going forward by an ordinary commit — the earlier
commits still contained them. The repository was made public in that state and the UIDs were
briefly reachable in history before a second pass removed them and the branch was force-pushed
again.

Practical exposure: application UIDs are device-local integers. Mapping one back to a package
requires access to the device that produced it, so on their own they identify an app inventory
only to someone who already has the phone. No credential, serial, IMEI, account or network
identifier was ever committed — that was verified across the full history before publication
and again from a fresh clone afterwards.

Note that GitHub can keep unreferenced objects reachable by direct SHA for some time after a
force-push, so the pre-rewrite blobs may persist in its cache independently of the branch.

The lesson generalises: **redacting a string in the working tree does not redact it from
history**, and an audit that only greps the current checkout will report a clean tree over a
dirty history. Verify with `git log --all -S<string>` and from a fresh clone, not from the
working copy.
