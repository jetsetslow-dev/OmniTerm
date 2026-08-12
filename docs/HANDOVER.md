# OmniTerm handover — Kotlin → Flutter parity migration

The single current status document. It supersedes `CLAUDE_HANDOFF_2026-08-09.md`,
`CLAUDE_STRESS_TEST_PROGRESS.md` and `E2E_STRESS_TEST_PROGRESS.md`, all deleted: the first is rolled
into this file, the other two described a Kotlin-era campaign (last updated 2026-07-18) whose open
items no longer exist.

`docs/PARITY_LEDGER.md` is the evidence record — one entry per defect with the Kotlin reference, the
fix, the gate results and the negative control. **The ledger is the authority; if the two disagree,
believe the ledger.** This file is the summary and the to-do list.

## 2026-08-11 live handover — resume here

This section is newer than the historical counts below. The worktree is intentionally dirty and
has **not** been committed or pushed. Preserve all existing edits and stage explicit paths only.
No test process is currently running; the reusable fixture containers are still up on the isolated
daemon `unix:///run/omniterm-test-docker.sock`.

### The WebDAV blocker is closed — the host suite is green on the phone

`artifacts/device-tests/20260811T081220Z_android_ZF62224F8K_host` — **all tests passed, no
warnings**, on the rooted Moto G6 (`ZF62224F8K`, Lineage Android 12 / API 32), driving real Docker,
Podman, SFTP, SMB, FTP **and WebDAV**. Two things were wrong, both in the lab rather than the app;
the ledger carries the full account.

- **The Alpine Apache WebDAV fixture could never write.** apr-util 1.6.4 ships no `apr_dbm_*.so`
  driver on Alpine 3.21, Alpine 3.22, `httpd:2.4-alpine` or Debian `httpd:2.4`, so `mod_dav_fs`
  could not open its lock DB — and `mod_dav` consults that DB on writes too, via its lock-null
  status query, so dropping `DavLockDB` only renames the 500. WebDAV is now served by
  `rclone serve webdav` from the same image, volume and `/fixture` base URL, running as the share
  user via `su-exec` on port 8080 with Compose mapping the host's 8082 onto it.
- **`test-hosts.sh verify` only ever proved reads.** A share that could not be written passed every
  lab gate. SMB, FTP and WebDAV now each do a write round trip in `verify`.

The old fixture is the negative control: the identical `curl -T` returned 500 before and 201 after.
Do not print or commit `scripts/test-hosts/.env`; the runner passes it via `--dart-define-from-file`
and records only the path.

```bash
FLUTTER_BIN=/home/sbvino/sdks/flutter/bin/flutter \
DOCKER_HOST=unix:///run/omniterm-test-docker.sock \
./scripts/flutter-device-test.sh --device ZF62224F8K --profile host --allow-warnings
```

### Defects found and fixed in this device pass

- Share start paths were discarded for FTP/WebDAV and nested SMB. `SftpViewModel.openShare` now
  uses `ShareClients.startPath`; a WebDAV `/fixture/nested/` unit guard fails on the old code.
- A new native SMB editor path first crashed because smbj's Bouncy Castle transitive dependency had
  been excluded. Flutter now explicitly pins `bcprov-jdk18on:1.85`, matching Kotlin.
- Android SMB had no `supportsTextEditing`, `readText`, or `writeText`. These now stream UTF-8
  through the native bridge and have a focused unit guard.
- FTP, WebDAV and native SMB registered stream completion after closing the producer, allowing a
  completion event to be missed. Completion is now registered before transfer starts.
- `SftpViewModel` created and leaked a new share client for every list/read/write. It now reuses one
  client through the browse/editor session and closes it once. The focused lifecycle/editor test
  passes.
- Native SMB emitted both a transfer-scoped `done` event and `endOfStream`; the delayed global end
  could terminate the next editor read. The redundant end was removed. Negative artifact:
  `20260811T074224Z_android_ZF62224F8K_host`; SMB read/save/reread and mutations subsequently pass.
- `ftpconnect` defaulted to MLSD without capability discovery; current vsftpd 3.0.5 returns 500.
  FTP now probes FEAT, prefers MLSD only when MLST/MLSD is advertised, and otherwise uses LIST.
  Negative artifact: `20260811T074451Z_android_ZF62224F8K_host`; FTP subsequently passes.
- WebDAV PROPFIND addressed `/fixture` and rejected Apache's 301 to `/fixture/`. Collection paths
  are now canonically encoded with a trailing slash. Negative artifact:
  `20260811T074848Z_android_ZF62224F8K_host`; listing/read subsequently pass.
- Code-editor Go-to-line disposed a dialog controller while its exit animation still rendered.
  A failing widget negative control was captured; the dialog now stores entered text without a
  prematurely disposed controller.

**These are now ledger entries 81–89**, each re-read against the current code first, with Kotlin
references where one exists. Two are parity gaps (81, 83); the other seven are defects in the port's
own share stack, which crosses a method channel and an event channel where Kotlin uses blocking JVM
streams — so no Kotlin comparison could have found them. Only driving the app against a real server
could, and did.

The full suite was rerun after these changes: 2,410 passing, replacing the historical 2,387. It has
since moved to **2,462** with ledger 90–100 and the focus-lifecycle guards.
`flutter analyze --fatal-infos` is clean across the whole app.

`dart format` had again been run at its default 80 columns, leaving 14 files formatted against a
gate that uses 100 — the CI format check reported `14 changed`. Reformatted at 100; it now reports
`0 changed`. This is the second occurrence of ledger 72, on a branch with no PR to catch it.

### Large fonts, syntax highlighting, and editor coverage

The physical-device 200% text negative sweep originally found 15 overflows: SFTP toolbar,
Compose/Infra resource titles, Shell prompt, SFTP/Infra bottoms, and landscape variants. Responsive
wrap/scroll/compact fixes are in the dirty worktree. The surface matrix exercises every route,
subtab and theme in portrait/landscape at the app's maximum 200% text setting. A previous run was
invalidated when the phone dozed; `scripts/flutter-device-test.sh` now wakes/unlocks the device and
forces/restores `stay_on_while_plugged_in` (using Magisk where required). The sweep has since been
rerun and passes; its one remaining finding became ledger 80. API 32 is extra evidence only:
AGENTS.md still requires API 34+, which the API 35 core run now supplies.

Deterministic, quota-free local tests now cover syntax selection/highlighting (YAML, shell,
comments, URLs, Unicode and malformed input), editor highlighting cutoff, wrap, find,
case-sensitive regex, replace-all, Go-to-line, 360dp at 200% text, SFTP full editor, Compose raw
YAML editor, read/save/discard/back/binary/sudo flows, and live SFTP/SMB/FTP/WebDAV read-save-reread.
They call repository fixtures only and consume no AI or external API quota.

### Repeatable lab and runners

- `scripts/test-hosts/docker-compose.yml` contains reusable password/key/encrypted-key/bastion/
  proxy SSH hosts, SMB/FTP/WebDAV shares, an isolated Docker 29 engine + SSH gateway, an isolated
  Podman 5.6 host, and committed Compose fixtures. The runtime engines cannot reach the developer's
  personal daemon.
- `scripts/test-hosts.sh up|verify|down` owns lifecycle and verification. Android reverse includes
  ports 21, 445, 8082, 2201-2206, proxy ports, and FTP passive ports 21100-21110.
- `scripts/flutter-device-test.sh --profile core|surface|host|all` records device/OS/toolchain
  identity, full command output, screenshots/platform logs and warnings under
  `artifacts/device-tests/<timestamp>_*`. It supports Android now and the same command with a booted
  iPhone simulator UUID on macOS; iOS execution is deferred until a Mac is connected.

### Toolchain and warning policy

Use latest **stable** everywhere unless a demonstrated incompatibility blocks it; beta/main belong
in a separate forward-compatibility lane, not the release baseline. Current dirty-worktree pins are
Flutter 3.44.9 (latest stable on 2026-08-11), AGP 9.3.1, Gradle 9.6.1, Kotlin 2.4.0, compile/target
SDK 37. Two evidence-backed holds remain:

- Flutter built-in Kotlin migration needs Flutter 3.47+, which is beta, while stable 3.44.9 cannot
  complete it. Four latest plugins still apply KGP and emit Flutter's migration warning.
- `build_runner` newer than 2.15.1 needs `meta >=1.18.3`, but Flutter 3.44.9 pins `meta 1.18.0`.

Do not suppress those warnings or claim a warning-clean build. The Java deprecation audit also found
exactly five warnings in latest `google_mobile_ads 9.0.0`, with no repository-owned Java compiler
warnings. Recheck upstream releases later; remove warnings by upgrading when compatible.

### Gates still required before completion

1. ~~Fix/rebuild/verify the WebDAV fixture and get `--profile host` green on `ZF62224F8K`.~~
   **Done** — `20260811T081220Z_android_ZF62224F8K_host`, all passed, no warnings.
2. ~~Run `--profile surface` on the rooted phone and confirm zero overflow/warning signatures at
   200%.~~ **Done** — `20260811T082511Z_android_ZF62224F8K_surface`, passed with no warnings. The
   sweep found one real defect first (ledger 80, the SFTP browser header at 200% landscape); the
   failing run `20260811T081441Z_android_ZF62224F8K_surface` is its negative control.
3. ~~Restart API 35 AVD `omniterm-api35` and run at least `--profile core`; API 35 is the mandatory
   modern-device evidence.~~ **Done** — `20260811T083355Z_android_emulator-5554_core`, 13 tests
   passed, no warnings. Avoid running the emulator, Gradle and fixture builds concurrently — the
   prior emulator was OOM-killed. This box has ~6GB free with the developer's own containers up, so
   the working order is: `flutter build apk --debug` first, **then** boot the AVD, then run the
   profile; the runner's build is incremental by then. The AVD and Xvfb `:99` are still running.
4. ~~Run `flutter analyze --fatal-infos`, full `flutter test`, and line-length-100 format check.~~
   **Done 2026-08-11** — clean / 2,410 passing / `0 changed`. Rerun after any further edit.
5. Run `git diff --check` and `git diff --cached --check`.
6. Before any final commit/push, AGENTS.md requires `./scripts/local-pr-check.sh --full`. State all
   platform exclusions exactly; plain opt-in-skipping instrumentation is not screen evidence.
   **Know its scope.** It covers the Kotlin app only — `test-release-version.sh`,
   `test-ci-gradle-gate.sh`, Gradle `testOpenSourceDebugUnitTest` + `testPlayStoreDebugUnitTest` +
   `lintOpenSourceDebug` + `lintPlayStoreDebug`, and a gitleaks scan over **all history**. It has no
   Flutter steps (`grep -c flutter` → 0); the Flutter equivalents live in
   `.github/workflows/flutter-pr-check.yml`, which triggers on `pull_request`.
   This is **not currently a gap in practice**: those three commands — `dart format --line-length
   100`, `flutter analyze --fatal-infos`, `flutter test` — are run by hand every slice, alongside
   device sweeps the workflow does not do. It only starts to matter if Flutter changes ever land
   without someone running them, so read "the required gate passed" as *Kotlin* passed, and quote
   the Flutter results separately, which this ledger already does.
   Budget time: a run left for 50 minutes was still inside the Gradle build when its timeout killed
   it.
7. Run the same runner on a macOS iPhone simulator when available. Linux cannot validate Xcode,
   CocoaPods, linking, permissions or native iOS integrations, so iOS remains explicitly deferred.

The first abandoned/doze artifact is
`artifacts/device-tests/20260811T071536Z_android_ZF62224F8K_surface`; do not cite it as coverage.

**Read the ledger's withdrawals as carefully as its entries.** Several claims in it were retracted
after the code contradicted them, and they are left visible on purpose — a retraction names the
reasoning that produced a confident wrong answer, which is more useful than the original.

---

## Where things stand

**113 defects closed, none open.** Thirty-three were added across 2026-08-11/12 (80–113): one from
the 200% surface sweep (80), nine from the live-fixture device pass (81–89), two on the terminal's
focus lifecycle (90, 91), five on platform-call arguments and dead settings (92–96), the backup
passphrase minimum in both apps (101), the tmux control-mode stale pane (102), the editor's Replace
button (103), overlapping SFTP mutations (104), the unbounded replica count (105), anonymous SFTP shares (106), share search (107), WebDAV modification dates (108), SSH failures parsed as output (109), the SSH session-limit exhaustion behind it (110), unrecorded auth failures (111), Infra's never-rendered error state (112) and the overflowing PIN dialog (113). Of the nine device-pass defects, two are parity
gaps against Kotlin and seven are in the port's own share stack, which no Kotlin comparison could
have surfaced.

**A live queue worth knowing about:** twelve error/empty widgets are referenced by no test at all
(listed in the ledger under defect 113). Defects 112 and 113 both came out of that class — a branch
nothing renders is a branch nothing has measured — and the emulator is a *large* device, so a small
phone in landscape at 200% text is the geometry that finds them.

**Nothing is open.** The device warning gate now carries a narrow allowlist for the one upstream KGP
warning and fails on anything else. The plugin upgrade behind that warning is **not available** — all
four plugins are already at their newest published versions, so the warning cannot be cleared from
this repository; re-check when a future Flutter actually refuses the build. The **control-by-control audit** is partway through 167 unlabelled Compose controls. 31 of those
carry a gate and were worked first, since a gating divergence is where defects 101 and 105 lived.
That pass is now complete: **two defects (105, 106), eight rows cleared on inspection, and one false
positive** — Monitor's missing `status == "online"` check, which turned out to be enforced once at
the source instead of per control. The fix for it was written, tested and reverted; the ledger keeps
the entry because following a control's gate without following the values that feed it is the failure
mode this audit is most exposed to.

The **unmatched** axis is also worked: 334 Compose controls had no Flutter peer by label, and
checking every distinctive word against the whole port reduced that to three real candidates. One was
a genuine missing feature — defect 107, share search — and the rest were wording. That axis is
closed. What remains is 136 unlabelled controls carrying no gate, the lower-yield tail.

The audit then moved **below the UI**: the same word-absence search over Compose's view-model and
data-layer functions. 344 public `AppViewModel` functions produced zero candidates, which is real
evidence the port is complete at that level; the `data/` package produced three, two of them naming
differences and the third the WebDAV parser behind defect 108. The lesson carried forward is that
name-level parity is now largely established, and the remaining yield is in **behaviour inside
functions that both apps have** — 108 was found by reading two parsers side by side, not by any
search.

Gates on
`migration-to-flutter`:

| Gate | State |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Flutter host suite | **2,513 passing** (2026-08-12) |
| `dart format --set-exit-if-changed --line-length 100 .` | passes |
| Device host suite, real fixtures | **passing** on the phone `ZF62224F8K` (`20260811T081220Z`) and — since defect 110 — on `emulator-5554` too (`20260812T023955Z`, exit 0, no unexpected warnings) |
| Device surface sweep at 200%, `ZF62224F8K` | **passing** — `20260811T082511Z_android_ZF62224F8K_surface` |
| API 35 core profile, `emulator-5554` | **24 passing**, Patrol included — `20260811T225648Z_android_emulator-5554_core`. Warning gate fails on an upstream KGP deprecation only; see the ledger note. |
| `./scripts/test-hosts.sh verify` | 18/18, now including write round trips |
| API 35 surface sweep + walkthrough | 8 passing |
| API 35 action suite (`app_actions_test.dart`) | 5 passing |
| Kotlin parity worktree suite | 516 passing, 0 failures |
| `gitleaks git --log-opts="--all"` | no leaks |

### The working method

**Review against code, never against docs.** A document saying a feature shipped, and a test
covering a function, both turned out to be entirely compatible with that feature being unreachable
by any user action.

That is the dominant defect class here — **not missing code, but unconsulted code** (defects 27, 31,
33, 38, 43, 44, 52, 63, 76, 77). Something was ported, unit-tested, and never wired to a button, a
gesture or a code path. Grep proves a symbol exists; only following the call chain proves it runs.
The purest case was defect 76: `pushSplit`, its method-channel handler, its `ShortcutInfo` builder
and its launch-intent extras were all written, and the only reference to any of it was its own
definition.

Four habits that repeatedly paid for themselves:

- **Negative controls.** Every fix carries a deliberate mutation showing its tests fail without it.
  This caught four tests that asserted nothing — one read `Theme.of` from `MaterialApp`'s own
  element and could not have failed; three were unreachable because `isPlayStoreDistribution` is a
  compile-time `false`.
- **Assert the mutation applied.** A control whose `replace` silently matched nothing reports "all
  tests pass" and proves the opposite of what it claims. Use `assert s.count(old) == 1` before
  mutating. This bit twice (ledger 75).
- **Write down what has *not* been verified.** Defect 66 existed only because entry 65 recorded the
  file editor's Back as "likely parity by construction" — an inference, flagged as unverified.
  Checking it found real data loss.
- **When a sweep and the code disagree, suspect the sweep.** A preset comparison reported 11
  differing commands; all 11 were extractor artifacts (escaping, multi-line concatenation, a
  "longest string" heuristic grabbing labels). One read as "Flutter only runs the first of four
  fallbacks" — serious, and entirely false.

A recorded *limitation* deserves the same scepticism as a recorded feature. Defect 62 asserted the
gated-save path was undrivable and needed "a harness rewrite larger than the fix"; the rewrite was
two helpers, and the claim survived two repetitions because it was plausible and nobody retested it.

---

## Repository state

### Branches and PRs

`main` is current: **#82, #83, #86 and #78 are all merged**, and there are **no open PRs**.

| PR | What | State |
|---|---|---|
| #82 | secret-scan baseline | merged — unblocked CodeQL, the release gate and the Room matrix, none of which had run since 5 Aug |
| #83 | consolidated 81 + 79 + 80 | merged |
| #86 | consolidated 84 + 85, **plus the bcprov pin fix** | merged |
| #78 | Kotlin fixes, including the parity fixes bundled in | merged |
| 79, 80, 81, 84, 85 | superseded | closed, each with the reason recorded |

**`migration-to-flutter` is not merged and gets no PR** until the migration is complete. It is
pushed and stays a branch.

### Worktrees

| Path | Branch | State |
|---|---|---|
| `/home/sbvino/Omniterm` | `migration-to-flutter` | the Flutter port; carries uncommitted slice work |
| `/home/sbvino/Omniterm-kotlin-parity` | `fix/kotlin-parity-defects` | clean — its work is merged via #78 |
| `/home/sbvino/Omniterm-consolidate` | `chore/consolidate-automated-updates` | clean, merged via #83 |

Never `git add -A` in the Flutter worktree: `shared/build/**` is tracked on some branches and leaks
into main-based commits. Stage explicit paths.

### Toolchain

- Flutter SDK at `/home/sbvino/sdks/flutter/bin` — **not on `PATH`**, must be exported
- JDK at `/opt/java/temurin-17`; Android SDK at `/home/sbvino/Omniterm/.android-sdk`
- API 35 AVD `omniterm-api35` as `emulator-5554`, under Xvfb `:99`
- API 36+ emulator images crash-loop on this box (bisected); API 35 is the modern target

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

# Device — any screen touched needs these. This runner also retains the complete output, exact
# device/OS/toolchain identity and platform logs under artifacts/device-tests/ (gitignored).
cd /home/sbvino/Omniterm
FLUTTER_BIN=/home/sbvino/sdks/flutter/bin/flutter \
  ./scripts/flutter-device-test.sh --device emulator-5554 --platform android

# On a Mac, boot an iPhone simulator and use its UUID. The same surface/action suite and evidence
# format applies; Flutter, Xcode command-line tools and CocoaPods must be installed.
./scripts/flutter-device-test.sh --device <booted-simulator-uuid> --platform ios
```

**A green host suite is not evidence a screen opens.** That rule exists because a crash shipped once
after JVM tests passed. Tests must assert on repository-controlled fixtures, never on whatever the
dev machine happens to be running.

### Bringing the emulator back

```bash
setsid Xvfb :99 -screen 0 1280x800x24 -ac > /tmp/xvfb.log 2>&1 < /dev/null & disown
ls /tmp/.X11-unix/            # expect X99 — check the socket, not the process
export ANDROID_SDK_ROOT=/home/sbvino/Omniterm/.android-sdk
DISPLAY=:99 setsid .android-sdk/emulator/emulator -avd omniterm-api35 \
  -no-snapshot-save -no-boot-anim -gpu swiftshader_indirect -noaudio \
  > /tmp/emulator.log 2>&1 < /dev/null & disown
```

**Do not `pkill -f` a pattern that appears in your own command line.** `pkill -f "Xvfb :99"` and
`pgrep -f gradlew` both matched the shell running them — the first killed it, the second produced a
wait loop that could never exit and thirty minutes of false "still running" reports.

### Gradle dependency verification

- `scripts/refresh-verification-metadata.sh --write` takes **~32 minutes** (measured): six Gradle
  invocations, each `--no-daemon` with `--refresh-dependencies`, two of them assembling. It is a
  pre-push check, not something to run in a loop.
- The targeted equivalent — `./gradlew :app:assembleOpenSourceDebug --write-verification-metadata
  sha256,sha512` with the daemon — takes **~32 seconds** and records the same artifacts. Iterate
  with this; run the script once before pushing.
- A local build needs a `debug.keystore` or it fails at `validateSigningOpenSourceDebug`. Generate
  it as CI does; it is gitignored:
  `keytool -genkeypair -keystore debug.keystore -storepass android -keypass android -alias androiddebugkey -dname CN=Android-Debug -keyalg RSA -keysize 2048 -validity 1`

---

## What the dependency PRs kept teaching

Three lessons, each of which cost a CI round-trip:

1. **A bump and its checksums must land together.** Dependabot opens them as two PRs and neither can
   merge first. Consolidating is the only order that works.
2. **Regenerating from dependency *graphs* is not enough.** Execution-time plugins (KSP, the
   roborazzi marker) resolve into detached configurations that `:app:dependencies` and
   `buildEnvironment` never report. `refresh-verification-metadata.sh` now runs a compile pass with
   the same `:app:assemble*` tasks as `ci-gradle-gate.sh` — **keep those two lists in step.**
3. **A `resolutionStrategy` pin silently discards a bump.** `build.gradle.kts` forced Bouncy Castle
   to 1.85, so the catalog change to 1.85.2 moved the declared version and nothing else. The version
   file would have claimed a security patch the app does not ship. **After a bump, check
   `dependencyInsight`, not the catalog.**

Both of that session's CI round-trips are now catchable locally: the compile-graph pass above, and
`scripts/local-pr-check.sh` running the secret gate the way CI runs it — `gitleaks git
--log-opts="--all"`, over **every ref** rather than `HEAD`'s ancestry, falling back to the pinned
Docker image and warning loudly rather than passing silently when neither is available.

---

## Axes closed

Evidenced in the ledger, so worth not re-deriving.

| Axis | Outcome |
|---|---|
| **Back handling** | all six Kotlin `BackHandler`s have counterparts (63, 65, 66) |
| **Confirmation dialogs** | 70 Kotlin sites vs 32; four gaps — two were missing *capabilities*, one was not missing at all (68, 69, 70) |
| **Long press** | five Kotlin sites; the real defect was a handler doing something *different* (67) |
| **Split terminal / multi-SSH** | closed (75, 76). Kotlin's host-picker checkbox flow is deliberately **not** reproduced — defect 75's sheet serves the same purpose, and both would be two ways to do one thing |
| **Settings keys** | 44 vs 37, accounted for key by key (78) |
| **Large text** | 21 overflow reports across 7 surfaces → 0 |
| **Empty / loading / error / offline states** | 53, 54, 55 |
| **Database columns** | 96 vs 101 — 0 missing |
| **Remote command tooling** | 27 vs 26 — no real difference |
| **Preset scripts** | 32 keys and all 20 comparable command bodies identical |
| **Colour** | app palette, terminal base palette and all five terminal themes identical |

---

## Still open

- **Kotlin-side change: unit-verified, not device-verified** (ledger 101).
  `BACKUP_PASSPHRASE_MIN_LENGTH` in the `fix/kotlin-parity-defects` worktree compiles
  (`:app:compileOpenSourceDebugKotlin`) and its unit suite passes
  (`:app:testOpenSourceDebugUnitTest`). **No device run** — the Kotlin app has not been installed
  and driven through the backup dialog since the change, and no handset is attached.
- **A twelve-digit PIN set in Flutter cannot be typed into Kotlin** (ledger 101). Kotlin's lock
  screen stops accepting digits at eight (`ui/AppViewModel.kt:3081`). Only bites a Flutter→Kotlin
  downgrade; recorded rather than changed, since Kotlin is being retired.

- **SSH compression: a capability Kotlin has and this port cannot** (ledger 94, 95). The switch no
  longer lies — it is shown disabled with the reason, and its stored value still round-trips — but
  dartssh2 proposes `compression: ['none']` and ships no zlib, so the app cannot compress at all.
  Nothing in this repository can change that; it needs a library that implements it. Listed here as
  a **capability difference**, not an open defect.
- **Podman runtime discovery failed once, unexplained** (ledger 94). Artifact
  `20260811T110727Z_android_ZF62224F8K_host`: the raw probe answered, `infra.load` returned an empty
  set, `infra.error` was null, and the next run of the same build passed. Not reproduced, not
  attributed.
- **Platform-call arguments — a live seam** (92, 93, 94). Two consecutive defects were inherited default
  arguments to plugin calls: the biometric prompt accepting the device credential, and secure
  storage deleting its key on a failed read. Neither is visible in behaviour, in a sweep of symbols,
  or in any test that only checks return values. **The named callers are now all read** (92–96):
  biometrics, secure storage, the SSH client (94, 95) and the clipboard (96). Link opening and the
  foreground service were read and found sound — url_launcher falls back to its own WebView where
  Kotlin falls back to the external browser, and `_syncBackgroundSessions` already mirrors Kotlin's
  keep-alive condition. One cosmetic difference is left unfixed and is *not* recorded as a defect:
  Kotlin's Custom Tab sets `setShowTitle(true)` and a toolbar colour; url_launcher defaults
  `showTitle` to false and offers no colour at all. **Read the plugin's defaults, not just the
  call.**
- **Accessibility, part-swept** (71, 73, 79, 90). Icon-only buttons are done and guarded by
  `test/accessibility_labels_test.dart`; terminal content, split-pane focus, health scores and the
  fleet refresh cadence are announced, and the read-only keyboard is fixed. **Three of the four
  items previously listed here were not defects** — `liveRegion` and focus order exist in neither
  app, and Kotlin's only `mergeDescendants`/`stateDescription` site is the terminal pane closed by
  79. See ledger 90. **The fourth item is not a defect either** — Kotlin's 117
  `contentDescription` values are all verbs on icon *buttons*, with 59 icons explicitly nulled, and
  Flutter matches on both halves. The axis is closed; what is left are *joint* enhancements under the
  scope rule, since neither app has them: `liveRegion` announcements and a considered traversal
  order.
- **Terminal focus lifecycle — closed** (ledger 90, 91, and the no-defect slice above 91). All four
  Kotlin sites are accounted for: two ported, one deliberately *not* ported (its reason is a Compose
  crash workaround, and porting it would drop the keyboard on every notification glance — there is a
  test that fails if anyone does), and one that reaches the same outcome by a different route
  (`ShellScreen.kt:2555`, the copy-dialog restore). **Nothing is left open on this axis.** Two of the
  four sites were real gaps; the other two were behaviours Flutter already had, where the work was
  proving it and leaving a guard.
- **Action-by-action semantics** — does each control do the same thing *to the host*? Not sweepable
  by grep; needs screens driven.
- **Spacing and layout.**
- **Patrol native tests now run and pass on the emulator** (5 tests): backup save/restore through
  the real system document picker, and the notification permission dialog. The androidTest wiring
  was never missing — the first execution simply found two stale taps that needed `scrollTo`.
  `--profile core` on `emulator-5554` is **27 tests** end to end.
  **Crash-log collection now has a device flow** — `integration_test/crash_log_test.dart`, passing
  on both the emulator and the phone; it reads the real clipboard back and asserts a planted
  password is redacted out of it.
  **The instrumentation blocker was the Moto, not the project.** A Galaxy S23 Ultra
  (`RZCW418XP4P`, Android 16 / API 36) runs Patrol fine — backup/restore through the real document
  picker now has evidence on hardware (`20260811T162650Z_android_RZCW418XP4P_core`, Patrol 2/3).
  Two things are outstanding there, both in tests rather than the app: the `app_actions` scroll fix
  is verified on the emulator but **not yet re-run on the S23** (now unplugged), and Patrol's
  `the picker is offered the file name` throws `StaleObjectException` from UiAutomator and needs a
  re-query. The Moto's `JNI_CreateJavaVM failed` is that handset's fault and is not worth more time.
- **Device profiles, rebuilt.** `core` = every integration test that does not need the lab,
  discovered recursively; Patrol files are split by content and run through the Patrol CLI. The old
  `core` ran three of eight files and `-maxdepth 1` hid `integration_test/native/` from every
  profile, which is how four failures and five never-executed tests went unseen. Run `core` on the
  **phone**, not only the emulator.
- **Action-level device coverage**, started not finished: five host-free flows in
  `app_actions_test.dart`. Anything needing a reachable host belongs in the lab suites. **Give every
  new flow a negative control** — a flow that only taps through screens passes whatever the app
  does.
- **`TERMINAL_COMPATIBILITY.md`, part-verified** (ledger 97). Five claims checked against the Dart
  emulator: OSC safely ignored (including OSC 52), mouse reporting absent, focus reporting absent
  and alternate screen 47/1047/1048/1049 all held; **bracketed paste did not** — the mode was
  tracked and never read (97); the hardware-keyboard row failed too — the encoder matched Kotlin
  exactly, but nothing told it which modifiers were held (98); and persistent tmux claimed
  capture-based history recovery that **does not exist in this port** (99, open).
  Verified sound since: soft-wrap reflow (13 tests, including hard newlines and wide glyphs),
  colours and attributes (all five render; 256 and truecolor SGR parse correctly, index
  consumption included), OSC, mouse, focus and alternate screen. Still unchecked: UTF-8 clustering
  and wide-cell reflow, tmux control framing, and the "regression minimum" list.
  **Three of the eight claims checked were wrong**, so the remainder are unverified, not fine.
- **Persistent tmux history recovery — ported** (ledger 99, closed). Capture, guards, scratch
  re-parse, adoption and the scroll-up trigger all landed together. **Not yet driven against a live
  tmux**: the fixture reattach is the missing evidence. `tmuxExitCopyModeCommand` has been removed —
  Kotlin's caller for it does not exist either, and the wheel-forwarding approach it belonged to was
  abandoned on both sides.
- **iOS** remains largely unexercised. `iosMain` cinterop compiles on Linux, but linking, tests and
  the native integrations need macOS.
- **`missing2.json` string queue** — ~297 plausible strings left, now low-yield; mostly wording
  variants of copy that exists.
- ~~`lib/platform/biometric_gate.dart` is a second, unused biometric implementation.~~ **Resolved as
  ledger 92, and it was a defect, not a hazard.** The wrong one was already wired: the live
  `BiometricAuth` accepted the device credential where Kotlin allows strong biometrics only. The
  live class now matches Kotlin and the duplicate is deleted. When a sweep finds two implementations
  of one thing, ask which is *correct*, not which is unused.

---

## Picking the next slice

The grep-able axes are largely exhausted: two consecutive slices found nothing, and the table above
is why. When sweeping anyway, the method that produced every recent defect is:

1. Pick a behaviour with a searchable marker on both sides — `BackHandler` vs `PopScope`,
   `confirm.ask` vs `showDialog`, `contentDescription` vs `tooltip`, `Toast` vs `SnackBar`.
2. Count both sides. **A gap in the counts is a lead, not a finding.**
3. **Compare by concept, not by string.** Half the apparent gaps are wording; a third of the real
   ones are missing *capabilities* rather than missing copy.
4. Follow the call chain before concluding.

The remaining value is mostly in work that cannot be diffed from source — the "Still open" list
above, in roughly that order.

Two things to be careful of:

- **Scope may now be added — in both apps.** The original rule was strict parity: twice a Flutter
  shortcoming had no Kotlin counterpart (an unlabelled host card, a colour-only status dot) and both
  were recorded as rejections rather than fixed. On 2026-08-11 the user relaxed this: *"I am ok for
  adding scope if it makes sense"*, and *"it should be added at both places"*. So an improvement
  neither app has may now be made — **but it must land in Kotlin as well as Flutter**, or it
  reintroduces the divergence this whole exercise exists to remove. Kotlin-side work goes in the
  `fix/kotlin-parity-defects` worktree at `/home/sbvino/Omniterm-kotlin-parity`.
  A genuine parity *defect* still outranks any enhancement, and the rejections above stay recorded
  as what they were: correct calls under the rule in force at the time, now re-openable as joint
  enhancements rather than as parity work.
- **`dart format` needs `--line-length 100`.** The default is 80, `flutter analyze` is silent about
  it, and the branch has no PR, so the gate that would catch it never runs (ledger 72).
