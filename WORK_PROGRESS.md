# Kotlin PR completion — 2026-11-03

Scope: finish PR #136 on `kotlin-bug-fixes`, including the requested additional bug review.
Independent review and merge remain the user's responsibility. No new Haven features, Flutter
changes, releases, automated approvals, alert dismissals or review-thread resolutions are included.

## Implemented in this checkpoint

- Share the digest-pinned gitleaks history scan and tracked credential-container rejection between
  local preflight, Secret scan and the aggregate CodeQL/release gate. Check staged and unstaged
  diffs too; stage new files before running the gate. Support linked worktrees with read-only
  mounts and no container network. Missing Docker/image and shallow history fail with instructions.
  An isolated self-test checks credential filenames, failure propagation, linked worktrees and wiring.
- Preserve forwarded-agent context for certificate-wrapped security keys while retaining RSA
  SHA-512 signing. Forwarded touch requests keep their shorter timeout and explicit wording.
- Close SFTP channels that fail to connect, including jump-host channels. Replace a stale reused
  connection once; report a fresh connection failure without another sign-in attempt.
- Keep New file creation and the ensuing editor read on the original host/folder/sudo context.
  Show pending progress, prevent duplicate creation while pending, report no-host errors, and
  avoid opening another host's file after navigation. Update end-user documentation.
- Share the two-tab Fleet count with swipe navigation and the device sweep; use all six Infra tabs
  in the sweep, including Kubernetes. This corrects test drift without changing product tabs.
- Keep full unit-test exception details in local and CI logs for missing-class diagnosis.

## Final local validation

`./scripts/local-pr-check.sh --full` completed successfully on the final build-affecting tree.
Only this tracker is updated afterward. Reproducible checks and results:

| Check | Result |
| --- | --- |
| Both full unit variants | 907 discovered, **899 passed / 8 skipped** per variant, no failures/errors |
| Changed test repeats | 52 classes, five additional runs; **311 passed / 6 skipped** per run |
| Both Android lint gates | Passed |
| Strict fresh dependency verification | Project, buildscript, test, lint, instrumentation, benchmark, both release SBOM and compile graphs passed |
| Dependency advisories | None at moderate or above across 201 Maven packages and 13 Actions |
| Dependency updates | None proposed under the repository's holds; 66 Gradle and 36 Actions checked |
| Secret scanner | Isolated self-test plus complete history, staged diff and unstaged diff passed |
| Ordinary API 35 instrumentation | 69 discovered, **27 passed / 42 opt-in E2E skipped**, no failures/errors |
| API 35 Room matrix | **6 passed / 0 skipped**, included in ordinary instrumentation |
| Local CodeQL security-extended | **Zero alerts, 75,627 lines analyzed**; all 120 production Java/Kotlin files extracted |

Unit skips are six opt-in `SshSignInLiveTest` cases and two unavailable `TmuxAltScreenReplayTest`
captures. Repeats skip only the six live cases. This Linux x86_64 host excluded no unsupported
ARM native-runtime classes. CodeQL's 120/338 source-file message corresponds to all 120 production
files across both variants; tests/benchmark sources are outside its production-only compile.

## Explicit fixture/runtime checks

API 35 uses only the disposable repository SSH fleet from `./scripts/test-hosts.sh up`.
Provisioning passed **2 / 0 skipped**. The following opt-ins were driven directly after installing
app and test APKs once, so provisioning survived:

- `E2eKotlinConnectionFixesTest`, `omniterm_e2e_connection_fixes=yes`: **2 passed / 0 skipped**;
  forwarded prompt wording and cancellation, New file progress, editor opening, save/read-back,
  existing-name refusal and cleanup.
- `E2eAppSurfaceStressTest`, `omniterm_e2e_surfaces=yes`: **1 passed / 0 skipped**;
  routes, subtabs including Kubernetes, themes, rotation and remote loaders.
- Both suites used `omniterm_e2e_sftp_home=/config`.
- A manual warm-SFTP check paused only the disposable direct fixture for 6.5 seconds. One old
  transport was retired, one replacement appeared, and the listing returned without a visible
  connection error. This is actual Android recovery evidence.
- The separately enabled Play Store live suite (`--tests '*SshSignInLiveTest'
  -Domniterm.liveSsh=true`) passed **6 / 0 skipped** against certificate-only OpenSSH: Ed25519/RSA
  certificates, protected keys, software FIDO keys, missing-touch feedback and safe file creation.

Regression controls failed on the prior implementations before passing with the fixes. The first
completion gate failed to compile the new test's private-setter assignment, and the first surface
run exposed stale tab counts; those failed attempts are preserved privately and are not passes.
The recorded `GlobalAlertsPopupTest` failure did not recur in the final ordinary run; its earlier
cause remains unproven. Starting head `6fe1cc8` had 101 abbreviated missing-class failures in hosted
Play Store tests; the final full local suites passed, and full exception logging now preserves a
root cause if it recurs. Do not label an unproven earlier CI cause a confirmed source fix.

## Publication and remaining boundary

At checkpoint creation, final-head hosted CI is pending. After pushing, monitor the exact head
through Build & Test, Room migrations, release SBOM, CodeQL, dependency review, secret scanning and
supply-chain analysis; inspect real job durations rather than companion no-op names. The PR
Validation section records the resulting terminal status without creating another head just to
change this snapshot. Keep required reviews, signing and protections intact.

Real FIDO2 USB/NFC, USB serial, real telnetd and macOS remain untested here. Software authenticators
and TCP fixtures do not establish hardware coverage. API 36/37 remain deferred under repository
policy; required hosted CI covers API 29 Room migrations. The user accepted the behavior decisions
and two historical gitleaks banner exclusions on 2026-11-03; no new exclusions were added.

Consolidate this temporary tracker privately before any later authorized merge to main.
