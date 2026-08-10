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

**73 defects found and closed** (71 parity, plus two of my own making — see ledger 72), each against the Kotlin source rather than against
documentation. Current gates on `migration-to-flutter`:

| Gate | State |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Flutter host suite | **2,373 passing** |
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
| `main` | shipping Kotlin app | secret gate fixed; #83 and #78 in flight |
| `chore/secret-scan-baseline` | unblocked the secret gate | **PR #82 — merged** |
| `chore/consolidate-automated-updates` | PRs 81+79+80 combined | **PR #83 open** |
| `fix/kotlin-parity-defects` | Kotlin-side fixes found while porting | worktree at `/home/sbvino/Omniterm-kotlin-parity` |

### Worktrees on this machine

- `/home/sbvino/Omniterm` — Flutter, `migration-to-flutter`
- `/home/sbvino/Omniterm-kotlin-parity` — `fix/kotlin-parity-defects`, **has uncommitted work**
- `/home/sbvino/Omniterm-consolidate` — `chore/consolidate-automated-updates`, clean and pushed

Never `git add -A` in the Flutter worktree: `shared/build/**` is tracked on some branches and leaks
into main-based commits. Stage explicit paths.

### Toolchain

- Flutter SDK at `/home/sbvino/sdks/flutter/bin` — **not on `PATH`**, must be exported
- JDK at `/opt/java/temurin-17`
- API 35 AVD `omniterm-api35` as `emulator-5554`, run under Xvfb `:99`
- API 36+ emulator images crash-loop on this box (bisected); API 35 is the modern target

---

## Pending work

### 1. CI — unblocked (**PR #82 merged**)

`Secret scan` had failed on every branch since **5 Aug**, and because CodeQL runs after it, CodeQL,
the release gate and the Room migration matrix had not run at all in that time. PR #82 fixed it and
is merged; those gates now run.

The cause is worth keeping, because it is not obvious: the findings were **not on `main`**.
`actions/checkout` with `fetch-depth: 0` fetches every ref, so `gitleaks git` scans the whole
repository including `migration-to-flutter`, where they lived. Every `main`-based branch reported
them while carrying a `.gitleaksignore` that predated them.

**Scan every ref when verifying, not `HEAD`'s ancestry.** `gitleaks git` defaults to the current
branch's history; `main` is not an ancestor of `migration-to-flutter`, so a local "no leaks" result
proved less than it appeared to. Use `--log-opts="--all"`, which is what CI effectively does. That
mistake hid four findings *introduced by the fix itself* — PEM banners in doc comments, an assertion
pair, and the fixture's own serialiser.

None was ever a live credential. Both causes are fixed at source (keys generated per run by
`flutter_app/test/support/ed25519_fixture.dart`; banners built via `pemBegin`/`pemEnd`). History
cannot be fixed without a rewrite, which was rejected as disproportionate.

### 2. Merge order

1. ~~**PR #82** — secret-scan baseline.~~ **Merged.**
2. **PR #83** — the consolidated dependency PR (81 + 79 + 80, cherry-picked with `-x`, rebased on
   the new `main`, verification metadata regenerated and verified under Gradle 9.7.0). Secret scan
   passes; the rest was still running when this was written.
3. **Close PRs 79, 80 and 81** once #83 is green — not before, or working PRs are closed in favour
   of one that fails.
4. **PR #78** — `fix/kotlin-telemetry-quality`. Branch updated from `main` so it picks up the
   baseline; re-check its rollup before merging.
5. **`migration-to-flutter` is not merged and gets no PR** until the migration is complete.

PR 80's verification metadata was proven *insufficient* rather than merely stale, by reproducing the
`kotlin-reflect` failure locally. The consolidated branch regenerates it.

**Dependency verification hides work behind configurations you did not resolve.** Regenerating
locally still missed `com.google.devtools.ksp:symbol-processing-aa-embeddable:2.3.11`, which CI
resolves into a detached configuration at execution time — the same shape as the `kotlin-reflect`
gap, one layer down. `:app:dependencies` and `buildEnvironment` never report it; only an actual
compile does.

**Both of this session's CI round-trips are now catchable locally**, which is where they should have
been caught:

- `scripts/refresh-verification-metadata.sh` gained a compile-graph pass running the same
  `:app:assemble*` tasks as `scripts/ci-gradle-gate.sh`. Keep the two task lists in step — anything
  CI assembles must be resolved here, or the metadata is verified against a smaller graph than the
  one that ships.
- `scripts/local-pr-check.sh` now runs the secret gate the way CI runs it: `gitleaks git
  --log-opts="--all"`, over every ref rather than `HEAD`'s ancestry. It falls back to the pinned
  Docker image, and warns loudly rather than passing silently when neither is available.

### 3. Parity work still open

- **`missing2.json` string queue** — ~297 plausible user-facing strings left, but now low-yield;
  most are wording variants of copy that exists. Axis sweeps have been finding more (defect 63 came
  from diffing `BackHandler` against `PopScope`).
- **Unswept axes** from the original handoff: action-by-action semantics, spacing and colour.
- **Candidate defect, not yet confirmed: split-pane host selection.** Kotlin's connect list carries
  a checkbox per host for choosing the two hosts that open into split panes, with a stateful
  accessible label — *"Add nas to split panes"* / *"Remove nas from pane 2"* (`ui/AppUi.kt:211`).
  Flutter can split (`splitWith`, and the `open_split` external action in `main.dart`), but only
  between sessions that are **already connected**; no equivalent picker was found in the connect
  sheet. Read Kotlin's host-list sheet in full before building anything — this was found from the
  accessibility sweep, so the label is confirmed and the surrounding flow is not.

- **Accessibility is part-swept** (ledger 71, 73). Icon-only buttons are done and guarded by
  `test/accessibility_labels_test.dart`, and the terminal content is now announced. Still open:
  non-interactive icons that convey state, `Semantics` grouping on composite rows (a host card
  announces as separate fragments), focus order, and `liveRegion` for state changes. (Long press and confirmation dialogs are now swept — see below.)
- The dialog sweep is **finished** (ledger 68–70). Of four gaps, two were missing *capabilities*
  rather than missing prompts, and one was not missing at all. **Check the underlying action before
  assuming only the prompt is absent** — that is what the axis actually taught.
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
- **Confirmation dialogs** — swept and closed (defects 68, 69, 70). Kotlin has 70 `confirm.ask` sites to Flutter's 32;
  comparing the destructive ones by concept left four gaps, one closed and three listed above.
- **Long press** — swept (defect 67). Kotlin has five sites; four had counterparts, the fifth
  carries no behaviour, and the real defect was a handler doing something *different*.
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

# ALWAYS pass the width. CI uses this exact command; plain `dart format` defaults to 80 and
# silently reformats the whole repository to the wrong style (ledger 72).
dart format --output=none --set-exit-if-changed --line-length 100 .

# device sweeps — any screen touched needs these
flutter test integration_test/app_surface_stress_test.dart \
             integration_test/app_walkthrough_test.dart -d emulator-5554
```

**A green host suite is not evidence a screen opens.** That rule exists because a crash shipped once
after JVM tests passed. Anything touching a screen gets the API 35 sweep.

Tests must assert on repository-controlled fixtures, never on whatever the dev machine happens to be
running.
