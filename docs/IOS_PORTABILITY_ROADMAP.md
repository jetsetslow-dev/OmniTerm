# OmniTerm iOS Portability Roadmap

Status: active implementation. Product decisions and portable foundations are in progress; every
platform/device acceptance gate remains open until its required environment runs.

This document is intentionally agent-agnostic. A human contributor or any automation agent should
be able to select a task ID, inspect its prerequisites, implement only that scope, and produce the
listed acceptance evidence without relying on prior conversation context.

## 1. Objective

Ship an iOS version of OmniTerm while preserving one tested implementation of platform-neutral
terminal behavior, parsing, business rules, persistence semantics, and feature state machines.
Android-specific behavior must remain in the Android application. iOS-specific behavior must live
behind explicit contracts and follow Apple platform constraints rather than imitating Android APIs.

The recommended initial product architecture is:

- Kotlin Multiplatform (KMP) for shared domain logic, state machines, terminal emulation, parsers,
  persistence, and network-independent orchestration.
- Compose Multiplatform for reusable Android/iOS UI, migrated incrementally on Android.
- Thin Android and Swift/UIKit composition roots, with platform views where requirements demand them.
- Platform implementations for SSH/SFTP, secrets, biometrics, file handling, notifications,
  background lifecycle, and widgets.

Compose Multiplatform is approved in ADR 0002. Reconsidering it requires a replacement ADR backed by
measured accessibility, integration, build, or rendering evidence.

## 2. Current repository baseline

At the time this roadmap was written:

- The repository has `:app`, `:benchmark`, and Kotlin Multiplatform `:shared` Gradle modules.
- `app/src/main/java` contains 66 Kotlin production files; 36 import Android or AndroidX APIs.
- `AppViewModel.kt` is the largest architectural coupling point. It combines feature state,
  orchestration, Android lifecycle, Android services, intents, notifications, persistence, and UI
  snapshot state.
- The terminal emulator, UTF-8 decoder, tmux protocol/parser, many remote parsers, share-client
  contracts, health scoring, and several policies are already mostly platform-neutral.
- `SshTransport` is already an abstraction, but its production implementation uses JSch/JVM APIs
  and cannot be compiled for Kotlin/Native as-is.
- Persistence uses Room 2.8.4. Room supports KMP, but the current database construction, low-level
  SQLite usage, entities, DAOs, migrations, and tests must be audited before moving them.
- Android widgets, foreground services, notifications, biometrics, Keystore, activity results,
  file-provider intents, billing, ads, and review prompts are platform-specific by design.
- Pure concurrency policies already extracted during the Android audit include
  `OperationGeneration`, terminal read-only key policy, and terminal geometry validation.

Before beginning a task, re-check the baseline. File names and line counts are informative, not a
guarantee that the repository has not changed.

### Implementation status on this branch

“Foundation implemented” does not claim a simulator or physical-device gate ran.

| Task | Status | Remaining acceptance gate |
|---|---|---|
| IOS-001 | Accepted | ADR 0002 records Compose Multiplatform, protocol, and tmux decisions. |
| IOS-002 | Environment documented | Signed device build needs an Apple team, certificate, and test device. |
| IOS-003 | Implemented | Shared Android and iOS Arm64 compilation. |
| IOS-004 | Workflow implemented | First macOS CI run must compile the framework and run Xcode tests. |
| IOS-005 | Implemented | Each dependency PR still runs forced-refresh verification and release SBOM gates. |
| IOS-010–013 | Implemented foundation | Continue moving reusable regression tests into common tests. |
| IOS-020–021 | Implemented foundation | Wire production adapters incrementally at platform roots. |
| IOS-030 | Portable store implemented | `TerminalStore` runs the full session state machine against a fake transport; Android `AppViewModel` adoption and a real SSH adapter remain. |
| IOS-031 | Portable store implemented | App integration depends on the IOS-030 terminal/session split. |
| IOS-032 | Portable store implemented | `FilesStore` owns navigation, the transfer queue, conflicts, and cancellation; platform `LocalFileGateway` implementations remain. |
| IOS-033 | Portable stores implemented | Repository wiring remains platform composition work. |
| IOS-040 | Audit complete | `IOS_ROOM_KMP_AUDIT.md` keeps movement blocked by migration evidence. |
| IOS-041, IOS-042 | Not started | Blocked by IOS-040: no Room code moves before every unsupported API has a replacement and full migration evidence. |
| IOS-050 | Shared Ktor/WebDAV implemented | Android/iOS deterministic TLS server tests precede production replacement. |
| IOS-051 – IOS-053 | Not started | Engine selection is a macOS/device spike with its own ADR; the shared contracts and host-key trust policy are ready for it. |
| IOS-052 (trust policy) | Portable half implemented | `HostKeyTrust` enforces strict first-use, changed-key, and malformed-key rules; engine integration remains. |
| IOS-054, IOS-064, IOS-100 | Not started | Requires the project owner's written decision and an ADR before any implementation. |
| IOS-060 | Portable half implemented | `SecretVault` owns namespacing, the authentication gate, and typed failures; Keychain/Keystore adapters and locked-device tests remain. |
| IOS-061 | Adapter/policy implemented | IOS-060 secure storage and physical Face ID tests remain. |
| IOS-062 | Contracts/policies only | Production picker adapter depends on the platform half of IOS-032. |
| IOS-063 | Adapter/routing policy implemented | Device permission/tap reconciliation and store wiring remain. |
| IOS-065 | Portable half implemented | Secret-free snapshot, masking, staleness, and reload policy are shared; WidgetKit timelines and the App Group container remain. |
| IOS-070, IOS-080 | Shell/facade implemented | Xcode launch/test and generated-header review run on macOS. |
| IOS-071 – IOS-074 | Not started | Requires an Xcode gate; no iOS screen may be claimed from a Linux compile. |
| IOS-081 | Implemented foundation | Crash-report integration remains optional and consent-gated. |
| IOS-090 | Matrix published | `IOS_TEST_MATRIX.md` records executed rows and every deferred Apple-runtime row. |
| IOS-091 | Partial review published | `IOS_SECURITY_REVIEW.md` closes 14 findings in shared code; nine areas stay open pending Apple-runtime and SSH decisions. |
| IOS-092 | Portable half implemented | Bounded validation, import planning, and atomic apply are shared; the real backup file format binding remains. |
| IOS-093 | Manifest/checklist implemented | Signed archive validation requires the remaining IOS-091 open items. |
| IOS-094 | Not started | Depends on IOS-090/091/093 exit criteria. |

## 3. Complexity and risk scale

Complexity estimates engineering effort and number of moving pieces. Risk estimates the chance and
impact of regressions, data loss, security problems, platform rejection, or architectural lock-in.
They are rated independently.

| Rating | Meaning |
|---|---|
| Easy | Local, well-understood change; normally one small reviewable patch. |
| Medium low | Several files or build settings, but limited behavioral uncertainty. |
| Medium | Cross-layer change requiring tests and careful integration. |
| Medium high | Multiple subsystems, lifecycle/concurrency concerns, or notable migration work. |
| High | Security-, data-, protocol-, or architecture-sensitive; requires specialist review. |
| Very high | Fundamental subsystem replacement or difficult platform behavior with broad parity risk. |
| Requires president's signature | Deliberately humorous label for a decision with product-wide consequences that must not be inferred by an implementation agent. It requires explicit written approval from the project owner and an ADR before work begins. |

Spelling note: this document uses `Medium high` for the requested “midium high” category.

## 4. Mandatory working rules

These rules apply to every task in this roadmap:

1. Read the repository `AGENTS.md` before changing code.
2. Preserve existing Android behavior unless a task explicitly changes product behavior.
3. Never move Android types into `commonMain`. This includes `Context`, `Application`, `Uri`,
   `Intent`, `Parcelable`, Android `Bitmap`, Compose `mutableStateOf`, and AndroidX lifecycle types.
4. Shared code must not call platform APIs through global singletons. Use injected interfaces.
5. Shared state machines must expose immutable state and explicit events. Avoid public mutable
   collections and fire-and-forget global scopes.
6. Cancellation is part of every asynchronous API contract. Late results must not overwrite newer
   requests or state belonging to a different host/session/path.
7. Secrets must never enter logs, exceptions exposed to analytics, widget data, or unencrypted
   persistence.
8. Terminal protocol changes require deterministic JVM/common replay tests using sanitized byte
   streams. Do not rely only on device UI tests.
9. Database changes require migration evidence from every supported historical schema. Do not reset
   user databases or replace migration coverage with destructive fallback.
10. Dependency verification remains strict. Any dependency or plugin change must follow the
    repository checksum regeneration and verification policy.
11. Build-affecting final heads must pass `./scripts/local-pr-check.sh --full`. Run API 29 and API 35
    Room migration matrices on working emulators as required by `AGENTS.md`.
12. iOS changes require a macOS/Xcode gate. Linux can compile and test common/JVM code, but cannot
    claim iOS application or simulator validation.
13. Each pull request should normally implement one task or one explicitly identified slice of a
    task. Avoid combining module migration, behavior changes, and UI redesign.

## 5. Target module and source-set structure

The initial target structure is:

```text
Omniterm/
├── app/                         # Existing Android application and Android adapters
├── benchmark/                   # Existing Android benchmark module
├── shared/                      # Kotlin Multiplatform module
│   └── src/
│       ├── commonMain/kotlin/
│       │   ├── core/            # clocks, results, operation ownership, validation
│       │   ├── terminal/        # emulator, parser, snapshots, viewport/input policy
│       │   ├── domain/          # platform-free models and use cases
│       │   ├── data/            # repository contracts and shared persistence
│       │   └── feature/         # feature state stores and immutable UI state
│       ├── commonTest/kotlin/
│       ├── androidMain/kotlin/   # Android actuals/adapters only when shared module owns them
│       ├── androidUnitTest/kotlin/
│       ├── iosMain/kotlin/       # iOS actuals/adapters and Swift-facing facade
│       └── iosTest/kotlin/
└── iosApp/                      # Xcode project, SwiftUI/UIKit, app extensions
    ├── OmniTerm/
    ├── OmniTermTests/
    ├── OmniTermUITests/
    └── OmniTermWidget/
```

Start with one `:shared` module. Additional shared modules are justified only after measured build
or ownership problems appear. Premature module fragmentation increases Gradle/Kotlin Native build
cost and complicates dependency visibility.

## 6. Architecture boundaries

### Shared by design

- Terminal byte decoding, screen model, ANSI/tmux parsing, key encoding, scroll policy, history
  hydration policy, input ownership, and immutable terminal snapshots.
- Host, metric, alert, script, port-forward, network-share, bookmark, and configuration domain
  models after platform annotations/types are removed or made KMP-compatible.
- Input validation, formatting, sorting, filtering, health scoring, alert evaluation, backup schema,
  and import/export policy.
- Repository interfaces and feature state machines.
- Room database schema/DAOs if the Room KMP migration is accepted.
- HTTP protocol logic after conversion to a multiplatform client.

### Platform-specific by design

- SSH/SFTP engine implementation.
- Android foreground service and iOS lifecycle/background policy.
- Android Keystore and Apple Keychain.
- Android BiometricPrompt and Apple LocalAuthentication.
- Android notifications and Apple UserNotifications.
- Android RemoteViews/Glance widgets and Apple WidgetKit.
- File pickers, external viewers/share sheets, app links, shortcuts, and platform permissions.
- Billing, advertising, consent, review prompts, store metadata, and purchase restoration.
- Platform composition roots and any view that cannot meet requirements in shared Compose.

## 7. Summary task matrix

| ID | Task | Complexity | Risk | Depends on |
|---|---|---:|---:|---|
| IOS-001 | Record product and UI-sharing decisions | Easy | Requires president's signature | None |
| IOS-002 | Establish macOS/Xcode development and signing prerequisites | Medium low | Medium | IOS-001 |
| IOS-003 | Add minimal `:shared` KMP module | Medium | Medium | IOS-001 |
| IOS-004 | Add macOS shared/iOS CI | Medium high | Medium | IOS-002, IOS-003 |
| IOS-005 | Define dependency and checksum workflow for KMP artifacts | Medium | Medium high | IOS-003 |
| IOS-010 | Move terminal primitives to `commonMain` | Medium high | Medium high | IOS-003 |
| IOS-011 | Move generic policies, validation, and measurement logic | Medium low | Easy | IOS-003 |
| IOS-012 | Move remote models and parsers | Medium | Medium | IOS-003 |
| IOS-013 | Create shared clocks, dispatchers, logging, and ID contracts | Medium | Medium | IOS-003 |
| IOS-020 | Define platform capability and adapter contracts | Medium high | High | IOS-003, IOS-013 |
| IOS-021 | Define immutable feature-store conventions | Medium | Medium high | IOS-003, IOS-013 |
| IOS-030 | Extract terminal/session orchestration from `AppViewModel` | High | High | IOS-010, IOS-020, IOS-021 |
| IOS-031 | Extract fleet/monitoring orchestration | Medium high | Medium high | IOS-012, IOS-020, IOS-021 |
| IOS-032 | Extract files/transfers orchestration | High | High | IOS-012, IOS-020, IOS-021 |
| IOS-033 | Extract alerts/settings/scripts orchestration | Medium high | Medium | IOS-020, IOS-021 |
| IOS-040 | Audit Room schema and APIs for KMP compatibility | Medium | High | IOS-003 |
| IOS-041 | Move Room entities, DAOs, and database to shared | High | Very high | IOS-040, IOS-005 |
| IOS-042 | Add Android/iOS database builders and migration tests | High | Very high | IOS-041, IOS-004 |
| IOS-050 | Migrate shared HTTP operations to Ktor | Medium high | High | IOS-005, IOS-020 |
| IOS-051 | Select and prove an iOS SSH engine | High | Very high | IOS-001, IOS-002, IOS-020 |
| IOS-052 | Implement iOS SSH sessions and host-key trust | Very high | Very high | IOS-051, IOS-030 |
| IOS-053 | Implement iOS SFTP and transfer streaming | Very high | Very high | IOS-052, IOS-032 |
| IOS-054 | Decide and implement SMB/FTP/WebDAV parity | Very high | Requires president's signature | IOS-001, IOS-020, IOS-032 |
| IOS-060 | Implement secrets with Android Keystore/Apple Keychain | High | Very high | IOS-020, IOS-004 |
| IOS-061 | Implement biometric/app-lock adapters | Medium high | High | IOS-060, IOS-020 |
| IOS-062 | Implement file/document/external-viewer adapters | Medium high | Medium high | IOS-020, IOS-032 |
| IOS-063 | Implement iOS notifications and alert routing | Medium high | High | IOS-020, IOS-033 |
| IOS-064 | Define iOS background-session behavior | High | Requires president's signature | IOS-001, IOS-030, IOS-052 |
| IOS-065 | Implement WidgetKit cached fleet widget | High | High | IOS-031, IOS-042, IOS-063 |
| IOS-070 | Create the iOS shell application and shared facade | Medium high | Medium high | IOS-003, IOS-004, IOS-021 |
| IOS-071 | Implement iOS navigation and design system | High | Medium high | IOS-070 |
| IOS-072 | Implement performant iOS terminal renderer | Very high | Very high | IOS-010, IOS-030, IOS-052, IOS-070 |
| IOS-073 | Implement iOS terminal keyboard/read-only/accessibility | High | High | IOS-072 |
| IOS-074 | Implement remaining iOS feature screens | Very high | High | IOS-031 through IOS-033, IOS-071 |
| IOS-080 | Stabilize Swift-facing shared APIs | Medium high | High | IOS-021, IOS-070 |
| IOS-081 | Add cross-platform diagnostics and redaction | Medium | High | IOS-013, IOS-020 |
| IOS-090 | Build parity, stress, and lifecycle test matrix | High | High | All implemented features |
| IOS-091 | Perform security and privacy review | High | Very high | IOS-052 through IOS-065 |
| IOS-092 | Design Android-to-iOS data transfer/import | High | Very high | IOS-042, IOS-060 |
| IOS-093 | Prepare App Store metadata, privacy manifest, and review evidence | Medium high | High | IOS-091 |
| IOS-094 | Conduct staged beta and parity rollout | High | High | IOS-090, IOS-091, IOS-093 |
| IOS-100 | Reconsider the accepted Compose Multiplatform UI strategy | Very high | Requires president's signature | Measured platform evidence |

## 8. Detailed task specifications

### IOS-001 — Record product and UI-sharing decisions

Complexity: Easy
Risk: Requires president's signature

Purpose: prevent implementation agents from silently making product-defining assumptions.

Required decisions:

1. Confirm KMP shared logic plus native SwiftUI/UIKit as the initial direction, or explicitly choose
   Compose Multiplatform UI.
2. Define first-release feature parity: terminal, tmux resume, fleet monitoring, files, containers,
   tools, alerts, widgets, purchases, ads, and network shares.
3. Decide whether iOS is allowed to omit or defer SMB, FTP, background keepalive, ads, or widgets.
4. Define minimum iOS version and supported device classes.
5. Define whether Android and iOS share a product SKU/account entitlement model.

Deliverable:

- An ADR under `docs/adr/` recording decisions, alternatives, and owners.

Acceptance evidence:

- The ADR is approved by the project owner.
- Every deferred feature has explicit user-facing behavior, not a silent no-op.

Do not:

- Start a full shared-UI rewrite without this ADR.
- Promise Android-equivalent indefinite SSH background execution on iOS.

### IOS-002 — Establish macOS/Xcode development and signing prerequisites

Complexity: Medium low
Risk: Medium

Implementation steps:

1. Record the supported Xcode, macOS, Kotlin, Gradle, and JDK versions.
2. Provision an Apple developer team, development certificate, bundle identifiers, and test device.
3. Reserve bundle IDs for the app and widget extension.
4. Decide how CI receives signing material; simulator builds should not require production secrets.
5. Confirm an Apple Silicon simulator target and a physical iPhone target can be built.

Deliverables:

- `docs/IOS_BUILDING.md` with setup instructions and version matrix.
- Secret names and CI environment requirements documented without secret values.

Acceptance evidence:

- A clean macOS machine can follow the document and build an empty signed development shell.
- No signing key or provisioning profile is committed.

### IOS-003 — Add a minimal `:shared` KMP module

Complexity: Medium
Risk: Medium

Implementation steps:

1. Add a Kotlin Multiplatform library module named `shared`.
2. Configure Android, `iosArm64`, and `iosSimulatorArm64` targets.
3. Add empty `commonMain`, `commonTest`, `androidMain`, `androidUnitTest`, `iosMain`, and `iosTest`
   source sets.
4. Export a minimal framework that exposes a version or platform-neutral greeting solely to prove
   linkage.
5. Make `:app` depend on `:shared` without moving production behavior yet.
6. Keep all current Android checks and variants working.

Acceptance evidence:

- Android builds both product flavors.
- Common tests run on Linux.
- `iosSimulatorArm64` and `iosArm64` frameworks compile on macOS.
- Existing Android unit/lint/migration gates remain green.

Rollback:

- The module can be removed without touching feature code if toolchain integration proves blocked.

### IOS-004 — Add macOS shared/iOS CI

Complexity: Medium high
Risk: Medium

Implementation steps:

1. Add a macOS workflow pinned to full action SHAs.
2. Compile all shared Apple targets and run `commonTest`/native tests.
3. Build the iOS simulator app without production signing.
4. Add Xcode unit tests once the shell exists.
5. Cache only safe build artifacts; do not cache signing secrets.
6. Make the gate required before shared/iOS code can merge.

Acceptance evidence:

- A deliberately broken `iosMain` source fails the gate in a test branch.
- Exact final-head SHA is visible in CI evidence.
- Android workflows remain unchanged unless synchronization is required.

### IOS-005 — Define dependency and checksum workflow for KMP artifacts

Complexity: Medium
Risk: Medium high

Implementation steps:

1. Extend `gradle/verification-metadata.xml` for every new common, Android, iOS, test, and compiler
   artifact using the repository's forced-fresh workflow.
2. Update `scripts/refresh-verification-metadata.sh` so all KMP graphs are resolved and verified.
3. Ensure both existing CycloneDX release graphs still pass.
4. Determine how iOS-native/CocoaPods/SPM dependencies receive lockfiles, checksums, and license
   review.
5. Update notices/SBOM strategy for native libraries.

Acceptance evidence:

- Cold-cache strict verification passes.
- Metadata diff contains only intended artifacts.
- Native dependency versions and source repositories are locked.

### IOS-010 — Move terminal primitives to `commonMain`

Complexity: Medium high
Risk: Medium high

Initial candidates:

- `data/term/Utf8StreamDecoder.kt`
- `data/term/TerminalEmulator.kt`
- `data/term/TmuxControl.kt`
- `ui/TerminalKeyEncoder.kt`
- Platform-neutral parts of `ui/TerminalBufferText.kt`, `ui/TuiScrollRouter.kt`, and viewport logic

Implementation steps:

1. Move one cohesive type at a time, retaining its package initially to minimize churn.
2. Replace JVM-only APIs with common Kotlin equivalents only when semantics are identical.
3. Remove Compose annotations/state from viewport logic; provide Android UI adapters if necessary.
4. Move all corresponding JVM tests to `commonTest` or duplicate only when target behavior differs.
5. Run sanitized PTY/tmux replay fixtures on JVM and iOS simulator.

Acceptance evidence:

- Existing terminal tests pass unchanged in meaning.
- Common tests cover Unicode boundaries, ANSI control sequences, alt-screen enter/exit, resize,
  scrollback limits, capture adoption, and Kitty keyboard controls.
- Android terminal screenshots and stress behavior do not regress.

Do not:

- Rewrite the emulator while moving it.
- Add UIKit, SwiftUI, Compose, Android, Java I/O, or Foundation types to common terminal models.

### IOS-011 — Move generic policies, validation, and measurement logic

Complexity: Medium low
Risk: Easy

Candidates include operation generations, input validation, health scoring, measurement units,
terminal contrast math, host-display masking rules, backup filters, and alert breach policy.

Acceptance evidence:

- Every moved type has `commonTest` coverage.
- No output formatting changes occur without golden tests.
- Locale-sensitive formatting is either injected or explicitly platform-owned.

### IOS-012 — Move remote models and parsers

Complexity: Medium
Risk: Medium

Implementation steps:

1. Separate parsed domain models from Android/Room/UI annotations.
2. Move shell command output parsers and command builders that use only strings and domain models.
3. Retain existing malformed-input, indentation, OS-variant, and large-output regression fixtures.
4. Ensure parsers accept explicit locale/time dependencies where needed.

Acceptance evidence:

- Parser output is byte-for-byte or field-for-field equivalent on Android and iOS targets.
- No parser catches broad exceptions and silently returns misleading healthy state.

### IOS-013 — Create shared clocks, dispatchers, logging, and ID contracts

Complexity: Medium
Risk: Medium

Define injected contracts for:

- wall clock and monotonic clock;
- random/UUID generation;
- CPU, I/O, and main/UI dispatching where an API truly needs them;
- structured logging with mandatory redaction;
- platform and capability information.

Acceptance evidence:

- Common tests use deterministic clocks and IDs.
- Production code does not call `System.currentTimeMillis()`, Android logging, or platform UUID APIs
  from `commonMain`.

### IOS-020 — Define platform capability and adapter contracts

Complexity: Medium high
Risk: High

Required contracts:

- SSH command, streaming, shell, resize, and close lifecycle;
- SFTP/list/download/upload/progress/cancellation;
- secure secret storage;
- biometrics/app-lock authentication;
- notifications and deep-link payloads;
- application foreground/background lifecycle;
- external URL/file opening;
- document import/export;
- clipboard;
- widget snapshot publication;
- local-network permission/capability;
- purchases and entitlement;
- review/ads/consent as optional platform capabilities.

Contract requirements:

- Typed errors; do not pass Android exception messages through shared logic.
- Explicit cancellation and ownership.
- Progress callbacks or flows for operations that can take noticeable time.
- Capability result for unsupported platform behavior; never fake success.
- No platform object leakage through method signatures.

Acceptance evidence:

- Fake implementations can drive common state-store tests.
- Android adapters can wrap existing implementations without behavior change.

### IOS-021 — Define immutable feature-store conventions

Complexity: Medium
Risk: Medium high

Adopt one convention before splitting `AppViewModel`:

- one immutable state data class per feature;
- one event/action entry point or a small explicit method surface;
- `StateFlow` for observable state;
- scoped coroutine ownership and deterministic cancellation;
- operation IDs/generations for latest-wins loaders;
- no callback that can complete twice;
- navigation effects separated from persistent state;
- platform effects requested through typed effect interfaces.

Acceptance evidence:

- A reference store demonstrates load, refresh, cancellation, error, retry, and progress tests.
- Swift consumption of state and cancellation is proven in a small Xcode test.

### IOS-030 — Extract terminal/session orchestration from `AppViewModel`

Complexity: High
Risk: High

Scope:

- connection state and phases;
- session registry and focused session;
- tmux create/resume/reconnect/history hydration;
- terminal input ownership/read-only policy;
- resize ordering and snapshot publication;
- split-session model;
- connection errors and host-key approval requests.

Implementation strategy:

1. Characterize current behavior with tests before moving code.
2. Extract a `TerminalStore` that depends on SSH, clock, dispatcher, notification, and persistence
   contracts.
3. Keep Android foreground-service and activity/navigation effects outside the store.
4. Adapt existing Android UI to the new state without redesigning it.
5. Delete migrated state from `AppViewModel`; do not keep two mutable sources of truth.

Acceptance evidence:

- Existing terminal unit, replay, Robolectric, and instrumentation tests pass.
- Tests cover host switch during connect, cancellation, stale completion, reconnect, large tmux
  history plus resize, split-pane ownership, and cleanup.
- A fake SSH transport can run the complete common session state machine.

### IOS-031 — Extract fleet/monitoring orchestration

Complexity: Medium high
Risk: Medium high

Scope:

- host selection and probe ownership;
- telemetry scheduling and history;
- process/service/log/container loaders;
- alert evaluation inputs;
- refresh progress and stale-result rejection.

Acceptance evidence:

- Polling uses an injected lifecycle/capability policy.
- Overlapping refreshes cannot clear or overwrite newer progress/results.
- Battery and background decisions are platform adapters, not common assumptions.

### IOS-032 — Extract files/transfers orchestration

Complexity: High
Risk: High

Scope:

- directory navigation and sorting;
- SFTP/share browser state;
- bookmarks;
- transfer queue, progress, cancellation, conflict resolution, and cross-endpoint copy;
- preview/edit/open/download requests as platform effects.

Acceptance evidence:

- All transfer operations expose indeterminate or determinate progress.
- Switching host/path during a load cannot publish stale entries.
- Cancellation closes streams and temporary resources.
- Conflict decisions and aggregate progress have common tests.

### IOS-033 — Extract alerts/settings/scripts orchestration

Complexity: Medium high
Risk: Medium

Split at least:

- `AlertsStore`;
- `SettingsStore`;
- `ScriptsStore`;
- `BackupStore`;
- `NetworkToolsStore` where practical.

Acceptance evidence:

- Stores contain no Android APIs or Compose state.
- Long operations surface progress.
- Settings persistence failures are observable and do not claim success.

### IOS-040 — Audit Room schema and APIs for KMP compatibility

Complexity: Medium
Risk: High

Implementation steps:

1. Inventory every entity, DAO method, transaction, converter, callback, and direct SQLite API.
2. Mark blocking DAO methods that must become `suspend` for non-Android targets.
3. Identify Android-only Room builder features and migration-test dependencies.
4. Decide whether Room KMP or SQLDelight will own the shared schema. Default recommendation: Room
   KMP, because the repository already uses Room 2.8.4 and has a valuable migration matrix.
5. Write an ADR if selecting SQLDelight or another replacement.

Deliverable:

- A compatibility table covering every DAO/database file and required change.

Acceptance evidence:

- No database code is moved until every unsupported API has an explicit replacement.

### IOS-041 — Move Room entities, DAOs, and database to shared

Complexity: High
Risk: Very high

Implementation steps:

1. Move schema definitions incrementally while preserving table/column names and version.
2. Convert required DAO methods to suspending APIs and update callers.
3. Use the KMP SQLite driver required by Room.
4. Preserve all exported Android schemas.
5. Do not combine schema evolution with the module move unless unavoidable.

Acceptance evidence:

- Android opens databases created by the prior release without reset.
- All historical Android migrations pass API 29 and API 35.
- Query behavior and transaction atomicity tests pass in common/Android tests.

Rollback:

- Keep the last Android database implementation available until compatibility evidence is complete.

### IOS-042 — Add platform database builders and migration tests

Complexity: High
Risk: Very high

Implementation steps:

1. Android builder uses the existing application database location.
2. iOS builder uses an Application Support path with correct file-protection behavior.
3. Add iOS tests for fresh creation, reopen, concurrency, transaction rollback, and every migration
   representable from exported schema fixtures.
4. Verify app/widget shared-container needs before choosing the final database location.
5. Document backup/exclusion behavior for database and WAL/SHM files.

Acceptance evidence:

- Android and iOS produce semantically equivalent repository results.
- Migration failure never falls back to destructive recreation.

### IOS-050 — Migrate shared HTTP operations to Ktor

Complexity: Medium high
Risk: High

Implementation steps:

1. Inventory Retrofit/OkHttp calls and separate protocol models from transport annotations.
2. Introduce Ktor core/content negotiation in common code.
3. Use an Android engine and Darwin engine in their platform source sets.
4. Preserve TLS validation, redirect, timeout, authentication, proxy, and cancellation behavior.
5. Keep WebDAV semantics covered by integration tests.

Acceptance evidence:

- Contract tests run against a local deterministic HTTP/TLS server on Android and iOS.
- Certificate failures remain failures; no permissive trust manager is introduced.

### IOS-051 — Select and prove an iOS SSH engine

Complexity: High
Risk: Very high

This is a time-boxed technical spike, not production integration.

Evaluation requirements:

- maintained upstream and acceptable license;
- modern OpenSSH keys including Ed25519;
- encrypted private keys;
- password and keyboard-interactive authentication;
- strict known-host verification and changed-key detection;
- jump host and HTTP/SOCKS proxy feasibility;
- PTY shell, resize, binary-safe streaming, cancellation, and disconnect classification;
- exec, streaming exec, SFTP, tunnels/port forwards;
- arm64 device and simulator support;
- reproducible dependency pinning and SBOM/license story.

Spike acceptance evidence:

- Connect to a disposable test SSH server from an iOS simulator and physical device.
- Demonstrate strict first-use approval, reconnect, PTY resize, UTF-8 streaming, large output, and
  clean resource teardown.
- Produce an ADR comparing candidates and recording missing capabilities.

Do not:

- Choose a library solely because it connects once.
- disable host-key checking to simplify the spike.

### IOS-052 — Implement iOS SSH sessions and host-key trust

Complexity: Very high
Risk: Very high

Implementation steps:

1. Implement every shared SSH contract using the selected engine.
2. Match Android error classification without exposing engine-specific strings as business logic.
3. Implement strict known-host persistence and atomic approval/rejection.
4. Implement bounded output/input queues with backpressure.
5. Implement resize ordering, cancellation, cleanup, jump/proxy support selected for v1, and network
   transition behavior.

Acceptance evidence:

- Shared SSH contract suite passes against Android and iOS adapters.
- Security tests reject changed keys, wrong host aliases, and malformed key material.
- Stress tests cover large output, repeated connect/disconnect, network loss, and tmux resume.

### IOS-053 — Implement iOS SFTP and transfer streaming

Complexity: Very high
Risk: Very high

Implementation steps:

1. Implement list/stat/read/write/mkdir/rename/delete and recursive operations.
2. Preserve byte counts and determinate progress when total size is known.
3. Support cancellation without leaving partial files presented as complete.
4. Use atomic destination replacement where the operation promises it.
5. Apply file-size and memory bounds used by previews/editors.

Acceptance evidence:

- Cross-platform transfer contract tests pass against the same SSH fixture.
- Interrupted transfers and conflicts produce correct recoverable state.

### IOS-054 — Decide and implement SMB/FTP/WebDAV parity

Complexity: Very high
Risk: Requires president's signature

Reason for approval requirement: current Android libraries are JVM-oriented and may not have safe,
maintained Kotlin/Native equivalents. Supporting every protocol can dominate the iOS schedule and
expand the security surface.

Decision options:

1. Ship WebDAV first and defer SMB/FTP with explicit product messaging.
2. Implement native iOS adapters for all three protocols.
3. Remove a protocol from both platforms through a separately approved deprecation plan.

Acceptance evidence after a decision:

- ADR defines v1 parity and security ownership.
- Each included protocol has TLS/authentication, cancellation, large-transfer, traversal, and
  malformed-server tests.

### IOS-060 — Implement secrets with Android Keystore and Apple Keychain

Complexity: High
Risk: Very high

Implementation steps:

1. Define a shared secret-reference model; domain/database rows should reference secrets rather
   than carry plaintext when feasible.
2. Keep or adapt Android Keystore behavior behind the contract.
3. Implement iOS Keychain storage with explicit accessibility class and device-migration policy.
4. Define behavior for device lock, biometric-set changes, reinstall, backup restore, and missing
   items.
5. Redact all identifiers and values from logs.

Acceptance evidence:

- Secrets never appear in Room rows, widgets, crash logs, or analytics beyond explicitly approved
  encrypted backup behavior.
- Keychain/Keystore tests cover locked device, deletion, replacement, and authentication failure.

### IOS-061 — Implement biometric/app-lock adapters

Complexity: Medium high
Risk: High

Acceptance evidence:

- Cancellation cannot unlock the app.
- Biometric failure falls back only according to configured policy.
- App foreground/background timeout behavior is deterministic and tested.
- Privileged pending actions are cleared on cancellation and lifecycle teardown.

### IOS-062 — Implement file/document/external-viewer adapters

Complexity: Medium high
Risk: Medium high

Scope:

- import/export through document picker;
- security-scoped URL lifetime;
- temporary preview files;
- external open/share sheet;
- clipboard;
- image decode bounds;
- cleanup and filename sanitization.

Acceptance evidence:

- Large files stream rather than load entirely into memory unless bounded preview behavior requires
  it.
- Cancellation releases security-scoped resources and deletes incomplete temporary files.

### IOS-063 — Implement iOS notifications and alert routing

Complexity: Medium high
Risk: High

Implementation steps:

1. Map shared alert payloads to UserNotifications.
2. Define permission-denied behavior.
3. Route notification taps to the correct host/alert without embedding secrets.
4. Reconcile delivered notifications when alerts resolve or are acknowledged.

Acceptance evidence:

- Deep links are validated and cannot select arbitrary unsupported resources.
- Notifications contain masked host information when privacy settings require it.

### IOS-064 — Define iOS background-session behavior

Complexity: High
Risk: Requires president's signature

iOS normally suspends ordinary applications in the background and does not offer a general
equivalent to Android's foreground service for indefinite SSH. This is a product constraint, not
something to bypass with an unrelated background mode.

Required decisions:

- Does iOS detach persistent tmux sessions immediately on background, after a short grace period,
  or when suspension is detected?
- How are non-tmux sessions described to users before backgrounding?
- Which monitoring/alert behavior requires a server-side component or push service?
- Are Live Activities useful, and if so, what truthful cached state can they display?

Deliverable:

- ADR and user-facing lifecycle specification.

Acceptance evidence:

- No unsupported background mode is declared.
- App Store review notes accurately explain background behavior.
- Resume/reconnect is tested after short and long suspension, process termination, and network
  changes.

### IOS-065 — Implement WidgetKit cached fleet widget

Complexity: High
Risk: High

Implementation steps:

1. Define a secret-free shared widget snapshot schema.
2. Store snapshots in an App Group container accessible to app and extension.
3. Build native WidgetKit timelines and configuration.
4. Show explicit loading, stale, empty, and error states.
5. Reload timelines only when displayed data changes; do not promise exact periodic refresh.

Acceptance evidence:

- Widget works when the main app is not running.
- No SSH credentials or unmasked sensitive host data enter the App Group.
- Manual/configuration actions show immediate feedback permitted by WidgetKit.

### IOS-070 — Create the iOS shell application and shared facade

Complexity: Medium high
Risk: Medium high

Implementation steps:

1. Add an Xcode project under `iosApp/`.
2. Integrate the shared framework locally.
3. Expose a deliberately small composition root/facade to Swift.
4. Implement dependency construction in Swift/iOS Kotlin adapters.
5. Render one shared state value and deliver one event back to shared code.

Acceptance evidence:

- Simulator and physical device launch.
- Shared objects are retained and released without lifecycle leaks.
- Xcode tests can replace adapters with fakes.

### IOS-071 — Implement iOS navigation and design system

Complexity: High
Risk: Medium high

Implementation steps:

1. Define native tab/navigation behavior for compact and regular width.
2. Keep alerts reachable on every screen.
3. Define colors, typography, cards, progress, error, empty, and confirmation components.
4. Support Dynamic Type, VoiceOver, Reduce Motion, high contrast, keyboard navigation, and iPad
   resizing.
5. Avoid pixel-copying Android when native iOS conventions provide a better equivalent.

Acceptance evidence:

- Accessibility audit passes for the shell navigation skeleton.
- Every long-running action component supports progress and cancellation/disabled state.

### IOS-072 — Implement a performant iOS terminal renderer

Complexity: Very high
Risk: Very high

Implementation approach:

- Keep terminal emulation and immutable snapshots shared.
- Build a native renderer using UIKit/CoreText initially unless measurement proves another approach
  superior. SwiftUI may host the view, but should not force one SwiftUI view per terminal cell.
- Render only the visible range plus minimal overscan.

Required behavior:

- monospace glyph measurement, wide/combining Unicode, ANSI colors/styles, cursor, selection,
  links, touch scrolling, copy, resize, rotation, split panes, and large scrollback;
- snapshot generations prevent stale frames;
- resumed tmux history cannot overwrite a newer geometry or live screen;
- no full-buffer conversion or layout on the main thread.

Acceptance evidence:

- Deterministic visual fixtures for representative snapshots.
- Performance measurements for sustained output and 10k/50k-line histories.
- Memory remains bounded during large tmux resume.
- Rotation and keyboard resize stress tests do not blank or corrupt the screen.

### IOS-073 — Implement iOS terminal keyboard/read-only/accessibility

Complexity: High
Risk: High

Scope:

- software keyboard input and composition;
- hardware keyboard translation;
- terminal special-key bar;
- paste confirmation and bracketed paste;
- sticky modifiers;
- read-only mode that dismisses keyboard and blocks all mutating input below the UI layer;
- touch scroll plus Page Up/Page Down navigation in read-only mode;
- VoiceOver semantics that do not read an unbounded terminal buffer.

Acceptance evidence:

- Shared input-policy tests and iOS UI tests agree.
- CJKV composition, emoji, combining marks, Ctrl/Alt, function keys, and external keyboards are
  tested.
- Read-only mode cannot be bypassed by paste, hardware keyboard, or accessory controls.

### IOS-074 — Implement remaining iOS feature screens

Complexity: Very high
Risk: High

Implement in vertical slices, suggested order:

1. Hosts and connection editor.
2. Terminal/session picker.
3. Fleet and monitoring.
4. Alerts.
5. SFTP/files/transfers.
6. Containers and remote tools.
7. Scripts, keys, backup, settings, and about.
8. Included network-share protocols.

Each slice must include progress, empty/error/retry state, accessibility, store tests, UI tests, and
Android parity confirmation before starting the next slice.

### IOS-080 — Stabilize Swift-facing shared APIs

Complexity: Medium high
Risk: High

Implementation steps:

1. Keep exported names intentional and small.
2. Wrap flows/coroutines in a Swift-friendly observation and cancellation layer.
3. Avoid exposing generic types or Kotlin implementation details that produce unusable Swift APIs.
4. Map sealed errors/state to stable Swift-consumable representations.
5. Document threading and ownership of every exported callback/object.

Acceptance evidence:

- Swift tests consume the API without reflection, unsafe casts, or knowledge of internal packages.
- Breaking export changes are detected by an API snapshot or equivalent review artifact.

### IOS-081 — Add cross-platform diagnostics and redaction

Complexity: Medium
Risk: High

Scope:

- typed operation and connection events;
- terminal/session lifecycle diagnostics without terminal contents;
- crash log redaction shared where possible;
- platform-specific crash/report integrations;
- opt-in policy and retention limits.

Acceptance evidence:

- Automated redaction tests cover passwords, private keys, hostnames/IPs under privacy mode,
  commands, terminal text, and file paths.

### IOS-090 — Build parity, stress, and lifecycle test matrix

Complexity: High
Risk: High

Required matrix:

- Common unit tests on JVM and iOS simulator.
- Android existing unit/lint/migration/instrumentation gates.
- iOS unit and UI tests on supported minimum and current iOS runtimes.
- Physical iPhone smoke tests.
- SSH fixture tests for password/key/proxy/jump/host-key changes.
- Large output, large tmux history, resize/rotation, split panes, and repeated resume.
- Network loss, app background/suspension/termination, low memory, and locked-device secrets.
- Large file transfers, cancellation, insufficient disk, and conflict resolution.
- Widget stale/loading/error behavior.

Acceptance evidence:

- `docs/IOS_TEST_MATRIX.md` lists exact executed and deferred coverage.
- A suite is never reported as passing when a target or class was excluded.

### IOS-091 — Perform security and privacy review

Complexity: High
Risk: Very high

Review areas:

- SSH library provenance, CVEs, cryptographic algorithms, host-key policy, and key parsing;
- Keychain accessibility and backup/sync behavior;
- database/file protection and App Group exposure;
- logs, widgets, notifications, clipboard, screenshots, previews, and temporary files;
- local-network permissions and App Transport Security;
- backup encryption/KDF bounds;
- native dependency SBOM and licenses;
- threat model for malicious servers and crafted terminal streams.

Acceptance evidence:

- Written threat model and findings disposition.
- No critical/high finding remains unowned at beta release.

### IOS-092 — Design Android-to-iOS data transfer/import

Complexity: High
Risk: Very high

Implementation steps:

1. Use the existing encrypted backup format only after confirming every field is platform-neutral.
2. Version the schema and preserve bounded parsing/KDF/decompression protections.
3. Define which secrets can migrate and whether Keychain items must be re-created.
4. Test partial selections, ID remapping, deduplication, unsupported features, and rollback.
5. Never introduce cloud sync implicitly as part of portability.

Acceptance evidence:

- Android export imports into iOS and iOS export imports into Android using sanitized fixtures.
- Failed import leaves the destination unchanged.

### IOS-093 — Prepare App Store metadata, privacy manifest, and review evidence

Complexity: Medium high
Risk: High

Scope:

- privacy manifest and required-reason APIs;
- local-network, notifications, biometrics, files, and tracking disclosures;
- export-compliance/cryptography answers;
- App Store screenshots and accessibility information;
- background behavior review notes;
- purchase restoration if monetization is included;
- support/privacy URLs and deletion expectations.

Acceptance evidence:

- Archive validation passes with no unresolved privacy/signing warnings.
- Store claims match actual background, widget, and monitoring behavior.

### IOS-094 — Conduct staged beta and parity rollout

Complexity: High
Risk: High

Stages:

1. Internal terminal-only build against disposable hosts.
2. Internal full-data build with migration/import testing.
3. Small TestFlight group with diagnostics and explicit known limitations.
4. Expanded TestFlight after crash, reconnect, and transfer thresholds are met.
5. App Store phased release with rollback/disable strategy for remote features.

Exit criteria must be defined numerically before each stage: crash-free sessions, connection success,
tmux resume success, transfer failure/cancellation correctness, and no security-critical findings.

### IOS-100 — Reconsider the accepted Compose Multiplatform UI strategy

Complexity: Very high
Risk: Requires president's signature

This task occurs only after a native iOS vertical slice provides measured evidence.

Required comparison:

- development velocity;
- terminal renderer performance;
- keyboard/IME/accessibility quality;
- native navigation and widget integration;
- binary size and startup;
- debugging and team skills;
- cost of maintaining two UIs versus platform-quality compromises.

Deliverable:

- Replacement ADR approving a specific alternative to the accepted Compose Multiplatform strategy.

Do not:

- migrate UI merely to maximize percentage of shared lines.

## 9. Recommended execution order

### Milestone A — Prove the build boundary

Tasks: IOS-001 through IOS-005.

Exit condition: Android consumes a minimal shared framework; iOS device/simulator frameworks build in
required CI; dependency verification remains strict.

### Milestone B — Share low-risk logic

Tasks: IOS-010 through IOS-013.

Exit condition: terminal primitives, parsers, and generic policies run from `commonMain` with parity
tests on JVM and iOS simulator.

### Milestone C — Establish architecture

Tasks: IOS-020, IOS-021, then IOS-030 through IOS-033 incrementally.

Exit condition: `AppViewModel` is a thin Android composition/navigation layer rather than the owner of
portable business logic.

### Milestone D — Share durable data

Tasks: IOS-040 through IOS-042.

Exit condition: Android migrations remain intact and iOS can create/reopen/query the same logical
schema safely.

### Milestone E — Prove core iOS value

Tasks: IOS-051, IOS-052, IOS-060, IOS-070, IOS-072, IOS-073.

Exit condition: an iPhone can securely connect to a host, verify its key, run an interactive terminal,
resume tmux with large history, resize, scroll, use read-only mode, and tear down cleanly.

### Milestone F — Add product breadth

Tasks: IOS-031 through IOS-033 adapters, IOS-050, IOS-053 through IOS-065, IOS-071, IOS-074.

Exit condition: the explicitly approved v1 parity set is implemented with honest unsupported states.

### Milestone G — Release readiness

Tasks: IOS-080 through IOS-094.

Exit condition: security, privacy, migration, stress, TestFlight, and store gates pass with no hidden
platform exclusions.

## 10. First implementation slice

The safest first coding slice is deliberately small:

1. Complete IOS-001.
2. Add the empty `:shared` module from IOS-003.
3. Move `Utf8StreamDecoder` and its tests into `commonMain`/`commonTest`.
4. Make Android import it from `:shared` with no behavior change.
5. Compile the iOS simulator framework and execute the same decoder tests there.
6. Run the complete Android `--full` validation and API 29/API 35 migration matrices.

Do not begin with `AppViewModel`, SSH, Room, or the terminal UI. The first slice exists to prove the
toolchain, dependency verification, test layout, and Android compatibility before higher-risk work.

## 11. Per-task handoff template

Every contributor should leave the following in the pull request or task report:

```text
Task ID:
Scope implemented:
Scope explicitly not implemented:
Architectural assumptions:
Files/modules changed:
Behavior preserved or intentionally changed:
Tests added:
Commands executed:
Platforms actually exercised:
Suites/classes excluded or deferred:
Security/privacy considerations:
Migration/data considerations:
Known risks and follow-up task IDs:
Rollback approach:
```

An implementation is incomplete when its required platform could not be exercised. Report that as
deferred or blocked; never infer success from another platform.

## 12. Primary platform references

Use current official documentation while implementing; do not treat this list as a version lock:

- Kotlin Multiplatform overview and project structure:
  <https://kotlinlang.org/docs/multiplatform/kmp-overview.html>
- Kotlin Multiplatform iOS integration methods:
  <https://kotlinlang.org/docs/multiplatform/multiplatform-ios-integration-overview.html>
- Adding KMP to an existing Android project:
  <https://developer.android.com/kotlin/multiplatform/migrate>
- Room Kotlin Multiplatform setup and limitations:
  <https://developer.android.com/kotlin/multiplatform/room>
- Apple background execution modes:
  <https://developer.apple.com/documentation/Xcode/configuring-background-execution-modes>
- Apple Keychain Services:
  <https://developer.apple.com/documentation/security/keychain-services>
- WidgetKit update and timeline model:
  <https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date>
