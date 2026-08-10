# OmniTerm handover — Kotlin → Flutter parity migration

This is the single current status document. It supersedes `CLAUDE_HANDOFF_2026-08-09.md`,
`CLAUDE_STRESS_TEST_PROGRESS.md` and `E2E_STRESS_TEST_PROGRESS.md`, all of which have been deleted:
the first is rolled into this file, and the other two described a Kotlin-era campaign (last updated
2026-07-18) whose open items no longer exist.

`docs/PARITY_LEDGER.md` remains the detailed evidence record — one entry per defect, with the Kotlin
reference, the fix, the gate results and the negative control. This file is the summary and the
to-do list. **The ledger is the authority; if the two disagree, believe the ledger.**

---

## Where things stand

**66 parity defects found and closed**, each against the Kotlin source rather than against
documentation. Current gates on `migration-to-flutter`:

| Gate | State |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Flutter host suite | **2,364 passing** |
| API 35 surface sweep + walkthrough (`emulator-5554`) | 8 passing |
| Kotlin parity worktree suite | 512 passing, 0 failures |
| `gitleaks git`, full history | no leaks |

### The working method, and why it matters

The single most productive rule has been: **review against code, never against docs.** A document
saying a feature shipped, and a test covering a function, both turned out to be entirely compatible
with that feature being unreachable by any user action.

That is the dominant defect class in this migration — **not missing code, but unconsulted code**
(defects 27, 31, 33, 38, 43, 44, 52, 63). Something was ported, unit-tested, and then never wired to
a button, a gesture or a code path. Grepping for a symbol proves it exists; only following the call
chain proves it runs.

Two habits that repeatedly paid for themselves:

- **Negative controls.** Every fix carries a deliberate mutation showing its tests fail without it.
  This caught four tests that asserted nothing — including one that read `Theme.of` from
  `MaterialApp`'s own element and so could not have failed, and three that were unreachable because
  `isPlayStoreDistribution` is a compile-time `false`.
- **Writing down what has *not* been verified.** Defect 66 existed because entry 65 recorded the
  file editor's Back as "likely parity by construction" — an inference, flagged as unverified.
  Checking it found real data loss. Had it been written as a conclusion it would have been inherited
  silently.

Three ledger entries were withdrawn or corrected after the code contradicted what had been written.
Those corrections are left visible in the ledger rather than edited out.

---

## Repository state

### Branches

| Branch | Purpose | State |
|---|---|---|
| `migration-to-flutter` | the Flutter port | **pushed, no PR** — stays a branch until migration completes |
| `main` | shipping Kotlin app | 3 open dependency PRs blocked on CI |
| `chore/secret-scan-baseline` | unblocks the secret gate | **PR #82 open** |
| `chore/consolidate-automated-updates` | PRs 81+79+80 combined | built and verified locally, **not pushed** |
| `fix/kotlin-parity-defects` | Kotlin-side fixes found while porting | worktree at `/home/sbvino/Omniterm-kotlin-parity` |

### Worktrees on this machine

- `/home/sbvino/Omniterm` — Flutter, `migration-to-flutter`
- `/home/sbvino/Omniterm-kotlin-parity` — `fix/kotlin-parity-defects`, **has uncommitted work**
- `/home/sbvino/Omniterm-consolidate` — `chore/consolidate-automated-updates`, **has an uncommitted
  `gradle/verification-metadata.xml`**

Never `git add -A` in the Flutter worktree: `shared/build/**` is tracked on some branches and leaks
into main-based commits. Stage explicit paths.

### Toolchain

- Flutter SDK at `/home/sbvino/sdks/flutter/bin` — **not on `PATH`**, must be exported
- JDK at `/opt/java/temurin-17`
- API 35 AVD `omniterm-api35` as `emulator-5554`, run under Xvfb `:99`
- API 36+ emulator images crash-loop on this box (bisected); API 35 is the modern target

---

## Pending work

### 1. CI is red everywhere, and one PR fixes it — **PR #82**

`Secret scan` has failed on every branch since **5 Aug**. CodeQL runs after it, so **CodeQL, the
release gate and the Room migration matrix have not run at all since then.** PR #78 is `BLOCKED` on
exactly this.

The cause is not obvious and is worth recording: the findings are **not on `main`**.
`actions/checkout` with `fetch-depth: 0` fetches every ref, so `gitleaks git` scans the whole
repository including `migration-to-flutter`, where the six findings live. Every `main`-based branch
reports them while carrying a `.gitleaksignore` that predates them.

None was a live credential — three throwaway Ed25519 test keys and three bare PEM banners. Both
causes are fixed at source on `migration-to-flutter` (keys generated per run by
`flutter_app/test/support/ed25519_fixture.dart`; banners assembled at runtime). History cannot be
fixed without a rewrite, which was rejected as disproportionate.

### 2. Merge order

1. **PR #82** — secret-scan baseline. Nothing else can go green first.
2. **The consolidated dependency PR** — `chore/consolidate-automated-updates` (PRs 81 + 79 + 80,
   cherry-picked with `-x`, verification metadata regenerated and verified under Gradle 9.7.0). Not
   yet pushed. Rebase on `main` after #82 lands, then open it.
3. **Close PRs 79, 80 and 81** once the consolidated PR is green — not before, or working PRs are
   closed in favour of one that fails.
4. **PR #78** — `fix/kotlin-telemetry-quality`. `MERGEABLE` but `BLOCKED`; should unblock once #82
   lands.
5. **`migration-to-flutter` is not merged and gets no PR** until the migration is complete.

PR 80's verification metadata was proven *insufficient* rather than merely stale, by reproducing the
`kotlin-reflect` failure locally. The consolidated branch regenerates it.

### 3. Parity work still open

- **`missing2.json` string queue** — ~297 plausible user-facing strings left, but now low-yield;
  most are wording variants of copy that exists. Axis sweeps have been finding more (defect 63 came
  from diffing `BackHandler` against `PopScope`).
- **Unswept axes** from the original handoff: action-by-action semantics, dialog/confirmation
  wiring, long-press menus, accessibility labels, spacing and colour.
- **Defect 62's coverage gap** — the settings-save security gate's *wiring* is untested. A live
  `AppLockController` keeps a timer, so `pumpAndSettle` never quiets, including in the harness's own
  setup. The gate's input is covered, the ungated path is covered, the join is not.
- **`TERMINAL_COMPATIBILITY.md` is unverified against Flutter.** It documents the Kotlin renderer's
  contract. The Flutter emulator may or may not match; nobody has checked. Treat it as a Kotlin
  document until someone does.
- **iOS** remains largely unexercised. `iosMain` cinterop compiles on Linux, but linking, tests and
  the native integrations need macOS.
- **Task "action-level device coverage for gaps found"** was never finished.

### 4. Known-good axes

Closed and evidenced, so worth not re-deriving:

- **Back handling** — all six Kotlin `BackHandler`s now have counterparts (defects 63, 65, 66).
- **Large text** — 21 overflow reports across 7 surfaces reduced to 0.
- **Empty / loading / error / offline states** and platform-specific branches (53, 54, 55).

---

## Running the gates

```bash
export PATH="/home/sbvino/sdks/flutter/bin:$PATH"
export JAVA_HOME=/opt/java/temurin-17
cd /home/sbvino/Omniterm/flutter_app

flutter analyze --fatal-infos
flutter test

# device sweeps — any screen touched needs these
flutter test integration_test/app_surface_stress_test.dart \
             integration_test/app_walkthrough_test.dart -d emulator-5554
```

**A green host suite is not evidence a screen opens.** That rule exists because a crash shipped once
after JVM tests passed. Anything touching a screen gets the API 35 sweep.

Tests must assert on repository-controlled fixtures, never on whatever the dev machine happens to be
running.
