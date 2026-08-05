# Continuation prompt — OmniTerm → Flutter migration

Paste the block below to any agent picking this work up on this machine. It carries every standing
instruction given since the migration started; everything else lives in `MIGRATION.md`.

For Claude Code, prefix it with `/loop 15m ` to run it on a 15-minute repeating cycle.

---

```
Continue the OmniTerm → Flutter migration.

FIRST, orient yourself — do not start coding before this:
  - Read /home/sbvino/Omniterm/MIGRATION.md §22 (where the port stands), then §21 (the cut-over
    checklist — pick the next item from here), then §18 (per-screen gaps).
  - Read §23 (working agreements — five code conventions and the process rules), §19 (how to
    validate on a device here, and seven lessons about probes that lied), and §20 (the failure
    patterns from the Kotlin history, with a verdict for each).
  - §8 is the recovery procedure. The §14 progress log is the narrative of how things got here; it
    is history, not a to-do list.

ENVIRONMENT
  - Always `export PATH="/home/sbvino/sdks/flutter/bin:$PATH"` — Flutter is not on PATH.
  - Work on branch `migration-to-flutter`, from `/home/sbvino/Omniterm/flutter_app`.
  - The Kotlin app being replaced is at `app/` and is never deleted before cut-over; it is the
    reference for any behaviour question.

THE THIRTEEN REQUIREMENTS (the user's own words, recorded in MIGRATION.md §1)
  1.  Migrate everything — no feature left behind.
  2.  Keep the functionality, the layout and the architecture.
  3.  Truly multiplatform, with iOS first-class rather than an afterthought.
  4.  Research best practices before choosing an approach.
  5.  Keep going in a loop; if a usage or rate limit is hit, resume where the log left off.
  6.  End-to-end UI automation covering every feature.
  7.  Port the CI/CD pipeline.
  8.  Use the best open-source tooling.
  9.  Fix major bugs and design flaws found in the Kotlin while porting — do not carry them across.
  10. Modularise.
  11. Reuse and centralise; never duplicate.
  12. Security takes priority. The app warns rather than blocks.
  13. Feature parity, not code parity.

HOW TO WORK
  - One coherent iteration at a time. Each ends with: `flutter analyze` clean, `flutter test`
    passing, a §14 progress entry appended to MIGRATION.md, and a commit.
  - Never `git add -A`. `shared/` must stay untracked — stage explicit paths.
  - Never commit `integration_test/zz_probe_test.dart`; it is a temporary device probe and is
    deleted after every run.
  - Validate on a device before reporting that something works. A green host suite is not evidence
    that a screen opens. Batch validation into ONE emulator pass per iteration — the device runs are
    the expensive part.
  - Say what the device run did *and did not* prove. If something shipped without a device pass, put
    that in the progress entry so the next session knows what to check.
  - When a probe disagrees with a test, believe neither: measure from outside (a screenshot, or the
    server itself). Several "defects" here turned out to be the probe.
  - A defect found in the Kotlin is not finished until it is fixed on both branches: the port, and
    `fix/kotlin-parity-defects` (already open as PR #77 against main).
  - CI keeps the shape it had on the Kotlin `main` branch; Play publication uses repository secrets.
  - The debug build carries its own application id (`…app.flutter`) so it installs beside the
    shipped Kotlin app. Do not change the release id — cut-over replaces that app.

WRITING
  - Comments explain *why*, especially where this port deliberately differs from the Kotlin. If a
    decision was between two reasonable options, the comment says which was rejected and what it
    would have cost.
  - Progress entries record what was built, what was decided against, and what remains unproven.
    Do not describe something as verified unless it was.

If a usage or rate limit interrupts you, simply resume from the last progress entry.
```
