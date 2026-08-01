# OmniTerm iOS test matrix (IOS-090)

This document records what has actually been executed for the iOS port and what is deferred, per
`AGENTS.md`: a suite is never reported as passing when a target, class, or platform was excluded.

Last updated: 2026-08-01, on branch `feature/ios-compose-port`.

## 1. Host used for the recorded runs

| Property | Value |
|---|---|
| OS / arch | Linux x86_64 (Ubuntu 26.04) |
| JDK | Temurin 17 |
| Android SDK | repo-local `.android-sdk`, compileSdk 37 |
| Xcode / macOS | **not available** — every Apple-runtime row below is deferred |
| Physical iPhone | **not available** |

## 2. Executed

| Suite | Command | Result |
|---|---|---|
| Shared common tests on the JVM host | `./gradlew :shared:allTests` | 57 tests, 0 failures |
| Apple-target compilation of `commonMain`/`commonTest`/`iosMain` | `:shared:compileKotlinIosSimulatorArm64`, `:shared:compileTestKotlinIosSimulatorArm64` (run as part of `:shared:allTests`) | compiles to klib |
| Android unit tests (both flavors) | `./scripts/local-pr-check.sh --full` | see the PR/preflight log for the exact head |
| Android lint (both flavors) | `./scripts/local-pr-check.sh --full` | as above |
| Dependency verification, forced refresh | `./scripts/refresh-verification-metadata.sh --verify` | as above |

Shared coverage executed on the JVM host:

| Area | Test class | Covers |
|---|---|---|
| Terminal/session orchestration (IOS-030) | `TerminalStoreTest` | first-use host-key approval before any shell opens, rejection, changed-key reporting, host switch mid-connect closing the superseded shell, read-only input blocking, split-pane input ownership and single-pane ownership, resize-versus-tmux-history race, tmux leave/resume bookkeeping, disconnect during reconnect, output delivery, `close()` releasing every PTY |
| Files/transfers orchestration (IOS-032) | `FilesStoreTest` | directory sorting with directories first, parent-path bounds, stale listing rejection after navigation, determinate download progress, explicitly indeterminate unknown-size transfers, cancellation closing the sink and deleting the partial file, conflict overwrite/keep-both/skip, upload source closure, aggregate progress, observable listing failure |
| Host-key trust (portable half of IOS-052) | `HostKeyTrustTest` | never auto-trusting an unknown host, changed-key reporting without overwriting stored trust, alias separation by port and hostname case, malformed/MD5/short fingerprint rejection, per-alias forget |
| Secret handling (portable half of IOS-060) | `SecretVaultTest` | namespaced keys, no secret or key name in diagnostics, missing item as `NotFound` rather than empty success, failed authentication never reaching storage, rotation keeping the reference, orphan cleanup, key-material wipe |
| Widget snapshot policy (portable half of IOS-065) | `WidgetSnapshotPolicyTest` | secret-free lines, privacy masking, staleness window, timeline reload only when displayed data changes |
| Cross-platform backup transfer (portable half of IOS-092) | `BackupTransferTest` | schema and KDF bounds, duplicate/invalid rows, add/update/unchanged classification, partial selection, credentials never transported, rejected envelope leaving the destination unchanged |
| Earlier foundation work | `TerminalPortabilityTest`, `RefreshStoreTest`, `SafetyPoliciesTest`, `RedactionTest`, `PlatformServicesTest`, `WebDavMultistatusParserTest`, `OmniTermSharedTest` | see IOS-010 – IOS-021 |

## 3. Deferred — requires macOS/Xcode

`iosSimulatorArm64Test` is disabled by the Kotlin Gradle plugin on a Linux host
("simulator tests require macOS"), so **no shared test has been executed on an Apple runtime**.
Apple-target *compilation* on Linux proves the common and `iosMain` sources are Kotlin/Native-clean;
it does not link a framework, run a test binary, or exercise any Apple API.

| Row | Blocked on | Task |
|---|---|---|
| `commonTest` on iOS simulator | macOS CI runner | IOS-004 |
| Framework link (`linkDebugFrameworkIosArm64`, simulator) | macOS + Xcode | IOS-004 |
| Xcode unit/UI tests for the shell app | macOS + Xcode | IOS-070 |
| Physical iPhone smoke tests | Apple team, certificate, device | IOS-002 |
| Keychain behavior: locked device, deletion, replacement, auth failure | iOS runtime | IOS-060 |
| Face ID / LocalAuthentication behavior | physical device | IOS-061 |
| UserNotifications permission-denied and tap routing | iOS runtime | IOS-063 |
| WidgetKit timeline, App Group container | iOS runtime | IOS-065 |
| Terminal renderer performance and visual fixtures | iOS runtime | IOS-072 |
| Keyboard/IME/VoiceOver behavior | iOS runtime | IOS-073 |

## 4. Deferred — requires an SSH engine decision

IOS-051 has not been run: no iOS SSH library has been selected, so nothing below can be executed on
either platform's iOS adapter.

| Row | Task |
|---|---|
| Shared SSH contract suite against a real iOS adapter | IOS-052 |
| Password / key / encrypted-key / keyboard-interactive authentication | IOS-052 |
| Jump host and HTTP/SOCKS proxy | IOS-052 |
| Large output, repeated connect/disconnect, network loss, tmux resume stress | IOS-052 |
| SFTP transfer contract tests against the same SSH fixture | IOS-053 |
| Interrupted transfer and insufficient-disk recovery | IOS-053 |

The shared state machines above are proven against a fake `SshAdapter`/`SftpAdapter`. That fixture
validates ownership, cancellation, and ordering; it does **not** validate protocol behavior, and no
result in section 2 may be read as SSH or SFTP evidence.

## 5. Deferred — requires an owner decision

| Row | Task | Reason |
|---|---|---|
| Background/suspension lifecycle tests | IOS-064 | Product decision on background behavior is unmade |
| SMB/FTP/WebDAV parity tests | IOS-054 | v1 protocol scope is unmade |
| Room migration matrix on iOS | IOS-041, IOS-042 | Schema move is blocked by `IOS_ROOM_KMP_AUDIT.md` |

## 6. Android rows that must stay green

These are unchanged by the iOS work and remain the responsibility of the existing gates:

- Room migration matrix on API 29 (required CI) and API 35 (local, KVM host).
- Robolectric native-runtime classes: excluded on Linux ARM64, exercised on x86_64 CI.
- Release SBOM generation for both `playStoreRelease` and `openSourceRelease` graphs.
