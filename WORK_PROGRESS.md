# Kotlin Multiplatform, phase 1 — 2026-11-09

Scope: the shared Kotlin module and an iOS app that builds and tests on CI, the first step of
OmniTerm on iOS (decision: `docs/adr/0004-kotlin-multiplatform-for-ios.md`). This branch starts
from main 06474d5. New features land first on `kotlin-automation` (PR #138); this branch merges
main as they do. Independent review and merge remain the user's responsibility.

## Implemented

- `shared/`: a Kotlin Multiplatform module for Android and iOS (`iosArm64`,
  `iosSimulatorArm64`), building the dynamic `OmniTermShared` framework.
- Pure logic moved to `shared/src/commonMain` under its old package, so app imports are unchanged:
  `HealthScoring`, `SshConfig`, `RefreshOutcome`, `RemoteModels`, `HostTools`.
  - `HostTool`'s PATH and time bounds moved to a new shared `HostShell` object; `RemoteCommands`
    points at it, so there is still one copy.
  - `SshConfig`'s JVM-only `putIfAbsent` became `getOrPut` (first value wins, as before).
- Their tests moved to `shared/src/commonTest` on `kotlin.test`. The JVM run is
  `:shared:testAndroidHostTest`; the iOS run is `:shared:iosSimulatorArm64Test` (macOS only).
  Kotlin/Native refuses a comma in a backtick test name, so `RefreshOutcomeTest` uses camelCase.
- Compose Multiplatform 1.12.2 and the Compose compiler apply to the iOS source set only. The
  Android app's dependencies are unchanged.
- `iosApp/`: an XcodeGen project (iOS 17, Swift 6) for a SwiftUI app hosting a shared Compose
  screen that says the iOS app is in development, a privacy manifest, and an XCTest suite that calls
  the shared ssh_config parser from Swift and loads the screen.
- CI:
  - New `iOS Check` workflow on macOS: shared tests on the simulator, then `xcodebuild test` on the
    newest iPhone simulator. Actions pinned to the Android workflows' commits; XcodeGen 2.46.0
    checked against its SHA-256.
  - `:shared:testAndroidHostTest` added to PR Check, the debug and release workflows, the
    main-branch gate (`scripts/ci-gradle-gate.sh` and its test) and `scripts/local-pr-check.sh`.
  - `shared/` added to the PR Check and CodeQL change detectors, with a detector test that fails
    without it.
- Dependency verification: the refresh resolves the shared module and its iOS libraries. The
  macOS Kotlin/Native prebuilt, which only a Mac downloads, has hand-added checksums from Maven
  Central (its SHA-1 matches Maven Central's published one).
- Dependency updates the gate requires, the same versions `kotlin-automation` took in 82702ea: AGP
  9.5.1, Gradle 9.9.0, biometric 1.4.0-beta01, mockk 1.14.12, Roborazzi 1.78.0, UI Automator
  2.4.1, setup-java 6.2.0, codeql-action 4.39.3. Kotlin stays at 2.4.0 (CodeQL lists up to 2.4.20;
  Dependabot would propose 2.4.21); the hold now names `org.jetbrains.kotlin.multiplatform` too.

## Validation

- On this Linux host: `:shared:compileAndroidMain`, `:shared:compileKotlinIosArm64`,
  `:shared:compileKotlinIosSimulatorArm64` and `:shared:compileTestKotlinIosSimulatorArm64`
  pass; linking and running iOS tests need macOS, so CI does those.
- `:shared:testAndroidHostTest`: HealthScoringTest 4, RefreshOutcomeTest 9, SshConfigParserTest 4,
  all passed.
- `scripts/test-change-detectors.sh`: 29 checks passed; the shared case fails with `shared/`
  removed. `scripts/test-ci-gradle-gate.sh` passed. Actions allowlist: every action allowed.
- `./scripts/local-pr-check.sh --full` passed on this tree: unit tests with the shared JVM run,
  lint, strict dependency verification, no advisories or outstanding updates, secret scan, the API
  35 device matrix (15 tests), and CodeQL 2.27.4 with no alerts (75,852 lines).
- iOS Check on macOS: pending until the branch is pushed.

## Next on this branch

1. Merge main as `kotlin-automation` features land.
2. More pure logic into `commonMain` (the remote parsers need `String.format` and UTF-16LE
   encoding replaced first).
3. The Go network core behind `SshTransport` on Android, then iOS adapters (Keychain,
   notifications, background limits) with a warning wherever Apple does not allow a feature.

Before an authorized merge, consolidate this tracker into the private handover and remove it from
the merge tree.
