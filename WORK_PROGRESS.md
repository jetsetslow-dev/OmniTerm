# Kotlin dependency review — temporary branch tracker

Updated: 2026-09-30. Working branch: `review/kotlin-dependabot-109`; proposed PR head: #109.

This file is temporary. Before any authorized merge to `main`, move the useful review record to
the private handover and remove this file from the merge tree. Do not add credentials, local host
details, session IDs or private logs here.

## Implemented and under validation

- PR #109 updates the Android dependency group: Gradle 9.8.0, Android Gradle Plugin 9.4.1,
  Navigation 2.10.2, Roborazzi 1.75.0, Bouncy Castle 1.86 and Develocity 4.6.0. The original
  head `38fd12a` failed Build & Test and CodeQL on missing strict Gradle verification metadata
  for Develocity 4.6.0. The exact failed jobs were inspected before changing files.
- PR #110 proposes metadata for #109, but its commit is unsigned. Its metadata file was copied
  into this worktree without merging the unsigned commit. The Gradle Windows wrapper line endings
  were normalized for review. A first `--write` pass failed only because the isolated worktree
  lacked a local ignored debug signing input; that input is now available for validation. The
  replacement `./scripts/refresh-verification-metadata.sh --write` passed, including its own
  forced-fresh verification of project, both release SBOM and both debug compile graphs. Relative
  to #109, the metadata adds 111 artifact/POM/module entries and completes SHA-512 on three
  existing entries. Every changed record has both correctly sized SHA-256 and SHA-512 values;
  no artifact records were removed or duplicated. The separate `--verify` run also passed with
  forced-fresh resolution of project, both release SBOM and both debug compile graphs.
- PR #111 updates pinned GitHub Actions. Its reported checks are terminal without a failure, and
  its required review remains pending. No automated PR has been merged to `main`.
- `./scripts/local-pr-check.sh --full` passed on the staged dependency tree. Both native debug
  variants ran 572 unit cases each with zero failures and two existing disabled
  `TmuxAltScreenReplayTest` cases per variant; both lint variants passed. Strict fresh Gradle
  verification passed again across project, release SBOM and compile graphs, and the staged diff
  secret scan found no leaks. This Kotlin branch has no `flutter_app`, so the Flutter gate is not
  selected here. The disposable API 35 emulator was OOM-killed during Gradle validation, and this
  full gate explicitly deferred Android instrumentation; that stage is not counted as passing.
  The emulator was restarted for separate device validation. Plain API 35 instrumentation then
  discovered 58 cases: 24 passed, 34 opt-in assumption exits and zero actual failures. The
  repository-controlled SSH fleet was verified ready. In one app/test-APK installation,
  `E2eLabHostProvisioner` host provisioning and host-key trust each passed one case with zero skips.
  The first `E2eAppSurfaceStressTest` invocation failed at SFTP because its argument pointed at a
  different lab layout; this repository fixture's documented home is `/config`. Re-running only
  that case with `/config`, without reinstalling or changing source, passed one case with zero
  skips. This is an operator argument correction, not a product fix.

## Remaining validation before a signed checkpoint

1. Re-run both diff checks and the staged secret scan after updating this tracker. Make a signed
   checkpoint on the working branch, push it to #109 only after validation,
   and monitor every selected check on the exact new head until terminal. Inspect job logs before
   fixing any hosted failure. Do not merge to `main` or publish a release without authorization.

The broader Flutter/Kotlin UI, gesture, biometric and terminal parity review continues on
`migration-to-flutter`; this dependency PR does not assert that parity is complete.
