# ADR 0003: Gate UI on a real device, and make every device fixture host independent

- Status: accepted
- Date: 2026-08-02

## Context

A release shipped with the Compose editor completely unopenable. `ComposeBuilder.kt` declared

```kotlin
private val YAML_INTERPOLATION = Regex("""\$\{[^}]*}|\$[A-Za-z_][A-Za-z0-9_]*""")
```

Android backs `java.util.regex` with **ICU**, not the JDK implementation, and ICU is the stricter of the two: a bare `}` outside a character class is a literal on desktop and a `PatternSyntaxException` on device. The pattern is a top-level `val`, so the throw lands in the file class's static initialiser and every entry into the file dies with `ExceptionInInitializerError` — not just port validation. The user, not a test, found it.

The fix is one escaped brace (`fix/host-scan-hint-text`). This ADR is about why nothing caught it, because the regex was the smallest part of the problem.

### Why the existing tests could not catch it

Three independent failures had to line up, and all three were invisible.

**1. JVM tests cannot see this class of defect.** `ComposeCorpusRegressionTest` is 348 lines written specifically to cover this regex, and it passed. It runs on the desktop JDK, which accepts the pattern that ICU rejects. No amount of additional JVM coverage over that regex would have helped. A test that cannot fail on the defect it targets is worse than no test, because it produces confidence.

**2. The guard already existed and had never been run.** `ComposeBuilderStateSyncTest` imports `VisualEditor` from the same file, so touching it triggers the same static initialiser. Verified: restoring the unescaped brace and running it on API 35 reproduces the reported stack trace exactly. But `scripts/local-pr-check.sh` filtered the connected step to `-Pandroid.testInstrumentationRunnerArguments.package=com.jetsetslow.omniterm.data`, so **no UI instrumentation test ran in any gate, ever.**

**3. Opt-in suites report success when they run nothing.** Every `E2e*` suite is gated behind `assumeTrue(<instrumentation argument>)`. A plain `connectedAndroidTest` skips all of them and prints `BUILD SUCCESSFUL`. Green output certified nothing, and the count of tests actually executed was never checked.

### What the device suites turned out to depend on

Once UI instrumentation was actually run, the suites that should have provided coverage were themselves unrunnable by anyone but their author:

- `E2eComposeBuilderUiStressTest` read a >300 KB, 400-service Compose file from `/home/tempadmin/omniterm-e2e/corpus/07-large-stack/compose.yml`. No generator for it existed anywhere in the repository.
- `E2eNetworkToolsTest` expected ports 21, 445, 8080 and 8081 open on the target, plus two seeded `E2E` port-forward rows and a live HTTP origin.
- `E2eAppSurfaceStressTest` assumed the account's home was `/home/<user>`; the fleet's containers use `/config`.
- `TerminalPaneFocusSemanticsTest` had been failing since PR #41 and nobody knew, because it had never run in a gate.

A fourth dependency was subtler and is the reason this ADR has a rule of its own: the Network Tools port scan asserted **port 22 was open on the target**, which is really an assertion that *the developer's workstation runs sshd*. It passed on the machine that happened to satisfy it and would fail on a clean one, for reasons having nothing to do with the app. A host dependency is invisible precisely on the machine that satisfies it.

## Decision

**Screen coverage is a local API 34+ gate.** `scripts/local-pr-check.sh` now runs the whole instrumentation package instead of the data layer alone. Lab-dependent suites still self-skip via `assumeTrue`, so a bare emulator works.

**The hosted PR job deliberately stays data-layer-only.** It is pinned to API 29, which predates the ICU-backed `java.util.regex` (API 34). Running UI suites there would add runtime and still pass on this exact defect class. Hosted runners also cannot boot API ≥ 36 (see the emulator note in `AGENTS.md`) and may lack KVM for 35. The two configurations are intentionally different; the divergence is commented in both files so nobody "aligns" them by narrowing the local run.

**Every fact a test asserts comes from a fixture this repository controls.** The repository's own disposable fleet is the *default*; a personal lab is the override, never the reverse.

**Large inputs are generated and committed, not hand-written.** `ComposeLargeStackFixture` builds the 400-service draft as a pure function of the service index and renders it through the app's own `generateDockerComposeYaml`.

Generating through the production renderer is a requirement, not a convenience. The stress test asserts `renderComposeYaml(parse(text)) == text`, so the fixture must already be in exactly the form the renderer emits. A hand-authored file drifts the first time formatting changes, and the resulting failure impersonates a parser bug.

## Consequences

### Immutability is enforced, not conventional

The fixture (391,768 chars, 400 services) lives at `scripts/test-hosts/fixtures/large-stack/compose.yml` and is held in place three ways: committed so everyone reads identical bytes; digest-compared by `ComposeLargeStackFixtureTest`, which reports the first differing line rather than dumping a 391 KB diff and requires an explicit `-Domniterm.regenerateFixture=true` to change; and bind-mounted `:ro` so a test cannot mutate its own input.

That flag needs Gradle plumbing. A bare `-Domniterm...` on the command line reaches only the daemon, never the test JVM, so without the forwarding now in `app/build.gradle.kts` the documented regeneration command silently no-ops while appearing to succeed.

The same round-trip invariant the device test spends minutes reaching is now also checked in milliseconds by a JVM test in the default gate, so drift is caught on every push.

### The fleet gained real services

`E2eNetworkToolsTest`'s tunnel assertions could not be satisfied by a sibling container. Both seeded forwards resolve `127.0.0.1:8080` **as resolved on the SSH host** — the local forward targets it, and the dynamic tunnel issues `CONNECT 127.0.0.1:8080` from the far end. So `labhttp` joins `direct`'s network namespace via `network_mode: "service:direct"` and answers on that host's own loopback. Ports 21 and 445 are TCP listeners for a connect scan and **nothing more**; no test asks them to speak FTP or SMB, and a suite that needs those protocols needs real daemons.

`E2eLabSeedTest` gained a `port` argument. `ServerEntity.port` defaults to 22, so seeding without it pointed the entire lab at the developer's own sshd.

### A latent fleet defect, fixed

`lscr.io/linuxserver/openssh-server` ships `AllowTcpForwarding no`. Every `-L` and `-D` tunnel was refused, and the bastion jump path to `internal-a` documented at the top of `docker-compose.yml` — the only way to prove `proxyType=ssh` carries traffic — could never have worked. `fixtures/ssh-init/10-allow-tcp-forwarding`, mounted at `/custom-cont-init.d`, fixes both hosts.

Two traps are recorded in that script because each cost a debugging cycle:

- sshd runs with `-f /config/sshd/sshd_config`, **not** `/etc/ssh/sshd_config`. Patching only the latter logs a confident `AllowTcpForwarding yes` and changes nothing. The image's `Include /etc/ssh/sshd_config.d/*.conf` is commented out, so a drop-in is ignored too.
- The client-visible symptom misdirects. JSch closes the client stream inside its own connect-failure path, so the SOCKS error reply is never delivered and the caller sees the connection drop mid-handshake rather than a SOCKS failure code. It reads like a handshake bug in the app. The honest error (`administratively prohibited`) only appears when driving `ssh -D` from a shell.

### `TerminalPaneFocusSemanticsTest` was not testing what it claimed

Two defects, both hidden by never running. Each pane laid out zero-height — the frame wraps its content, the content was empty, and `Row` aligns children to the top rather than stretching them — so `assertIsDisplayed` failed correctly. And it drove focus with `performClick()`, but `TerminalPaneFrame` carries no pointer-input modifier; it exposes focus through `semantics { onClick { … } }` for accessibility services, and real taps are handled by the terminal content it wraps. The synthesized gesture was consumed by nothing, so **the pane switching the test exists to verify was never exercised**. It now drives the semantics action.

### Standing obligations

A green on-device test proves nothing until it has been seen to fail. When fixing a device-only defect, re-run the guard against the unfixed code and confirm it fails for the expected reason.

Never cite a connected run as screen coverage without naming the instrumentation arguments passed and the number of tests that actually executed. Gradle also reinstalls the APK per `connectedAndroidTest` invocation, which wipes app data and destroys any seeded host — provision and exercise within one invocation, or install both APKs once and drive `adb shell am instrument` directly.

`./scripts/test-hosts.sh down` discards host keys by design, so the app's trust store must be cleared before re-seeding against a recreated fleet.

## Verification

On API 35, against the disposable fleet, with no machine-specific arguments beyond host and credentials:

| Suite | Before | After |
| --- | --- | --- |
| `E2eComposeBuilderUiStressTest` | unrunnable (fixture on one machine) | passes, 16.4 s |
| `E2eNetworkToolsTest` | failed at the port scan | passes, 16.6 s |
| `E2eAppSurfaceStressTest` | failed at the SFTP listing | passes |
| `TerminalPaneFocusSemanticsTest` | failing since #41, never run | passes |

`./scripts/local-pr-check.sh --full`: 938 JVM unit tests and 45 connected tests, zero failures, 26 opt-in lab suites correctly skipped.
