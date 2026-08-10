# OmniTerm Kotlin → Flutter migration handoff

Snapshot date: 2026-08-09 (Asia/Kolkata)

This is the current source of truth for continuing the migration. `MIGRATION.md` and older parts of
`docs/CONTINUATION_PROMPT.md` contain useful history, but their implementation-status sections became
stale during this large uncommitted iteration. Verify code and tests rather than trusting an old
checkbox.

## Read this first

- Read `/home/sbvino/Omniterm/AGENTS.md` in full and obey it. The device, disposable-fleet, API 35
  migration, dependency-verification, and exact-head gates are mandatory.
- Do **not** reset, clean, checkout, stash, rebase, or bulk-stage either worktree. The current changes
  are uncommitted and include user changes as well as migration work.
- Do **not** use `git add -A`. Inspect and stage explicit paths only when the user asks for commits.
- Do **not** commit or push yet. The available local gates are green, but required Docker-fleet E2E,
  action-level parity, Kotlin-worktree exact-head validation, iOS validation, and hosted exact-head
  gates have not been completed.
- Do not touch, kill, bypass, or reconfigure the user's personal NFS mounts merely to start Docker.
- Flutter is not on the default `PATH`; use `/home/sbvino/sdks/flutter/bin/flutter` or export that
  directory into `PATH`.
- The machine is an x86_64 SER8 with 24 GB installed RAM, not a Raspberry Pi. The observed runtime
  environment exposed about 18 GiB RAM plus 8 GiB swap and working KVM. Use parallelism sensibly,
  but retain the required hosted 4 GiB Gradle heap settings.

## User's required outcome

Audit the *entire* Kotlin and Flutter apps and finish the migration with exact visual and functional
parity for every screen, subtab, state, and action. Do not merely finish old unchecked tasks: code
that was labelled complete may be partial or wrong. If the audit finds a Kotlin bug, fix it in both
the Flutter port and the separate Kotlin parity branch. Keep iOS first-class. Security takes
priority, and validation must be honest about platform skips.

This outcome is **not yet fully proven**. A broad amount of implementation is present and the new
Flutter API 35 surface sweep is green, but action-by-action parity, fleet-backed behavior, the API 35
Room matrix, iOS native builds, and all final repository gates remain.

## Worktrees and immutable snapshot

### Flutter migration

- Path: `/home/sbvino/Omniterm`
- Branch: `migration-to-flutter`
- HEAD before these uncommitted changes: `1800150890b8c21bb372040316310a18b613dcd6`
- Current tracked diff: 85 files, approximately 13,327 insertions and 2,589 deletions, plus many new
  untracked implementation/test/native files.
- Nothing from this iteration is committed or pushed.

### Kotlin parity defects

- Path: `/home/sbvino/Omniterm-kotlin-parity`
- Branch: `fix/kotlin-parity-defects`
- HEAD before the uncommitted fix: `3364de03f94915b59c1b31c6b2427b17dc1ffed2`
- Current diff: only `app/src/main/java/com/jetsetslow/omniterm/ui/ToolsScreen.kt`, 6 insertions and
  1 deletion.
- Nothing from this iteration is committed or pushed.

At snapshot time, `git diff --check` and `git diff --cached --check` passed in both worktrees. There
were no staged changes.

## Preserve known user changes

At minimum, do not overwrite these choices while resolving overlaps:

- Alerts intentionally use a periodic timer.
- The Settings AMOLED condition contains a user-owned change.
- The dirty worktree predates the latest audit in places. Attribute changes from the diff; do not
  assume every dirty line was authored in one session.

## What the Flutter branch currently contains

The branch contains a much broader port than old migration documents suggest. Inspect the exact
diff before altering it. Major implemented areas include:

- SSH/SFTP transport behavior, cross-host SFTP transfer, file editing, terminal/tmux handling,
  terminal links/input, tunnels, and a bounded dynamic SOCKS server.
- Infrastructure screens and actions, Docker Compose builder/parser/rendering, large-stack work,
  service/container actions, telemetry, server forms/cards, and responsive layouts.
- Network tools: port scan, LAN discovery and hostname lookup, speed test, device-side ping and
  traceroute work, measurement units, and platform-aware command execution.
- Network shares: Android SMB plus pure-Dart SMB work for Apple platforms, FTP and WebDAV clients,
  forms, validation, and tests.
- Backup/restore, selective restore, ID remapping, local-security exclusions, database transaction
  safety, settings/bookmark remapping, and rollback tests.
- App lock/security preferences, external-action guards, permissions, battery-saver integration,
  crash logging, diagnostics, distribution handling, ads/licensing, shortcuts, Android widgets,
  iOS quick actions, and an initial iOS WidgetKit extension.
- Broad screen parity work across Servers, Shell, SFTP, Infra, Tools, Alerts, Backup, Settings,
  About, Auth Keys, and the shared scaffold/navigation.
- Flutter CI/release workflow edits and Android/iOS native project integration.

Do not treat this list as proof that every action is correct. It is an inventory of the current
branch, not a completion certificate.

## High-confidence implementation details and regression guards

### Backup and restore safety

Current behavior is designed to match the Kotlin security model:

- Restore profiles before hosts/shares and remap source IDs to newly inserted IDs.
- Null orphan profile/SSH-key references rather than linking to an unrelated row.
- Preserve an old network-share ID only long enough to remap settings.
- Remap bookmark settings and skip orphan keys.
- Exclude device-local security state: PIN, lock/biometrics state, failure counters, lockout/grace
  state, and last SFTP paths.
- Selective host restore filters profiles and SSH keys.
- Database restore uses a Drift transaction and rolls back on failure.
- Focused backup/security/collision/filter/bookmark/rollback suites previously reported 77 passing
  tests. Re-run them on the final head; do not rely only on this historical result.

### Dynamic SSH tunnel

- `ssh_tunnel_manager.dart` includes an owned bounded SOCKS4/4a/5 server.
- Handshake timeout is 15 seconds, DNS resolution is sent through SSH where applicable, and teardown
  is explicit.
- Focused tunnel/wire tests previously reported 46 passing tests.
- The repository-controlled real SSH fleet test is still blocked by Docker; unit/wire results are
  not a substitute for it.

### LAN hostname discovery

- Resolution order is PTR → mDNS → NetBIOS to match the Kotlin behavior.
- Wire parsers are bounded and lookup concurrency is capped at 16 workers.
- The focused network suite at that point reported 75 passing tests. Later network work reported 71
  focused tests; re-run the current aggregate rather than adding these counts together.

### Lifecycle defect fixed and proven on API 35

`ShellState.updateLicenseEntitlement()` used to notify providers during Flutter's build phase via
`_RuntimeBindings.didChangeDependencies`. The unfixed code reproduced the device-only failure.
`lib/main.dart` now coalesces initial license/app/alert/external-action/navigation synchronization
into a post-frame `_scheduleRuntimeSync` call. The API 35 walkthrough passed after the fix.

### Zero-sized route scaffold fixed

The real AppCore scaffold body was inside a positioned `Stack` child while a zero-sized permission
host was the only non-positioned child. Every route therefore received a 0×0 viewport even though
shallow tests appeared green.

- `lib/ui/app_scaffold.dart` now gives the real body the viewport via an expanded stack.
- Each `_ScreenBody` has a stable `ValueKey('screen.${screen.name}')` root.
- `integration_test/app_walkthrough_test.dart` now taps/ensures navigation, asserts the target route,
  and checks that the Tools grid is non-zero.
- The complete API 35 walkthrough passed 6/6 after this correction.

### Navigation equality fixed

`NavigationController.navigateTo` now does nothing when navigating to the current screen, matching
Compose mutable-state equality semantics. A unit guard is present; its focused run passed 22 tests.
One earlier combined shell command also named a nonexistent `test/app_scaffold_test.dart`, so that
*combined command* was not green even though all 22 navigation tests passed. Do not misreport it.

### Android backup rules fixed

Repeated debug installs exposed a real `FlutterSecureStorage` key-mismatch warning: Android had
restored encrypted preferences without their Keystore key. The Flutter Android manifest now uses:

- `android:allowBackup="false"`
- `android:dataExtractionRules="@xml/data_extraction_rules"`
- `android:fullBackupContent="@xml/backup_rules"`

Explicit database/shared-preference/file exclusions were added under
`android/app/src/main/res/xml/`. This follows the Kotlin device-local security policy. A repeated
install/logcat run on the final code is still required to confirm the warning no longer appears.

### Ping and traceroute parity fixed

Flutter's prior “Ping” was a TCP port connection, while Kotlin runs device-side ICMP and supports
continuous operation until stopped.

- New `lib/data/network/device_network_command.dart` provides a platform command runner using only
  trusted fixed system binary paths.
- Android uses `/system/bin/ping`; Linux/macOS use fixed candidate paths. iOS reports the capability
  as unavailable rather than pretending TCP is ICMP.
- stdout/stderr are merged safely, commands are stoppable, the target alphabet matches Kotlin, and
  process metacharacters are rejected.
- `NetworkViewModel` streams raw ICMP output, supports counts `0..9999`, stops cleanly, prefers a
  native traceroute, and uses TTL-stepped ping as a fallback with hop parsing.
- The Ping UI now has host/count/start/stop/raw selectable output and labels the operation as
  device-side ICMP.
- The speed-test dropdown was made width-safe with expansion and ellipsis.
- The focused network suite passed 71 tests after this work.

The actual Android system ping action has not yet been exercised end-to-end by an integration test;
the surface suite only opens the tab. Add or run a fixture-safe device action test.

### Responsive scaffold and surface sweep

The first stress run found an online-server-card horizontal overflow; the card's status/actions are
now two wrapping groups. Its focused suite passed 12 tests.

The next stress run found 21 landscape overflows per theme because the Kotlin-style top bar, free
banner, and bottom navigation consumed too much vertical space. `app_scaffold.dart` now switches to
an adaptive scrollable landscape side rail while preserving all seven destinations and stable
`nav.*` keys, OT home, Awake, Alerts badge, FREE/Unlock, 48 px controls, and the bottom ad. Portrait
keeps the Kotlin-style layout.

New `integration_test/app_surface_stress_test.dart`:

- Creates a repository-controlled “online” host fixture at `127.0.0.1:1` and stops the status
  probe/poller so online branches remain deterministic. It never uses a personal host.
- Sweeps all 15 routes and 32 subtabs in light, dark, and AMOLED themes, in portrait and landscape
  (about 282 route/subtab/config checks).
- Collects render exceptions so one overflow does not hide the rest.
- Restores settings and orientation while its view models are still alive.

Final command and result on API 35 x86_64 emulator `emulator-5554`:

```bash
cd /home/sbvino/Omniterm/flutter_app
/home/sbvino/sdks/flutter/bin/flutter test \
  integration_test/app_surface_stress_test.dart \
  -d emulator-5554 \
  --dart-define=OMNITERM_PLAY_STORE=true
```

Result: `01:00 +1: All tests passed!`

This proves screens/subtabs lay out and open under those configurations. It does **not** prove every
button's backend behavior, fleet interactions, dialogs, destructive confirmations, billing/store
behavior, widget actions, or iOS native behavior.

## Kotlin bug fixed in both implementations

The Kotlin privacy disclosure always implied Google Play services even for the open-source
distribution. The Flutter About/privacy content was made distribution-aware, and the Kotlin parity
worktree has the corresponding conditional disclosure change in `ToolsScreen.kt`. The focused
Kotlin compile passed after that edit. Re-run the Kotlin branch's required tests before committing.

Profile restore was also inspected because it looked suspicious, but Kotlin already had the correct
source-ID → new-ID remapping. Do not make a cosmetic no-op change there.

## Validation already observed

Treat results below as iteration evidence, not final exact-head release evidence:

| Check | Observed result | What remains |
|---|---|---|
| Flutter analyzer | `flutter analyze --fatal-infos` clean on the current worktree | Re-run after further edits |
| Complete Flutter host suite | 1,886 tests passed in 1m42s after correcting one stale About assertion | Device/fleet/native behavior is separate |
| Flutter debug Android build | Passed earlier in the iteration | Re-run both distribution defines |
| API 35 walkthrough | 6/6 passed | Keep as regression gate |
| API 35 Flutter surface stress | 1 integration test, complete sweep, passed in 60 s | Actions/fleet/iOS not covered |
| Focused network tests | 71 passed after ping/traceroute work | Real Android ICMP action still needed |
| Focused server tests | 12 passed | Fleet behavior still needed |
| Focused navigation tests | 22 passed | Do not cite the malformed combined command |
| Focused backup tests | 77 passed at backup milestone | Re-run current suite/final head |
| Focused SOCKS tests | 46 passed at tunnel milestone | Real disposable SSH fleet still needed |
| Root `local-pr-check.sh --full` | Passed on Linux/x86_64: unit/lint, forced-fresh dependency verification, both release SBOM graphs, and API 35 connected package | 26 opt-in E2E tests skipped |
| API 35 Kotlin connected run | 72 tests finished, 0 failed, 26 skipped | Skipped E2E is not surface/fleet evidence |
| `git diff --check` | Passed in both worktrees at handoff | Re-run before commits |
| Kotlin focused compile | Passed after privacy fix | Full Kotlin gates still needed |

The first complete Flutter run found one stale test expecting the old phrase `no telemetry`; the
production copy intentionally says `usage telemetry` and matches the corrected Kotlin disclosure.
The test now asserts both `usage telemetry` and that source builds omit billing/ads. Its focused file
passed 8/8, followed by the clean 1,886-test full run.

The root full preflight exercised the API 35 non-E2E connected package, including the repository's
Room/UI instrumentation, but it was invoked without the opt-in fleet arguments because Docker was
unavailable. Gradle initially announced 46 tests and ultimately reported `Finished 72 tests`, with
26 named `E2e*` skips and zero failures. Never cite this as Kotlin screen/fleet coverage. There is
still no disposable-fleet E2E, macOS/iOS build, Kotlin parity-worktree full preflight, or hosted
exact-head CI result.

### Commit decision

The user authorized a commit only “if all is good.” No commit was created: the 26 required opt-in
E2E tests were skipped, Docker remained blocked, the Kotlin parity worktree had not run its own full
exact-head gate, and the broader action/iOS audit remained incomplete. This is a deliberate safety
decision, not an accidental omission. Once those conditions are resolved, re-run the exact-head
gates and commit each branch separately with explicit staging.

## Active blocker: Docker fleet

At handoff:

- `docker.service`: inactive/dead
- required `mount-all.service`: still activating/start
- it is blocked on the user's inaccessible personal NFS mounts through `/bin/mount -a`

Do not kill the mount process, bypass the dependency, edit the user's mounts, or substitute a
personal lab. Wait for the external mount state to resolve or ask the user for authority. Once
Docker is legitimately available, use the repository fleet exactly as `AGENTS.md` requires.

## Remaining work, in priority order

### 1. Re-orient and make a parity ledger

- Read the entire current `AGENTS.md`, this handoff, relevant Kotlin source, Flutter source, tests,
  and native projects.
- Inspect `git status`, `git diff`, and untracked files in both worktrees before editing.
- Build a screen/subtab/action/state ledger directly from Kotlin code and compare it to Flutter.
  Include dialogs, empty/loading/error/offline/online/licensed/unlicensed states, rotations, back
  behavior, long-press/context actions, validation/error copy, accessibility labels, colors,
  spacing, icons, and platform-specific branches.
- Do not trust `MIGRATION.md` §§18/21/22 as current without reconciling them to code; they predate
  large parts of this dirty iteration.

### 2. Finish action-level device coverage

- Add/run fixture-safe API 35 tests for buttons and flows the surface sweep only opens.
- Specifically execute Android ICMP ping start/output/stop and traceroute/fallback behavior.
- Reinstall repeatedly and inspect logcat to prove the secure-storage backup key mismatch is gone.
- Exercise external actions, permission denial/grant, alert lifecycle, app lock, backup/restore,
  SFTP editor/copy/move/delete, terminal/tmux, infra actions, shares, compose validation/deploy,
  widgets/shortcuts, ads/licensing gates, and failure states against repository fixtures.
- Confirm every device-only regression guard fails for the expected reason against the unfixed
  implementation, as required by `AGENTS.md`.

### 3. Run the disposable SSH/Docker fleet when unblocked

Use the repository scripts and default fixture home `/config`:

```bash
cd /home/sbvino/Omniterm
scripts/test-hosts.sh up
```

Run the required Kotlin instrumentation surface sweep with the opt-in arguments, ensuring the host
is provisioned and exercised in the same app-data lifetime:

```text
-e omniterm_e2e_surfaces yes
-e omniterm_e2e_sftp_home /config
```

Also run Flutter's real SSH/SFTP/tunnel/infra/share/action E2E against repository fixtures. Record
the exact test count and every explicit skip; a plain `connectedAndroidTest` does not count as E2E
coverage.

### 4. Complete platform and native verification

- Run the API 35 Room migration matrix locally on the current x86_64 KVM host, in addition to the
  hosted API 29 gate. Do not raise hosted CI merely to match local.
- Verify Android open-source and Play Store builds/defines, manifests, package IDs, permissions,
  backup rules, widgets, shortcuts, billing/ads/consent, signing inputs, and release output.
- On macOS with Xcode, build/test the iOS project. The manual `SceneDelegate.swift` and
  `project.pbxproj` edits are unverified on Linux.
- Verify iOS quick actions, permission flows, SMB/FTP/WebDAV, external links, background behavior,
  and WidgetKit. The current WidgetKit work does not yet have per-widget server configuration.
- Audit release CI: current Flutter release workflow work may still be Android-only.
- Confirm product IDs and real store integration for billing; unit fakes are insufficient.

### 5. Resolve dependency/tooling warnings

Every Android build currently warns that `flutter_file_dialog`, `flutter_foreground_task`,
`home_widget`, and `patrol` apply an old Kotlin Gradle Plugin. Builds currently succeed, but a future
Flutter release will reject this. Audit upstream/current versions and upgrade safely if compatible.
If dependencies change, follow the repository's strict forced-fresh checksum and SBOM process; do
not weaken dependency verification.

### 6. Run full local gates on the exact final code

From the appropriate roots, with the emulator/fleet available:

```bash
cd /home/sbvino/Omniterm/flutter_app
export PATH="/home/sbvino/sdks/flutter/bin:$PATH"
flutter analyze --fatal-infos
flutter test

cd /home/sbvino/Omniterm
./scripts/local-pr-check.sh --full
git diff --check
git diff --cached --check

cd /home/sbvino/Omniterm-kotlin-parity
./scripts/local-pr-check.sh --full
git diff --check
git diff --cached --check
```

Confirm the exact final head passes build/test, Room migration validation, both release SBOM graphs,
CodeQL, dependency review, and repository security checks. Report exact platform skips. Never call a
Gradle run green if opt-in instrumentation was skipped.

### 7. Reconcile documentation, then commit deliberately

- Update `MIGRATION.md` implementation status and progress log from the actual final code. Its old
  claims that iOS SMB, Compose/SFTP/speed/platform integrations were absent are stale.
- Keep this handoff or replace it with a new dated handoff containing exact remaining gaps.
- Review all workflow and native-project diffs carefully.
- Split the Kotlin privacy fix into the Kotlin parity branch and Flutter migration work into the
  Flutter branch. Stage explicit paths only.
- Do not push or open/update a PR until the user asks and exact-head required evidence is available.

## Known risks requiring explicit closure

- “Every screen opens” is now well evidenced on Flutter Android API 35, but “every action matches”
  is not.
- iOS native code and Xcode project changes have not been built on macOS.
- iOS WidgetKit lacks per-widget server configuration.
- Flutter release automation may still be Android-only.
- Billing product IDs and store behavior are not verified against real stores.
- Plugin distribution graphs and old-KGP warnings need review.
- Docker-backed Kotlin/Flutter E2E and real SSH tunnel behavior remain blocked.
- The root API 35 connected package and Room/UI instrumentation passed, but every opt-in E2E guard
  remained skipped without the Docker fixture arguments.
- The complete Flutter host suite and root full local preflight are green; the separate Kotlin
  parity worktree, fleet E2E, native iOS, real store/plugin behavior, and hosted exact-head
  SBOM/checksum/security/CI gates remain outstanding.
- `infra_view_model.dart` appears as binary in Git's diff because the committed baseline contains
  five NUL bytes; the current working copy contains zero NUL bytes and is normal Dart text. Review
  it with `git diff --text` so this large change is not accidentally missed.

## Useful immediate commands

```bash
cd /home/sbvino/Omniterm
git status --short
git diff --stat
git diff --text -- flutter_app/lib/ui/view_model/infra_view_model.dart
git worktree list

cd /home/sbvino/Omniterm-kotlin-parity
git status --short
git diff -- app/src/main/java/com/jetsetslow/omniterm/ui/ToolsScreen.kt

adb devices -l
systemctl is-active docker.service mount-all.service
```

The API 35 emulator was still available at handoff as `emulator-5554`, launched from the
`omniterm-api35` AVD with KVM. Re-check its health rather than assuming it survived the handoff.
