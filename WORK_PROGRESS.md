# Kotlin / Flutter reliability review — temporary branch tracker

Updated: 2026-09-12. Working branch: `migration-to-flutter`; review PR: #92.
This is an in-progress checkpoint, **not** a parity-complete or release-ready declaration.

This sanitized tracker is intentionally committed so work can resume on another machine.
Before an authorized merge to `main`, consolidate it into the private handover under
`secrets/internal-docs/docs/` and remove this temporary file from the merge tree. Never put
secrets here: moving it later does not erase Git history.

## Resume here

1. Read `AGENTS.md`. Inspect `git status`, `git log -5`, and the remote branch before editing.
2. Check PR #92's **actual head SHA** and all its checks. Signed checkpoints `64d8e23` and
   `925ae3c` were pushed; the latter reconciles `main` (`bf227d2`) into this branch without changing
   the validated source. All `925ae3c` checks finished, but three jobs failed (details below).
   The replacement CI-repair checkpoint passed full local validation; push it and observe every
   exact-head check to completion. Never infer CI success from local results.
3. Preserve the existing fixes. Finish the remaining investigations below in small batches; run
   the required validation, update this tracker, commit with signing enabled, push, and monitor
   every selected check to completion before publishing the next replacement head.
4. Keep the session-targeted external continuation schedule active while authorized work remains,
   as required by `AGENTS.md`. Re-establish it on a replacement machine using that client's own
   verified mechanism; local timers do not survive loss of the original host.

Useful read-only recovery commands:

```sh
git status --short
git log -5 --oneline
gh pr view 92 --json headRefOid,statusCheckRollup,reviewDecision
gh run list --branch migration-to-flutter
```

The merge conflicts were only in `AppUi.kt` and `AppViewModel.kt`: preserve visible recovery
feedback, transport-generation ownership/cancellation, and batched recovery persistence. All
incoming hotfixes were already present. Before this tracker-only edit, the resolved merge tree
was byte-identical to checkpoint `64d8e23` (tree `44ac3dc54ff8690544e4a36d00abab5a1a33647a`).
No build-affecting source changed; the full local validation below applies to that same source.

## CI repair checkpoint — local validation passed; replacement CI still required

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

The replacement PR head still requires all selected GitHub checks. The prior head's native Room
and SBOM skips remain skips; only replacement-head CI can close those gates.

## Implemented and regression-tested in this checkpoint

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
cancelled caller; later resources are cleaned up, but setup deadlines still need investigation.

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

1. **SSH setup/background retention:** investigate remaining cold-connect and tmux latency;
   bound stalled banner/authentication/bastion forwarding without timing out user host-key approval.
   The pinned dartssh2 client already has `authTimeout` (starts after transport readiness) and
   `handshakeTimeout` (includes host-key verification). Do not blindly set both to 15 seconds.
   Add deterministic stalled-peer and approval-time tests. Audit Flutter Activity/engine destruction,
   live-session ownership, foreground-service error visibility and disconnect-all feedback.
2. **Fleet/container proof and consistency:** add a native fixture guard that taps all three Fleet
   diagnostics and proves popup streaming without changing Broadcast; Flutter has this live guard.
   Exercise real Compose Update with delayed output/stderr and local-build fallback. Audit mutation
   confirmations across Fleet, individual containers and stacks; keep read-only actions lightweight.
3. **Complete parity/feedback audit:** use the release handover and existing migration records;
   inspect untested feature routes and error/cancellation paths. Keep progress, errors, skip summaries
   and overflow indicators consistent. Do not declare full Kotlin/Flutter parity based only on the
   completed fixes above. Flutter backup picker cancellation still has legacy silent-result
   handling; add explicit cancellation feedback consistently in both apps in the backup UX batch.
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
