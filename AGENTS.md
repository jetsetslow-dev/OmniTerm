# OmniTerm working agreements

These rules apply to every contributor and automation tool working in this repository.

## Validate before publishing

- Run `./scripts/local-pr-check.sh --full` for every build-affecting final tree before committing
  or pushing it. `--quick` is only an intermediate check.
- Never describe a suite as passing when Gradle excluded or skipped part of it. Name every
  platform-specific exclusion and the later gate that covers it.
- Keep `scripts/local-pr-check.sh` and `.github/workflows/android-pr-check.yml` aligned whenever
  build, test, lint, migration, SBOM, signing-input, or dependency-verification behavior changes.
- Run `git diff --check` and `git diff --cached --check` before committing.

## Monitor every PR head to completion

- After every PR push, monitor all checks for that exact head until every check has reached a
  terminal state. A successful push is not completion, and pending checks must not be handed off
  as though the PR were green.
- If any check fails, inspect the exact failed job and its logs before editing. Distinguish source
  or test failures from runner, memory, dependency-verification, signing, artifact, SBOM,
  release-only, and security-analysis failures.
- Fix the cause, validate the final tree locally, push a new head, and monitor the replacement run
  through completion. Do not rerun an unchanged failed workflow.
- Treat the PR as incomplete until the exact final head passes Build & Test, Room migrations,
  release SBOM generation, CodeQL, dependency review, Scorecard/repository security checks, and
  every platform/release job selected for that PR.
- Record any genuinely unavailable external/platform validation explicitly; never silently treat
  a skipped, cancelled, superseded, or unstarted job as passing.

## Open every affected screen on a real Android runtime

- JVM tests are not evidence that an Android screen opens. For UI, parsing, or state read by UI,
  install the debug APK on API 34+ and open every reachable affected screen.
- Use the repository-controlled disposable SSH fleet (`scripts/test-hosts.sh up`) and
  `E2eLabHostProvisioner`, never personal or production hosts.
- `E2eAppSurfaceStressTest` is the required route/subtab/theme/rotation sweep. Pass
  `-e omniterm_e2e_surfaces yes` and the fixture SFTP home argument when needed.
- Every `E2e*` suite is opt-in through instrumentation arguments. A plain
  `connectedAndroidTest` skips them while still reporting success; always state the arguments and
  executed/skipped test counts.
- Keep provisioning and exercise in one invocation, or install once and drive instrumentation
  directly, because Gradle reinstalls wipe seeded app data.
- Device-only regression tests must be seen failing for the expected reason on unfixed code.
- Tests must assert against repository fixtures. A personal lab is an override, never the default.

## Keep tests platform-safe

- Keep pure coroutine, parser, ordering, and state-machine guarantees in ordinary JVM tests.
- Exclude Robolectric native-runtime classes during discovery on Linux ARM64; required x86_64 CI
  must exercise them.
- Run the Room matrix on API 29 in required CI and API 35 locally when a KVM-capable host exists.
  API 36/37 remain deferred until a stable emulator newer than 37.1.11 boots them reliably.
- Android regexes use ICU. Escape literal braces/brackets and verify UI-reachable regexes on device.
- Do not wrap production work on real IO/Default dispatchers in virtual-time `runTest`; inject a
  dispatcher or use bounded real-time integration tests.
- Fix synchronization boundaries rather than repeatedly increasing timeouts or rerunning flakes.
- For terminal parsing, replay deterministic sanitized PTY/tmux streams and dispatch on complete
  control sequences.

## Dependency, checksum, and supply-chain policy

- Gradle verification is strict. Keep SHA-256 and SHA-512 checksums for every resolved artifact,
  POM, and module metadata file; never disable verification or add broad trust rules to pass CI.
- For dependency/plugin/catalog/repository/SBOM changes, use
  `./scripts/refresh-verification-metadata.sh --write`, inspect the diff, then run `--verify` with
  forced fresh resolution across buildscript, both app variants, tests, lint, benchmark, and both
  release SBOM graphs.
- Preserve root security substitutions and the trusted-main Dependabot metadata-fixup workflow.
- Inspect Dependabot configuration, open dependency PRs, and update-job policy together. Respect
  compatibility holds and dedicated review for user-visible network/SSH/ads/consent majors.
- Keep Actions pinned to full SHAs and retain dependency review/submission, CodeQL, Scorecard,
  secret scanning, and release SBOM gates.

## Release and publishing safety

- Kotlin and Flutter release selection must remain mutually exclusive through
  `.github/release-engine`.
- Debug publishing stays separate from production, builds reviewed `main`, defaults to dry-run,
  uses only `debug-*` tags, and never uploads to Google Play.
- Published artifacts require the stable environment-scoped key and a successful exact-SHA main
  gate. Verify signature, package ID, version, debuggable state, and SHA-256 before publishing.
- Preserve branch protection, signed commits, required reviews, and required checks. Never weaken
  repository security or protection settings to make a PR pass.
