# OmniTerm working agreements

These rules apply to every contributor and automation tool working in this repository.

## Validate before publishing

- For any build-affecting change, run `./scripts/local-pr-check.sh --full` before the final commit
  or push. `--quick` is for intermediate iteration only and is not a final validation result.
- Never report a suite as passing if Gradle excluded or skipped part of it. State the exact
  platform-specific exclusions and the gate that will exercise them.
- Keep `scripts/local-pr-check.sh` aligned with `.github/workflows/android-pr-check.yml` whenever
  build, test, lint, migration, SBOM, signing-input, or dependency-verification behavior changes.
- Run `git diff --check` and `git diff --cached --check` before committing.

## Keep tests platform-safe

- Put platform-neutral logic in ordinary JVM tests. Do not place pure coroutine, parser, ordering,
  or state-machine guarantees inside Robolectric or instrumentation tests.
- Robolectric 4.16's Android 15 native runtime is unavailable on Linux ARM64. The Gradle test
  configuration must exclude native-runtime classes during discovery on that host; a JUnit
  assumption inside the class is too late because Robolectric fails before `@Before` runs.
- Android-framework behavior may remain in Robolectric/instrumentation tests, but required PR CI
  must exercise it on a supported x86_64 runner.
- Do not use `kotlinx.coroutines.test.runTest` around production work dispatched to real
  `Dispatchers.IO`/`Default`; virtual timeout advancement can race real threads. Inject a test
  dispatcher or use a plain JVM `runBlocking` integration test with bounded real-time waits.
- A test failure that varies with heap pressure or host speed is still a test defect. Fix the
  synchronization boundary rather than repeatedly increasing timeouts or rerunning until green.
- For terminal-emulator changes, reduce a real sanitized PTY/tmux byte stream to a deterministic
  JVM replay. Dispatch on the complete control sequence, not only its final byte: modern Kitty
  keyboard-protocol controls such as `CSI < u` and `CSI >1 u` share `u` with ANSI restore-cursor
  but must never move the terminal cursor.

## Required pre-merge evidence

- Treat the PR as incomplete until the exact final head passes Build & Test, Room migration
  validation, release SBOM generation, CodeQL, dependency review, and repository security checks.
- On hosts without an Android device/emulator, the local preflight must report the migration matrix
  as deferred; required hosted CI must pass it before merge.
- Do not merge based only on local ARM64 results because native Robolectric classes are intentionally
  deferred there.
- Keep the PR unit/lint heap aligned with the release gate (`-Xmx4g` on hosted runners) unless
  measured evidence supports changing both together.

## Dependency and checksum verification

- Gradle dependency verification is strict. `gradle/verification-metadata.xml` is a security
  boundary, not generated noise: keep SHA-256 and SHA-512 checksums for every resolved artifact,
  POM, and module-metadata file. Never disable verification, delete a failing component, or add a
  broad trusted-artifact rule merely to make resolution pass.
- A warm Gradle cache is not evidence that verification metadata is complete. Whenever a
  dependency, plugin, version catalog, dependency substitution, repository, benchmark dependency,
  or CycloneDX tool changes, regenerate against forced fresh resolution with
  `--write-verification-metadata sha256,sha512 --refresh-dependencies`.
- Resolve every affected graph while writing metadata: buildscript/plugin classpaths, parent POMs
  and module metadata, both Open Source and Play Store variants, unit and instrumentation tests,
  lint/build tooling, the benchmark module, and both CycloneDX release configurations
  (`playStoreReleaseRuntimeClasspath` and `openSourceReleaseRuntimeClasspath`).
- Generate both release graphs separately through `.github/cyclonedx.init.gradle.kts`, setting
  `SBOM_CONFIGURATION` for each, because debug compilation does not resolve the dependencies that
  ship in release artifacts.
- After regeneration, rerun the same graphs with strict verification and
  `--refresh-dependencies` but without `--write-verification-metadata`. A successful warm-cache
  build alone is insufficient.
- Review the metadata diff. It must correspond only to intended dependency graph changes; investigate
  unexpected repositories, versions, duplicate artifacts, disappearing checksums, or large unrelated
  churn before committing.
- Keep security substitutions in the root `build.gradle.kts` intact. The vulnerable and patched
  coordinate strings are deliberately split so Dependabot cannot rewrite the vulnerable-version
  match into a useless identity substitution.

## Dependabot and dependency policy

- Inspect `.github/dependabot.yml`, all open dependency PRs, and the Dependabot update job together.
  Respect compile-SDK holds, CodeQL/Kotlin compatibility holds, action startup-failure holds, and
  the dedicated-review requirement for user-visible network/SSH/ads/consent major upgrades.
- Fix recurring incompatibilities in `.github/dependabot.yml`; do not repeatedly close equivalent
  PRs and wait for Dependabot to recreate them.
- Dependabot cannot safely author complete Gradle checksums itself. Preserve
  `.github/workflows/dependabot-verification-metadata.yml`: it reads only the version catalog and
  never trusts metadata from the bot PR, regenerates on trusted `main`, and opens a separate fixup
  PR without executing untrusted PR code under `pull_request_target`. Keep it scoped to Gradle
  Dependabot branches. It requires the repository Actions setting that permits PR creation, but
  must never approve its own PR; independent review and normal branch protections still apply.
- Use `./scripts/refresh-verification-metadata.sh --write` for checksum regeneration and
  `--verify` for a non-mutating forced-refresh check. Keep local and CI dependency resolution
  aligned through this script rather than adding partial one-off Gradle commands.
- Keep GitHub Actions pinned to full commit SHAs and retain dependency-review, dependency-submission,
  CodeQL, Scorecard, and secret-scan gates. A version bump is incomplete until these checks and the
  two release SBOM graphs pass on the exact final head.

## Debug publishing

- Keep manual debug publishing separate from production release automation in
  `.github/workflows/android-debug.yml`. It must build reviewed `main`, default to a non-publishing
  dry run, use only `debug-*` tags, and never upload to Google Play.
- A published debug APK must use the stable `ANDROID_DEBUG_KEYSTORE_BASE64` secret from the `debug`
  environment and require a successful exact-SHA main gate. Dry runs must use an ephemeral key.
- Verify the APK signature, package ID, version name/code, debuggable flag, and SHA-256 checksums
  before uploading or creating a GitHub prerelease.

## CI failure discipline

- Read the exact failed job and logs before editing. Distinguish source/test failures from runner,
  memory, dependency-verification, signing, artifact, SBOM, and release-only failures.
- Do not repeatedly rerun an unchanged failing workflow. Identify what changed in the next attempt
  and what result will terminate the loop.
- Preserve branch protection, signed commits, required reviews, and required checks. Never weaken a
  repository protection to make a PR pass.
