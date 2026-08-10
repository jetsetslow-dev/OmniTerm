# Continuation prompt — OmniTerm Kotlin → Flutter parity migration

Paste the block below into Claude Code. Status and pending work live in `docs/HANDOVER.md`; the
per-defect evidence lives in `docs/PARITY_LEDGER.md`.

```text
Continue the OmniTerm Kotlin→Flutter parity migration per docs/HANDOVER.md and
docs/PARITY_LEDGER.md. Read the ledger for current state, pick up the next open defect, fix it, add
tests, and re-run the required gates (flutter analyze --fatal-infos, flutter test, and the API 35
device sweeps on emulator-5554 for any screen touched). Update docs/PARITY_LEDGER.md with evidence.
Do not commit or push. Do not reset, clean, stash or bulk-stage either worktree. Keep each turn
short — finish one slice, report, and stop. If several identical prompts have queued up, treat them
as one.
```

## Standing rules

These are the ones that were learned expensively; the handover explains why.

- **Review against code, never against docs.** A doc claiming a feature shipped is not evidence, and
  neither is a passing unit test — the dominant defect class here is code that exists, is tested,
  and is never reached.
- **Every fix carries a negative control.** Mutate the fix and show the new test fails. A control
  that cannot fail is not evidence, and four vacuous tests were caught exactly this way.
- **Record what was *not* verified**, explicitly, rather than rounding an inference up to a
  conclusion. Defect 66 was found only because 65 flagged an unverified guess.
- **A green host suite is not evidence a screen opens.** Anything touching a screen gets the API 35
  sweep. This rule exists because a crash shipped after JVM tests passed.
- **Fix defects in both implementations.** Kotlin fixes go in the `fix/kotlin-parity-defects`
  worktree at `/home/sbvino/Omniterm-kotlin-parity`.
- **Never `git add -A`.** `shared/build/**` is tracked on some branches; stage explicit paths.
- Both non-Flutter worktrees hold uncommitted work. Do not reset, clean, checkout, stash, rebase or
  bulk-stage them.

## Environment

- Flutter worktree: `/home/sbvino/Omniterm`, branch `migration-to-flutter`
- Kotlin parity worktree: `/home/sbvino/Omniterm-kotlin-parity`, branch `fix/kotlin-parity-defects`
- Flutter SDK: `/home/sbvino/sdks/flutter/bin` — **not on `PATH`**, export it
- JDK: `/opt/java/temurin-17`
- Device: API 35 AVD `omniterm-api35` as `emulator-5554`, under Xvfb `:99`. API 36+ images
  crash-loop on this host.
