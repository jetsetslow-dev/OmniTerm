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

## Open every screen you touched on a real device

JVM unit tests are not evidence that a screen still opens. They run on the desktop JDK, which does
not share Android's framework, resources, or regex engine. A change can hold a full green JVM suite
and still crash on first navigation. This section is mandatory for any change to UI, parsing, or
state that a screen reads.

- Before the final commit, install the debug APK on an API 34+ device or emulator and open **every
  screen the change can reach**, not only the one named in the ticket. Class-initializer failures
  surface on first navigation, so a screen that merely composes the changed file is impacted.
- Use `scripts/test-hosts.sh up` for the disposable SSH fleet and `E2eLabHostProvisioner` to seed
  the `E2E Foreground Demo` host. Never validate against a personal or production host.
- `E2eAppSurfaceStressTest` is the required sweep: it walks every route, subtab, theme, and rotation.
  Run it with `-e omniterm_e2e_surfaces yes`. Add `-e omniterm_e2e_sftp_home <path>` when the fixture
  home is not `/home/<user>` (the Docker fleet uses `/config`).
- Every `E2e*` suite is opt-in behind `assumeTrue(...)` on an instrumentation argument. A plain
  `connectedAndroidTest` **skips them and still reports BUILD SUCCESSFUL**. Never cite a connected
  run as screen coverage without naming the arguments you passed and the test count that executed.
- Gradle reinstalls the APK per `connectedAndroidTest` invocation, which wipes app data and destroys
  the seeded host. Provision and exercise in the same invocation, or install both APKs once and
  drive `adb shell am instrument` directly so state survives between steps.
- A green on-device test proves nothing until you have seen it fail. When a device-only defect is
  fixed, re-run the guard against the unfixed code and confirm it fails for the expected reason.
- Tests must be host independent wherever that is achievable. Every fact a test asserts should come
  from a fixture this repository controls, not from whatever the developer machine happens to be
  running. The Network Tools port scan used to assert port 22 was open, which was really an
  assertion that the workstation runs sshd — it passed or failed for reasons unrelated to the app.
  It now scans only ports the disposable fleet publishes. When a suite genuinely needs something
  external, make it explicit and overridable rather than implicit.
- Device suites must run against the fixtures in this repository, and the repository's own fleet is
  the DEFAULT — a personal lab is the override, never the other way round. Do not hardcode a path,
  account, or open port that exists only on one contributor's machine; parameterize it through an
  instrumentation argument whose default is what a clean checkout provides.
- Large test inputs are generated and committed, never hand-written. The 400-service Compose stack
  lives at `scripts/test-hosts/fixtures/large-stack/compose.yml`, is produced by
  `ComposeLargeStackFixture`, and is mounted read-only into the disposable fleet so a test cannot
  mutate its own input. `ComposeLargeStackFixtureTest` regenerates it and fails on any drift; change
  it by editing the generator and rerunning with `-Domniterm.regenerateFixture=true`, then commit
  the result. Generate through the app's own renderer, not an independent writer, whenever a test
  asserts a render round-trip — otherwise the fixture drifts the first time formatting changes and
  the failure impersonates a parser bug.
- `scripts/local-pr-check.sh` runs the whole instrumentation package; the hosted PR job stays
  data-layer-only on purpose. It is pinned to API 29, which predates the ICU regex engine, so it
  cannot gate modern-device defects. Screen coverage is a local API 34+ responsibility until hosted
  CI can boot API >= 36. Do not "align" the two by narrowing the local run.

## Keep tests platform-safe

- Put platform-neutral logic in ordinary JVM tests. Do not place pure coroutine, parser, ordering,
  or state-machine guarantees inside Robolectric or instrumentation tests.
- Robolectric 4.16's Android 15 native runtime is unavailable on Linux ARM64. The Gradle test
  configuration must exclude native-runtime classes during discovery on that host; a JUnit
  assumption inside the class is too late because Robolectric fails before `@Before` runs.
- Android-framework behavior may remain in Robolectric/instrumentation tests, but required PR CI
  must exercise it on a supported x86_64 runner.
- Required CI runs the Room migration matrix on API 29 only. On a KVM-capable x86_64 host, also run
  it locally against **API 35**, the newest level the current stable emulator can boot, so the
  modern end of the supported range (`targetSdk` 37, `minSdk` 24) is exercised and not just the
  oldest. Do not raise CI's API level to match: hosted runners may lack KVM, and API >= 36 images
  cannot boot at all on emulator 37.1.11 — surfaceflinger aborts on `hasReadColorBufferDma` and
  crash-loops system_server. Re-test API 36/37 when a stable emulator newer than 37.1.11 ships.
- An emulator satisfies the migration matrix; no physical device is required. A crash-looping
  emulator misreports as an app bug (`am start` says the launcher activity does not exist even
  though `adb install` succeeded) — confirm against a system app before blaming the APK.
- Android's `java.util.regex` is backed by ICU, not the JDK implementation, and ICU is stricter.
  A bare `}` or `]` outside a character class is a literal on desktop but a `PatternSyntaxException`
  on device. A top-level `val Regex(...)` that throws becomes an `ExceptionInInitializerError` that
  kills the whole screen on first touch, so JVM tests over that regex all pass while the feature is
  unopenable. Escape every literal brace and bracket, and treat any regex reachable from UI as
  device-verified only.
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
