# Kotlin / Flutter reliability review — temporary branch tracker

Updated: 2026-09-13 at 10:34 AM IST, after the cutoff. Working branch: `migration-to-flutter`; PR: #92.
Outgoing Codex session retired for handoff; **not** a parity-complete or release-ready declaration.

This sanitized tracker is intentionally committed so work can resume on another machine.
Before an authorized merge to `main`, consolidate it into the private handover under
`secrets/internal-docs/docs/` and remove this temporary file from the merge tree. Never put
secrets here: moving it later does not erase Git history.

## Resume here

**Codex-to-Claude handoff cutoff: September 13, 2026 at 10:30 AM IST today (05:00 UTC), not tomorrow.**
Implementation stopped before cutoff. The external cutoff fired at 10:30:00 IST and queued
finalization at 10:30:01; private handover finalized at 10:32, then this public summary was corrected
after the queued cutoff message arrived. Both outgoing continuation and cutoff timers are now
verified disabled/inactive, with successful delivery and no retry pending. Operational details:
`secrets/internal-docs/docs/CLAUDE_HANDOFF_2026-09-13.md`.
Stale `continue` messages must not restart implementation or recreate the retired schedule. This is a
handoff, not a claim that the whole review is complete. Claude must return an equivalent detailed
handover and a ready-to-use prompt for Codex to independently review and finalize the codebase.
The cutoff retires the outgoing Codex session; it does not forbid Claude's subsequently authorized
continuation from the handover.

**Claude session resumed from that handover on 2026-09-13.** It did not revive the retired Codex
schedule. Claude Code has no external, session-targeted `queue` command equivalent to the Codex
adapter in `AGENTS.md`, so its 30-minute `continue` schedule runs on the client's own in-session
scheduler instead of a `systemd --user` timer. That is a real weakening of the requirement and is
recorded rather than glossed: the schedule does not survive the client process exiting, and it fires
only while the session is idle. Everything else in the continuation rules is unchanged.

### Final checkpoint and CI snapshot

- Signed/pushed source checkpoint and actual PR head:
  `b691ddd5ea66beebcdcfd3cd347b14216a4f88ee`, signature G. Worktree was clean at 10:33 IST.
  This final documentation-only correction to `WORK_PROGRESS.md` is intentionally uncommitted;
  no production/test edits remain. Preserve it for the incoming agent's next validated checkpoint.
  Do not supersede still-running exact-head CI merely to publish a final status correction.
- At 10:33 IST, native Build & Test and release SBOM succeeded; Room still running in run
  `34738906013` (Room job `103675867004`). Flutter Analyze/Test, Android release/SBOM and iOS
  succeeded; emulator still running in run `34738905988` (job `103675128133`).
- CodeQL run `34738905986` reported success but actual Analyze Java/Kotlin job `103675129381`
  was **skipped**. Only the no-code-change placeholder succeeded, despite native paths in the
  detector's changed-file list. This is an unresolved security-gate bug, not CodeQL coverage.
  The `echo "$changed" | grep -qE ...` detector under `pipefail` can reject an early match when
  the writer receives SIGPIPE. A controlled small-pipe regression reproduced that mechanism;
  default local runs did not reproduce it. Fix/test the detector and audit equivalent workflows.
- Dependency review (`34738905957`), Scorecard analysis (`34738905964`) and both secret scans
  (`34738905962`, `34738904792`) succeeded; separate Scorecard check neutral. Unselected docs-only
  companions are skipped, not platform passes. Detailed new CI test counts remain to be audited.
- PR remains REVIEW_REQUIRED and incomplete. A read-only exact-head watcher remains active;
  its private service/log/recovery details are in the handover. Even a successful watcher exit
  cannot prove the skipped real CodeQL analysis ran. Inspect actual jobs and terminal results.
- No Claude launch, merge, release, test termination or protection changes. The incoming agent
  must finish the CI/security gate and remaining work below and leave a reciprocal Codex handover.

1. Read `AGENTS.md`. Inspect `git status`, `git log -5`, and the remote branch before editing.
2. Check PR #92's **actual head SHA** and all its checks. Signed checkpoints `64d8e23` and
   `925ae3c` were pushed; the latter reconciles `main` (`bf227d2`) into this branch without changing
   the validated source. All `925ae3c` checks finished, but three jobs failed (details below).
   Replacement CI-repair checkpoint `500f35d` was signed and pushed. Native Build & Test, API 29
   Room, native release SBOMs, CodeQL, dependency review, Scorecard analysis, both secret scans,
   Flutter analysis/tests, Android/iOS builds and emulator testing passed. All selected jobs on
   that exact head reached terminal success; the separate Scorecard result is neutral. Skipped
   jobs are unused docs-only companions, not missing platform gates. Never infer CI success from
   local results or reuse these results for the next source checkpoint. Later SSH checkpoint
   `85f5cfe` had one terminal Flutter surface failure. This checkpoint contains the locally
   validated swipe/runner repair below; its replacement exact-head CI must still be monitored.
3. Preserve the existing fixes. Finish the remaining investigations below in small batches; run
   the required validation, update this tracker, commit with signing enabled, push, and monitor
   every selected check to completion before publishing the next replacement head.
4. For an incoming agent, keep its own session-targeted continuation active while work remains,
   as required by `AGENTS.md`. Re-establish it on a replacement machine using that client's own
   verified mechanism; local timers do not survive loss of the original host.

Useful read-only recovery commands:

```sh
git status --short
git log -5 --oneline
gh pr view 92 --json headRefOid,statusCheckRollup,reviewDecision
gh run list --branch migration-to-flutter
```

The earlier `925ae3c` merge conflicts were only in `AppUi.kt` and `AppViewModel.kt`: preserve visible recovery
feedback, transport-generation ownership/cancellation, and batched recovery persistence. All
incoming hotfixes were already present. Before this tracker-only edit, the resolved merge tree
was byte-identical to checkpoint `64d8e23` (tree `44ac3dc54ff8690544e4a36d00abab5a1a33647a`).
That merge changed no build-affecting source. The newer SSH setup batch below has its own validation.

## Change-detector repair — CodeQL was never analysing this PR

`b691ddd` is now terminal on every selected check and every one of them reports success, but
**`Analyze Java/Kotlin` passed in 3 seconds**: that is the `analyze-skip` companion no-op, not
CodeQL. The `Detect code changes` job (run `34738905986`, job `103675118702`) listed
`app/build.gradle.kts` and 525 further `app/` paths in its own log and still set `code=false`,
so the real analysis job `103675129381` was skipped. The green checks list was hiding the fact
that no security analysis had run on this branch at all.

**Cause.** All three PR detectors decided with `if echo "$changed" | grep -qE '<include paths>'`
under `set -uo pipefail`. `grep -q` exits at its *first* match and closes the pipe. Once the
changed-path list is longer than grep's first read, the producing `echo` is killed by SIGPIPE
(141); `pipefail` reports the pipeline as 141 even though grep matched, the `if` takes the else
branch, and a build-affecting PR is classified as docs-only. The longer the PR, the likelier the
required analysis silently disappears.

**Reproduction.** A default local run does *not* reproduce it — `b691ddd`'s real list is 28,959
bytes across 580 paths, just under the buffer where it tips. Feeding the same detector a matching
path followed by 40,000 further paths reproduces it deterministically on GNU grep 3.12
(`PIPESTATUS` `141 0`, pipeline 141, `code=false`); the threshold on that host is between 16 KB
and 48 KB of changed paths. Note the local host's `grep` in some interactive shells is `ugrep`,
which does not reproduce this at any size — reproduce with `/usr/bin/grep`.

**Fix.** `codeql.yml`, `android-pr-check.yml` and `flutter-pr-check.yml` now write the changed-path
list to a file and match the file, so there is no pipe and no producer to kill. `grep` status 0 is
a match, 1 is genuinely no match, and anything above 1 is a real error that fails safe to
`code=true` exactly like the existing `git diff` failure path — previously a broken pattern or
unreadable input would also have been read as "nothing changed". `mktemp`/write failures fail safe
the same way. Behaviour is otherwise unchanged: include prefixes stay anchored, and `push`/
`schedule` still force `code=true` so the main prerelease gate never skips.

**Regression test.** `scripts/test-change-detectors.sh` extracts the *real* `run:` block out of each
workflow (failing loudly if an unsupported `${{ }}` expression appears in one) and executes it
against a stubbed `git`, so it tests the shipped detector rather than a copy. 39 checks across the
three detectors: matching path first in a 40,000-path list; a deliberately non-draining matcher,
which pins the behaviour independently of the host's grep; matching path last; the 580-path shape of
the head that actually skipped CodeQL; docs-only; include prefixes still anchored (`docs/app/...`
must not trigger); paths containing spaces, matching and not; an empty diff; `git diff` failure;
`grep` error; and `push`/`schedule`/`workflow_dispatch` on CodeQL. It also fails if the
`echo … | grep` shape reappears in a workflow.

**Negative control.** The same script run against the unfixed `HEAD` detectors fails 12 of 39 —
the SIGPIPE case and the grep-error case, in all three workflows, each returning the production
symptom `code=false` for a genuinely matching list. The other 27 checks pass on the old code, so
the suite is targeted rather than vacuous.

The test is wired into `scripts/local-pr-check.sh` and into the same "validate tooling" steps that
already run `test-release-engine.sh` in `codeql.yml`, `android-pr-check.yml` and
`flutter-pr-check.yml`; `test-change-detectors.sh` was added to the Flutter detector's own include
list so changes to it can trigger that gate. A detector job cannot catch its own false negative
(if it skips, the test skips with it), but `push` to `main` always sets `code=true`, so the
prerelease gate always executes it.

**This does not mean CodeQL has now passed.** It means the next pushed head is the first one whose
`Analyze Java/Kotlin` result can be believed. Until a real analysis job runs to completion on the
replacement head, this branch has no CodeQL coverage.

#### Validation for this tree

`./scripts/local-pr-check.sh --full` **passed** with `flutter` and `adb` on PATH and
`JAVA_HOME=/opt/java/temurin-17`. An earlier attempt exited 1 before the `--full` section purely
because `flutter` was missing from that run's environment — a harness error, not a result.

- Change-detector suite **39 passed / 0 failed**; the negative control against the unfixed detectors
  fails **12 of 39**, all three workflows, each returning the production symptom `code=false`.
- Flutter full suite **2676 passed / 4 optional live skips** — 3 `OMNITERM_SETUP_FIXTURE`
  setup-relay cases and 1 `OMNITERM_COMPRESSION_*` case, both needing a disposable OpenSSH fixture.
  `flutter analyze` clean in 6.5s.
- Native unit tests, **freshly executed** this run (not reused UP-TO-DATE results): each variant
  560 discovered = **558 passed / 2 skipped / 0 failures / 0 errors**. Both skips are
  `TmuxAltScreenReplayTest` capture cases (`no capture dir provided`); captures are unavailable on
  this host. No ARM discovery exclusion applies on x86_64; required CI still executes Robolectric.
- Flutter release APK + App Bundle, both release SBOM graphs, release test-code exclusion and
  strict forced-fresh dependency verification passed. No checksum metadata changed.
- Full-history secret scan: 200 commits, 14.97 MB, no leaks.
- **The connected device matrix actually ran this time** rather than being deferred:
  `connectedOpenSourceDebugAndroidTest` on API 35 `emulator-5554`, **58 tests = 24 passed /
  34 skipped / 0 failures**. Every one of the 34 is an opt-in `E2e*` case self-skipping through
  `assumeTrue` because its instrumentation arguments were absent. That explicitly includes
  `E2eAppSurfaceStressTest`, so **this run is not the required route/subtab/theme/rotation sweep**.
  It is not re-run here because this checkpoint changes no application source — only workflow YAML,
  `scripts/local-pr-check.sh` and a new test script. `b691ddd`'s device evidence still stands for
  the app itself.
- `git diff --check` and `git diff --cached --check` both clean.

## tmux preflight — a dead connection offered to install a package

Two defects in `ShellViewModel.connect`'s tmux availability probe, both found by reading the
transport contract rather than the tests.

**1. A returned error read as a definite "tmux is missing".** `DartSshTransport.exec` reports
failure by *returning* `'SSH Error: …'`, not by throwing — the codebase already knows this in
`telemetry_poller`, `infra_view_model`, `tmux_bootstrap` and `ssh_failure.dart`. But `_hasTmux`
caught only *thrown* errors and otherwise did `answer.trim().endsWith('yes')`. A refused
connection, a timeout or a rejected key therefore became a confident "not installed", and the app
offered to install a package over a link that did not exist. `parseTmuxCheck` now returns `bool?`
— `yes`/`no` definite, a returned `SSH Error:`, an empty answer or anything unrecognised
unverified — mirroring `parseTmuxSessionProbe`, which had the shape right all along. Only a
definite `false` raises the install prompt; `null` lets the connection report the host's real
failure. It reads the last non-blank line, so a login banner before the answer is fine, and a word
merely *ending* in "yes" no longer counts.

An unverified probe is also no longer written into `_tmuxVerified`. The old code cached a thrown
probe as "present", so one flaky moment silently disabled the check for the rest of the session on
the exact host that needed it.

**2. The probe ran outside the attempt it belonged to.** It awaited a full round trip to the host
with `_connecting` still false. There was no busy state, so a slow probe was indistinguishable from
a tap that did nothing; `cancelConnect` had nothing to cancel and a late answer could raise a
prompt for a connection the user had abandoned; and the `if (_connecting) return` guard at the top
of `connect` could not see it, so a second tap during the probe started a second full connection.
It now runs inside the owned attempt/generation boundary with a `Checking for tmux…` phase, and a
superseded or cancelled probe returns without touching the newer attempt's state.

`installTmuxAndConnect`'s post-install re-probe now requires a definite yes: an unanswered probe is
not evidence the install worked.

**Tests.** 5 `parseTmuxCheck` cases (definite answers, banner before the answer, returned transport
errors, empty/unrecognised, and the `endsWith` trap) and 5 new `ShellViewModel` cases. The fake
transport gained an `execGate`, matching its existing `gate` for `openShell`, so a probe can be
held in flight while the busy state, double-tap guard and cancellation are observed.

**Negative control.** All 5 new view-model tests fail against the unfixed view model, each with the
production symptom: the install prompt raised on a refused connection; `isConnecting` false while
the probe is pending; two probes from two taps; a prompt raised after `cancelConnect`; and a thrown
probe cached as verified so the second connection never asked again. The 6th case in that group is
a pre-existing test renamed — its old name asserted "assumes tmux is there", a mechanism that no
longer exists — and it passes both ways, as it should. An earlier draft of the caching test passed
on unfixed code for the wrong reason and was rewritten until it genuinely failed.

### Validation for this tree

`./scripts/local-pr-check.sh --full` passed (`rc=0`); both diff checks clean.

- Flutter full suite **2686 passed / 4 optional live skips** (2676 + the 10 new cases), same 3
  `OMNITERM_SETUP_FIXTURE` relay skips and 1 `OMNITERM_COMPRESSION_*` skip. `flutter analyze`
  clean in 6.3s. Focused run of the four affected files: 112 passed.
- Native unit tests were **reused UP-TO-DATE, not freshly executed** — this checkpoint changes no
  Kotlin. Required x86_64 CI executes them.
- Flutter release APK + App Bundle, both release SBOM graphs, release test-code exclusion and
  strict forced-fresh dependency verification passed. Full-history secret scan: 201 commits, no
  leaks.
- **Device profiles on API 35 `emulator-5554`, run before the heavy gate:** `core` **30 passed /
  0 skipped** (25 Dart across 9 entrypoints, every one first attempt with no retries, + 3 native
  backup-picker + 2 native permissions), `host` **2 passed / 0 skipped** (1 Dart fixture + 1 native
  "SSH survives Home and explicit background; tmux leaves and resumes the same shell", 151s). No
  unexpected warnings (16 known on core, 6 on host).
- The emulator was stopped for the heavy gate, so `local-pr-check`'s own in-script connected matrix
  reported **deferred, not passed**. The explicit `core`/`host` profiles above are the device
  evidence for this change. Normal Flutter debug launcher rebuilt, reinstalled and reopened
  (`COLD 2817ms`).

## SSH setup checkpoint (`85f5cfe`) — pushed; one exact-head CI failure

Signed and pushed `85f5cfe7392caafa4afdd249f635456a06777916`; all selected checks are terminal.
Native Build & Test, release SBOMs, API 29 Room/backup (7 tests), CodeQL, dependency review,
Scorecard analysis, both secret scans, Flutter analysis/tests, release artifacts/SBOMs and iOS
passed. Flutter emulator failed: the surface sweep expected Builder after a swipe but remained
on Stacks (`app_surface_stress_test.dart:203`). Exact job `103606496057` logs were inspected;
the locally validated repair follows below. No unchanged failed workflow rerun. The replacement
head must pass its own checks before PR #92 can be described as green.

Separately, a new API 35 Activity-recreation guard failed for the expected reason:
the replacement Activity owns a different Flutter engine. Its Dart Home/background/tmux flow
passed, but final native JUnit result is **1 failure / 0 skips**, not a pass. Production engine
retention is not fixed yet. The guard currently proves engine identity, not a live shell during
recreation; that stronger fixture test is still required. The failing guard is preserved privately
as a patch, not included in the swipe repair tree before its production ownership fix exists.

### Swipe/runner checkpoint (`b691ddd`) — signed/pushed; local validation complete, CI incomplete

The deterministic paused-swipe guard failed on API 35 with unchanged production gesture code:
the selected offline host stayed on Stacks instead of opening Builder. Flutter required nonzero
release velocity; Kotlin uses deliberate distance. The repair follows Kotlin's 96 logical-pixel
threshold and 2.2 horizontal/vertical ratio, once per gesture, while retaining nested-scroll gesture
ownership. Eight focused widget cases and existing navigation tests passed (**32 / 0 skipped**).
Expanded navigation/Infra/widget validation passed **71 / 0 skipped**, analyzer clean.
The first API 35 core run passed all 25 plain Dart cases (including the full surface sweep) and
3 native backup picker cases. It then stopped before the 2 native permission cases: Patrol's
optional update lookup hit a network reset. This was **28 passed / 2 unstarted**, not a passing
core profile, and the host/full gate were not reached. Normal debug launcher restoration passed.
The device runner now invokes the pinned Patrol CLI in its supported CI mode with analytics off,
matching hosted execution and avoiding optional update-service dependence. A new isolated runner
guard failed on the old invocation for that exact missing environment, then passed with the fix;
it also proves a real Patrol test failure propagates unchanged without retry. Both local preflight
and required native CI already execute this same runner regression script.
The replacement API 35 core run passed **30 / 0 skipped** (25 Dart, 3 native backup picker,
2 native permission cases); fixture-host run passed **2 / 0 skipped** (Dart fixture + native
Home/background/tmux). No unexpected warnings. `./scripts/local-pr-check.sh --full` **passed**:
Flutter **2,676 passed / 4 optional live-test skips**, analyzer clean. Native unit/lint tasks reused
Gradle's up-to-date results for unchanged native source; they were not newly executed in this run.
The reused native results contain **558 passed / 2 optional tmux replay skips per variant**,
560 discovered, zero failures/errors. The four Flutter live skips have separate earlier evidence
for unchanged SSH code, not new execution in this batch. No Linux ARM64 discovery exclusion applies
on this x86_64 host.
Fresh strict dependency/compile verification, both native release SBOM graphs, Flutter APK/AAB/SBOM
and release test-code exclusion passed. No checksum metadata changes. Full-history secret scanning
passed. The emulator was deliberately stopped for the heavy gate: its in-script device matrix was
deferred, not counted as passing. Separate API 35 Room afterward: **4 passed / 0 skipped**. Normal
Flutter debug launcher rebuilt/reinstalled/reopened successfully. Both diff checks and the staged
secret scan passed before signing/pushing `b691ddd`; remote branch and PR head were verified.
Monitor every selected exact-head job and fix the CodeQL false skip; do not infer CI success.

### Validation for the prior SSH deadline checkpoint (`85f5cfe`)

- Reproduced two indefinite Flutter setup waits: a loopback peer accepted TCP but never sent an
  SSH banner, both directly and as a bastion. Both new guards failed on the unfixed transport.
- Added a 15-second network budget per authentication and bastion-forwarding stage. It pauses only
  around the actual host-key decision; the existing 120-second approval limit stays intact.
  Trust-store reads/writes remain bounded. Failed setup closes its owned connections, suppresses
  late approval prompts/answers, and retires late forwarding channels without retrying requests.
  Bastion forwarding has its own visible phase, and returned timeout errors retain the failed stage.
- Final focused Flutter tests: **60 passed / 0 skipped**, including eight deterministic clock/trust
  tests, four real loopback socket cases and the explicitly enabled live-compression test.
  Analyzer clean. Real repository OpenSSH relay tests:
  **3 passed / 0 skipped** — delayed approval beyond 15 seconds, stalled authentication and stalled
  forwarding. No fixture daemon/network configuration was changed by these tests.
- New Kotlin counterpart guards use real JSch and loopback sockets, replacing only Android-backed
  trust storage with a fail-closed in-memory store. Final focused run: **2 passed / 0 skipped per
  variant**. No native production behavior changed in this batch.
- API 35 Flutter `host`: **2 passed / 0 skipped** (one Dart fixture case and one native Patrol
  Home/background/tmux lifecycle case). `surface`: **1 passed / 0 skipped**, all routes/subtabs,
  themes and rotations. No unexpected warnings; normal debug launcher restored afterward.
- The first full-validation wrapper stopped before the gate because its restricted PATH lacked
  `rg`; this was not an app/test failure or a passing gate. The corrected wrapper completed
  `./scripts/local-pr-check.sh --full`, then the separate API 35 Room matrix (**4 passed / 0 skipped**),
  and rebuilt/reinstalled/reopened the normal Flutter debug launcher successfully.
- Full gate: Flutter **2,668 passed / 4 optional live-test skips**, analyzer clean; native unit
  suites each **558 passed / 2 optional tmux replay skips**, 560 discovered, no failures/errors.
  This x86_64 host executed the Robolectric classes; there was no ARM discovery exclusion here.
  The four Flutter skips are the three setup fixture cases and one compression case, all separately
  enabled and passed above. The two native replay captures remain unavailable, not passing.
- Strict fresh dependency verification, release APK/AAB builds, native/Flutter SBOM graphs and
  release test-code checks passed. The owned emulator was intentionally stopped during the heavy
  gate, so its in-script connected matrix was deferred, not counted as passing; separate runtime
  and Room evidence is listed above. The new head still needs its own API 29 migration/platform CI.
- The above local validation belongs to `85f5cfe`; repair the failed surface gate and validate
  the replacement final tree before its own signed checkpoint. No merge or release is implied.

The three new live setup tests are opt-in in the ordinary unit suite. Run
`flutter test test/dartssh_setup_live_test.dart` with `OMNITERM_SETUP_FIXTURE=yes` and privately
loaded `OMNITERM_TEST_USER` / `OMNITERM_TEST_PASSWORD` from the repository fixture configuration.
They use only the fixed loopback fixture ports. Report these default skips separately from the
existing optional live-compression test; neither is default unit-suite coverage.

## CI repair checkpoint (`500f35d`) — local and exact-head CI validation completed

All selected jobs finished successfully: native Build & Test, API 29 Room/backup tests (7 cases),
both native release SBOM graphs, CodeQL, dependency review, Scorecard analysis, both history secret
scans, Flutter analysis/unit tests, Android release artifacts/SBOMs, unsigned iOS archive and
API 35 core emulator tests (**30 passed / 0 skipped**). Flutter CI unit tests reported **2,658
passed / 1 optional compression skip**. Host-backed/lifecycle tests are not selected by CI's
`core --no-fixtures` profile. The separate Scorecard result is **neutral**, not success.
Only unused docs-only companion jobs were skipped. No failed workflow was rerun unchanged.

All checks for `925ae3c6a755810d59525a42658cc004b37e67df` reached a terminal state:

- Native Build & Test failed in `TerminalLeavePersistenceRobolectricTest`: its teardown reset Main
  while canceled IO work was still dispatching cleanup. Room and native release SBOM jobs were
  consequently **skipped, not passing**. The fix waits for ViewModel and process-terminal jobs
  before resetting the test dispatcher; it does not increase test deadlines or change app behavior.
  A deterministic blocked-finalizer regression fails with the original teardown for the expected
  reason. Apply the same cleanup to the tmux startup tests.
- Flutter analysis/unit tests, Android release artifacts/SBOMs, and unsigned iOS archive passed.
  Emulator testing failed in the native backup save-cancellation test: after the screen revealed
  feedback at the top, the lazy list disposed its export button. Scroll back to the button before
  asserting it is enabled. Native picker tests reached 2 passed / 1 failed / 0 skipped on that head.
  Local retesting also exposed the first-operation notification prompt behind DocumentsUI: the
  test now explicitly handles denial after closing the picker before interacting with Flutter.
  The interrupted device run is not counted as a pass; the subsequent complete profile passed.
- Dependency vulnerability review passed; the license step rejected `file_selector_android`
  `0.5.2+9`'s non-SPDX identifier. The complete published LICENSE contains BSD-3-Clause and
  Apache-2.0 notices, both already approved by the existing policy. Archive and LICENSE checksums
  were independently checked. The new reviewer recognizes only the exact reviewed package,
  version, manifest, ecosystem, source, and identifier, reports the normalization, and rejects
  unrelated LicenseRefs or compounds. Eleven offline tests exercise the policy and gate alignment.
  Missing GitHub license metadata still produces the existing explicit warning, not a reviewed
  license claim. No dependency version, vulnerability threshold, or general allow-list changed.
- CodeQL, Scorecard analysis, and both secret scans passed. The separate Scorecard result was
  neutral, not success. No unchanged failed workflow was rerun, and no protections were weakened.

Focused repair validation: native leave/cleanup and tmux startup tests passed **7 tests per
variant, zero skips**; the new cleanup guard failed against the original teardown for the expected
reason. Native Flutter backup picker retest passed **3 tests, zero failures/skips**, including
actual notification denial. License-policy tests passed **11 tests**, and the reviewer accepted
the recorded GitHub comparison with its unresolved-license warnings retained.

Current repair tree validation:

- `./scripts/local-pr-check.sh --full` **passed**. `refresh-verification-metadata.sh --write`
  followed by strict fresh verification passed, with no checksum changes; the full gate repeated
  `--verify`, including both native release SBOM graphs and Flutter release APK/AAB/SBOM checks.
- Native unit suites: **556 passed / 2 optional replay skips per variant**, 558 discovered, zero
  failures/errors. Skips remain the unavailable `TmuxAltScreenReplayTest` captures, not a new
  exclusion. This x86_64 host executed the affected Robolectric classes.
- Flutter: **2,658 passed / 1 optional live-compression skip**; analyzer clean. SSH production code
  is unchanged from the separately enabled fixture-compression proof recorded below.
- Flutter API 35 `core --no-fixtures`: **30 passed / 0 skipped** — 25 Dart integration cases,
  3 native backup picker cases, 2 native permission cases. No unexpected warnings. This profile
  excludes the host-backed and terminal-lifecycle fixture suites; their earlier evidence below
  remains unchanged, not part of this core run.
- The emulator was intentionally stopped during the memory-heavy gate, so the in-script device
  matrix was deferred. Separate API 35 Room migrations afterward: **4 passed / 0 skipped**.
- The wrapper's final launcher reopen failed because the Flutter package was absent after restart,
  after both `--full` and Room had passed. Rebuilt/reinstalled the normal Flutter debug launcher
  separately; this was an environment-restoration failure, not a failed app test or a green wrapper.
- Full-history secret scanning passed. Both diff whitespace checks passed; repeat the staged secret
  scan and diff checks immediately before the signed checkpoint.

The failed prior head's native Room and SBOM skips remain skips in that historical run; both
gates passed on replacement head `500f35d`. Every future pushed head needs its own complete checks.

## Implemented and regression-tested in the earlier reliability checkpoints

| Area | Changes and evidence |
| --- | --- |
| Background/resume | Kotlin recovery persistence precedes Leave-resumable teardown; Flutter recovery intent/races and foreground-service lifecycle corrected. Runtime lifecycle guards exercise window switching and resumable sessions. Activity/engine destruction remains open below. |
| tmux startup | Show the existing pane before optional history hydration; order quiet-pane/control-mode repaint and guard late responses. Flutter shell-channel negotiation has a post-authentication deadline. Broader setup deadlines remain open. |
| SSH commands | Cancelled/expired Flutter channel-limiter waiters are removed; late leases/channels are cleaned up; cancelled work does not advance to later stages. Kotlin checks cancellation after blocking acquisition and before dispatch. Healthy Stop preserves pooled connections in both versions. Failed Kotlin jump-target authentication releases both owned sessions. No arbitrary command retries. |
| Empty-host navigation | Hidden Monitor/Infra subtabs no longer consume swipes; a selected offline host still permits local Compose editing. |
| Backup | Visible inspection/decryption/restoration progress, compatibility with Kotlin schema 5 and Flutter formats, explicit restore summaries, identity-based reuse and dependent-record remapping. User clarified the old backup itself worked; missing decryption feedback was the issue. |
| Server identity | Compare host, port, effective SSH username and auth method, not label or secret. Add/edit/clone/restore guards and profile-edit transactions prevent new collisions. Existing names/credentials remain intact; errors name conflicting hosts. Do not silently merge legacy duplicates. |
| Profile feedback | Both profile editors show saving state and inline errors. Flutter sheet scrolls; primary controls are disabled while saving. Native and Flutter runtime tests verify a rejected profile edit remains visible and preserves stored data. |
| Fleet/containers | Fleet Uptime/DF/PS use per-host streaming popups without changing Broadcast. Broadcast presets/save grouped with command input. Container actions show immediate busy state, streamed errors and Compose-update stage output. Further fixture/warning audit remains below. |
| Terminal text | Kotlin session identity keys the terminal viewport, preventing stale buffers on host switches. Flutter normal/hidden-normal resize reflows without truncating output; preserves pending wrap and wide characters at one column. Direct full-buffer toggle is visible after long press. |
| Overflow affordances | Persistent directional hints on overflowing Kotlin dialogs/menus/lists and Flutter popup scroll views; hints update with scroll position and disappear when no content overflows. |

Important cancellation boundary: once a request is handed to the SSH library/server, Stop cannot
guarantee the remote command did not run or has terminated. Never claim otherwise or retry it
automatically. Shared Flutter authentication and internal channel negotiation can outlive a
cancelled caller; later resources are cleaned up. The new checkpoint bounds SSH setup while
preserving the separate user-approval window; Activity/engine ownership remains open.

## Validation for the previous source checkpoint (`64d8e23` / `925ae3c`)

- `./scripts/local-pr-check.sh --full` **passed** for this source tree, including strict fresh
  dependency verification and both release SBOM graphs. The owned emulator was stopped during
  the memory-heavy gate; its in-script device matrix was deferred, not counted as passing.
  The separately executed runtime suites below passed, and after the gate the emulator was
  restored and API 35 `AppDatabaseMigrationTest` passed **4 tests / 0 skips**.
- Flutter unit/widget suite: **2,658 passed**, one optional live-compression test skipped in the
  default invocation. The separately enabled live-compression test passed against the disposable
  repository fixture with unchanged SSH code. Analyzer: no issues.
- Kotlin full unit suites: each variant (`openSourceDebug`, `playStoreDebug`) discovered 557
  tests: **555 passed, 2 optional replay cases skipped**, no failures/errors. The skipped cases
  are `TmuxAltScreenReplayTest` (missing optional captures), not platform exclusions on this host.
  Focused identity tests: 7 passed; SSH cancellation guards: 3 passed, no skips in either group.
- Native API 35 runtime: **14 passed, zero skipped** — seed 1, host provisioning 2, terminal
  lifecycle 4, navigation 3, surface sweep 1, backup/profile regression 3.
- Flutter API 35 runtime: host suite **1 passed / 0 skipped**, surface suite **1 passed / 0 skipped**.
  Host suite also runs the native Patrol lifecycle component. No unexpected warnings; known
  upstream Kotlin Gradle plugin warnings remain. Normal debug launcher restored after testing.
- Device-only before proofs: unkeyed Kotlin host switch produced the wrong viewport; native
  profile edit accepted a conflicting login and reported success. Both guards pass with fixes.
  Deterministic before proofs also cover Flutter reflow loss, one-column hang, pending-wrap loss,
  pre-cancelled SSH connections, Kotlin cancellation/connection retirement, and profile collisions.

The default Flutter compression skip is not an untested feature claim. The optional Kotlin
`TmuxAltScreenReplayTest` captures are unavailable in this checkout; those replay cases remain
skipped, not passing. Linux ARM64 excludes unsupported Robolectric native-runtime classes at
discovery; required x86_64 CI must run those classes. This development host is Linux x86_64.
API 36/37 emulator validation remains deferred per `AGENTS.md`; API 29 migrations run in CI.

### Reproduce without the original machine's private scripts or logs

Use JDK 17 for the native project, the repository-pinned Flutter SDK/toolchain, and JDK 21 for
Flutter Android builds. Run `./scripts/test-hosts.sh up` for disposable hosts. Load generated
fixture credentials privately from `scripts/test-hosts/.env`; never print or commit them.

```sh
./scripts/local-pr-check.sh --full
git diff --check
git diff --cached --check
./scripts/flutter-device-test.sh --device <api35-device-id> --profile host
./scripts/flutter-device-test.sh --device <api35-device-id> --profile surface
```

For native device validation, build/install the OpenSource debug app and its test APK **once**,
then drive the runner directly so Gradle reinstalls do not erase provisioning. The package is
`com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner`.
Use the repository's fixture port mapping and the generated account, not a personal host.

| Native class | Count | Required instrumentation arguments |
| --- | ---: | --- |
| `E2eLabSeedTest` | 1 | `omniterm_e2e_seed=yes`; fixture `host`, `port`, `username`, `password`, `lab_password`, `proxy_password` |
| `E2eLabHostProvisioner` | 2 | `omniterm_e2e_provision_host=yes`, `omniterm_e2e_trust_host=yes`; fixture `host`, `port`, `user`, `pass` |
| `E2eTerminalLifecycleStressTest` | 4 | `omniterm_e2e_terminal_lifecycle=yes` |
| `E2eTerminalNavigationMatrixTest` | 3 | `omniterm_e2e_terminal_nav_matrix=yes` |
| `E2eAppSurfaceStressTest` | 1 | `omniterm_e2e_surfaces=yes`, `omniterm_e2e_sftp_home=/home/omniterm` for the runtime fixture |
| `BackupCompatibilityInstrumentedTest` | 3 | No opt-in required; creates/removes its own synthetic records |
| `data.AppDatabaseMigrationTest` | 4 | No opt-in required; run separately on API 35 locally and API 29 in required CI |

Class names are relative to `com.jetsetslow.omniterm`. Pass arguments as `-e key value` and
select a class with `-e class <fully-qualified-class>`. Reject skipped/failing runs explicitly.
Do not cite plain `connectedAndroidTest` as opt-in E2E coverage.

## Remaining authorized work — do not replace this with unrelated tasks

0. **Actual required CI coverage:** `b691ddd` finished terminal with every selected check green,
   and that is precisely the problem — its `Analyze Java/Kotlin` was the placeholder. The detector
   repair and its regression test are above. What remains: push the replacement head, watch every
   selected job to a terminal state, and confirm from the job list that the **real** CodeQL
   analysis ran for 30+ minutes rather than a 3-second no-op. Do not treat a green envelope,
   a skipped companion, or a passing local gate as security analysis.
1. **SSH background retention and remaining latency:** audit Flutter Activity/engine destruction,
   live-session ownership, foreground-service error visibility and disconnect-all feedback.
   Continue measuring cold-connect and tmux startup latency; the new setup deadlines prevent hangs,
   but are not a claim that healthy connections are faster. Verify blank bastion username fallback
   and endpoint trimming against Kotlin with fixture regressions before changing them.
   Follow up Flutter's tmux preflight before its busy/attempt guard, error-string classification
   (transport failures must not mean tmux is missing), and channel cleanup if persistence fails
   after a shell opens. Add held-probe/concurrent-attempt and post-open storage-failure tests.
2. **Fleet/container proof and consistency:** add a native fixture guard that taps all three Fleet
   diagnostics and proves popup streaming without changing Broadcast; Flutter has this live guard.
   Exercise real Compose Update with delayed output/stderr and local-build fallback. Audit mutation
   confirmations across Fleet, individual containers and stacks; keep read-only actions lightweight.
3. **Complete parity/feedback audit:** use the release handover and existing migration records;
   inspect untested feature routes and error/cancellation paths. Keep progress, errors, skip summaries
   and overflow indicators consistent. Do not declare full Kotlin/Flutter parity based only on the
   completed fixes above. Flutter backup picker cancellation still has legacy silent-result
   handling; add explicit cancellation feedback consistently in both apps in the backup UX batch.
   Also audit backup trust-store export omissions, selection/last-export metadata IO failures and
   first-operation notification permissions overlapping the document picker. Do not silently omit
   pinned keys or misreport a saved file when only its metadata update failed.
4. **Publishing discipline:** checkpoint frequently, monitor every pushed head, fix failures from
   exact job logs, and leave required reviews/protections/signing/checks intact. This request does
   not authorize merging to `main`, publishing a release, or merging unrelated automated PRs.

## Automated PR review (read-only; last checked 2026-09-11)

- #99: AGP 9.3.2 → 9.4.0. Head `a8436aa96140500cd1ca4cd14195a1268e9e0c1e`.
  Build/CodeQL failed for missing plugin verification metadata; migrations/SBOM skipped.
- #100: proposed metadata fixup for #99, head `ac059121d7c6786f201eb288385fe293b1734d52`.
  No checks; not independently forced-fresh validated. Do not treat it as green or merge automatically.
- #101: deploy-pages 5.0.1, head `e18225d4d6b924b30cd017a500d8877970174d59`.
  Review required; docs-only placeholder checks are not evidence of app-build validation.

Re-query these heads/statuses before acting. No automated PR has been changed or merged by this review.

## Claude continuation and return-review prompt

Read AGENTS.md, this tracker, the private September 13 Claude handover and the original release
record. Continue the authorized Kotlin/Flutter reliability and feature/functionality parity review
on `migration-to-flutter`. First verify actual branch/HEAD, remote, dirty files, PR #92 exact-head
checks and running local jobs. Preserve existing changes and all completed fixes above. Private
notes are supplementary; this tracked document must remain enough to recover on another machine.

Start with exact-head CI and the false-skipped CodeQL analysis above; inspect actual job logs,
fix the detector with a regression test and require real security analysis. Then address SSH lifecycle and
latency, Fleet/container streaming/warning and app-wide feedback/parity work above. Use repository
fixtures only. Add deterministic regression tests and real-runtime before/after proof where required;
show progress, explicit results, cancellation/skip reasons and actionable errors. Preserve host
identity semantics, app-lock/privacy, explicit Quit, security checks and platform-specific limits.

Make frequent signed checkpoints only after the full local gate validates each build-affecting
final tree; run both diff checks and staged secret scanning. Push only the working branch, monitor
every selected exact-head check through terminal state and keep this tracker current. Never rerun
unchanged failed workflows, count skips as passes, merge main, merge automated PRs or release without
new authority. Set up your own verified exact-session continuation schedule per AGENTS.md, not the
retired Codex timer, and stop it at completion or handback. Stale `continue` is not new work.

Before returning to the user, leave a dated `CLAUDE_TO_CODEX_REVIEW` document under private docs and
link it here. Include completed/pending work, SHAs, dirty files, tests and commands with counts/skips,
before/after evidence, exact CI status, risks, platform gaps and any running jobs/stop/recovery steps.
Include a ready-to-use prompt for Codex to independently review your changes, reproduce critical
regressions, verify parity and security, finish remaining authorized issues and finalize only when
all required evidence is complete. Distinguish implementation-complete from validation-complete;
do not declare full parity merely because a subset passed. Keep the public summary sanitized.
