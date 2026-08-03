# OmniTerm → Flutter Migration (running log)

**This file is the single source of truth for the migration.** If context is lost, compacted, or
the session restarts, read this file top-to-bottom first — it is written so that work can resume
without re-deriving anything.

- **Branch:** `migration-to-flutter` (created from `origin/main` at `7a4e836`… see `git merge-base`)
- **Started:** 2026-08-03
- **Status:** Phase 5 in progress (transport, trust, pool, key parsing, FS abstraction done; SFTP + tunnels next) — see [Progress log](#14-progress-log)

---

## 1. Goal & constraints (from the user, verbatim intent)

1. Migrate the **entire** OmniTerm project from native Android (Kotlin + Jetpack Compose) to **Flutter**.
2. **Keep all functionality, layout and architecture the same.**
3. The Flutter app must be **truly multiplatform — iOS as a first-class target**, not Android-only.
4. Research best practices online rather than guessing.
5. Work should run in a **loop that retries every 15 minutes** if a usage/rate limit is hit, and
   resume automatically from this document.
6. **End-to-end UI automation** covering every feature, click, and navigation path (in *and* out of
   each screen) — see §11.
7. **Port the CI/CD pipeline** to the Flutter app — see §12.
8. **Use the best open-source tooling available** for testing, validation and feature enrichment —
   see §13.
9. **Fix major bugs and flaws found in the Kotlin while porting**, rather than reproducing them.
   This *amends* requirement 2: behaviour still may not drift casually, but a genuine defect is
   corrected in the port and recorded here so the change is traceable. See §15.

### Consequence of constraint 3 (important, drives everything)

Because iOS is a required target, the migration **cannot** use the common "add-to-app + Pigeon
platform channels back into the existing Kotlin engine" strategy. Kotlin/JVM libraries
(JSch, smbj, Apache Commons Net, Room, Android Keystore) do not run on iOS. Therefore:

> **The core engine must be ported to pure Dart.** Platform channels are used only for genuinely
> platform-specific OS integration (biometrics, secure storage, notifications, widgets, billing),
> where a maintained plugin already abstracts both platforms.

---

## 2. Environment (needed to do anything)

Flutter is **not on the default PATH**. Every shell must export it:

```bash
export PATH="/home/sbvino/sdks/flutter/bin:$PATH"
```

| Item | Value |
|---|---|
| Flutter SDK | `3.44.8` stable, installed at `/home/sbvino/sdks/flutter` |
| Dart | `3.12.2` |
| Flutter project | `/home/sbvino/Omniterm/flutter_app` |
| Legacy Android project | `/home/sbvino/Omniterm/app` (**kept as the reference implementation**) |
| iOS deployment target | 13.0 (scaffolded default; raise if a plugin demands it) |
| Android JDK/SDK | see `MEMORY.md` → dev-machine-toolchain |

The legacy `app/` module is deliberately **not deleted** while the migration is in flight — it is
the behavioural reference for every port, and deleting it would destroy the only spec for 59k LOC
of nuanced behaviour. It is removed only in the final cut-over step.

---

## 3. Source inventory (what must be migrated)

Legacy root: `app/src/main/java/com/jetsetslow/omniterm/`. Totals: **175 Kotlin files, ~59,400 LOC**
(plus 101 test files).

Status legend: ⬜ not started · 🟨 in progress · ✅ done · ⚠️ blocked/risk

### 3.1 Core / entry (709 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `MainActivity.kt` | 417 | `lib/main.dart` + `lib/app.dart` | ⬜ |
| `SessionService.kt` | 292 | `lib/platform/session_service.dart` (flutter_foreground_task; iOS differs — see §6) | ⬜ |

### 3.2 Data layer (3,546 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `data/RemoteParsers.kt` | 1604 | `lib/data/remote_parsers.dart` + `lib/data/remote_commands.dart` | 🟨 parsers ✅; `RemoteCommands` strings pending |
| `data/Daos.kt` | 362 | `lib/data/dao/*.dart` (Drift) | ⬜ |
| `data/AppDatabase.kt` | 352 | `lib/data/app_database.dart` (Drift, schema **v22**) | ✅ |
| `data/Entities.kt` | 271 | `lib/data/tables.dart` (**14** tables) | ✅ |
| `data/CrashLog.kt` | 206 | `lib/data/crash_log.dart` | ⬜ |
| `data/RemoteModels.kt` | 203 | `lib/data/remote_models.dart` | ✅ |
| `data/AppRepository.kt` | 191 | `lib/data/app_repository.dart` | ⬜ |
| `data/BiometricCryptoGate.kt` | 167 | `lib/platform/biometric_gate.dart` (local_auth) | ⬜ |
| `data/HealthScoring.kt` | 119 | `lib/domain/health_scoring.dart` | ✅ |
| `data/SecretStore.kt` | 71 | `lib/platform/secret_store.dart` (flutter_secure_storage) | ⬜ |

### 3.3 Network shares (705 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `data/shares/RemoteFsClient.kt` | 132 | `lib/data/shares/remote_fs_client.dart` (abstraction) | ✅ |
| `data/shares/WebDavFsClient.kt` | 217 | `lib/data/shares/webdav_fs_client.dart` (dio + xml) | ⬜ |
| `data/shares/FtpFsClient.kt` | 183 | `lib/data/shares/ftp_fs_client.dart` (ftpconnect) | ⬜ |
| `data/shares/SmbFsClient.kt` | 173 | `lib/data/shares/smb_fs_client.dart` | ⚠️ **blocked — see §7.1** |

### 3.4 SSH (1,984 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `data/ssh/JschSshTransport.kt` | 533 | `lib/data/ssh/dartssh_transport.dart` + `terminal_close.dart` | ✅ |
| `data/ssh/SshTunnelManager.kt` | 333 | `lib/data/ssh/ssh_tunnel_manager.dart` | ⬜ |
| `data/ssh/SshHostKeyTrust.kt` | 315 | `lib/data/ssh/ssh_host_key_trust.dart` | ✅ |
| `data/ssh/JschSftp.kt` | 294 | `lib/data/ssh/dartssh_sftp.dart` | ⬜ |
| `data/ssh/JschSession.kt` | 219 | `lib/data/ssh/ssh_private_key.dart` (key validation); connection setup absorbed into `dartssh_transport.dart` | ✅ |
| `data/ssh/SshSessionPool.kt` | 144 | `lib/data/ssh/ssh_session_pool.dart` (+ `async_lock.dart`) | ✅ |
| `data/ssh/SshTransport.kt` | 123 | `lib/data/ssh/ssh_transport.dart` (interface) | ✅ |
| `data/ssh/CappedTextBuffer.kt` | 23 | `lib/data/ssh/capped_text_buffer.dart` | ✅ |

### 3.5 Terminal (1,486 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `data/term/TerminalEmulator.kt` | 1177 | `lib/data/term/terminal_emulator.dart` — see §7.2 | ⬜ |
| `data/term/TmuxControl.kt` | 232 | `lib/data/term/tmux_control.dart` | ⬜ |
| `data/term/Utf8StreamDecoder.kt` | 77 | `lib/data/term/utf8_stream_decoder.dart` | ✅ |

### 3.6 UI (36,033 LOC — the bulk)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `ui/AppViewModel.kt` | **12310** | `lib/ui/view_model/` (split by feature, see §5.2) | ⬜ |
| `ui/ToolsScreen.kt` | 5005 | `lib/ui/screens/tools/` | ⬜ |
| `ui/SftpScreen.kt` | 3474 | `lib/ui/screens/sftp/` | ⬜ |
| `ui/ShellScreen.kt` | 3175 | `lib/ui/screens/shell/` | ⬜ |
| `ui/AppUi.kt` | 2806 | `lib/ui/app_scaffold.dart` + `lib/ui/screens/servers/` | 🟨 scaffold+nav done; screens pending |
| `ui/ComposeBuilder.kt` | 2100 | `lib/ui/screens/infra/compose_builder.dart` | ⬜ |
| `ui/MonitorScreen.kt` | 1185 | `lib/ui/screens/monitor/` | ⬜ |
| `ui/InfraScreen.kt` | 1020 | `lib/ui/screens/infra/` | ⬜ |
| `ui/FleetScreen.kt` | 878 | `lib/ui/screens/fleet/` | ⬜ |
| `ui/CodeEditor.kt` | 850 | `lib/ui/widgets/code_editor.dart` | ⬜ |
| `ui/OmniComponents.kt` | 779 | `lib/ui/widgets/omni_components.dart` | 🟨 app bar + bottom nav done (`omni_chrome.dart`) |
| `ui/LanHostnameResolver.kt` | 295 | `lib/domain/lan_hostname_resolver.dart` | ⬜ |
| `ui/ShellSession.kt` | 252 | `lib/domain/shell_session.dart` | ⬜ |
| `ui/ScriptEditorDialog.kt` | 230 | `lib/ui/widgets/script_editor_dialog.dart` | ⬜ |
| `ui/TerminalSessionManager.kt` | 200 | `lib/domain/terminal_session_manager.dart` | ⬜ |
| `ui/CodeHighlighter.kt` | 198 | `lib/ui/widgets/code_highlighter.dart` | ⬜ |
| `ui/ImagePreview.kt` | 164 | `lib/ui/widgets/image_preview.dart` | ⬜ |
| `ui/TerminalBufferText.kt` | 120 | `lib/ui/screens/shell/terminal_buffer_text.dart` | ⬜ |
| `ui/ShortcutHelper.kt` | 120 | `lib/platform/shortcut_helper.dart` | ⬜ |
| `ui/AppLockTimeoutPolicy.kt` | 120 | `lib/domain/app_lock_timeout_policy.dart` | ✅ |
| `ui/TuiScrollRouter.kt` | 118 | `lib/domain/tui_scroll_router.dart` | ⬜ |
| `ui/TerminalViewportState.kt` | 93 | `lib/domain/terminal_viewport_state.dart` | ⬜ |
| `ui/TerminalKeyEncoder.kt` | 72 | `lib/domain/terminal_key_encoder.dart` | ✅ (+ `TermKey`) |
| `ui/TerminalContrast.kt` | 71 | `lib/ui/theme/terminal_contrast.dart` | ⬜ |
| `ui/MonitorHistory.kt` | 65 | `lib/domain/monitor_history.dart` | ✅ |
| `ui/AlertBreachTracker.kt` | 64 | `lib/domain/alert_breach_tracker.dart` | ✅ |
| `ui/InputValidation.kt` | 54 | `lib/domain/input_validation.dart` | ✅ |
| `ui/ScriptFilters.kt` | 41 | `lib/domain/script_filters.dart` | ✅ |
| `ui/LinkOpener.kt` | 41 | `lib/platform/link_opener.dart` (url_launcher) | ⬜ |
| `ui/OperationGeneration.kt` | 37 | `lib/domain/operation_generation.dart` | ✅ |
| `ui/HostDisplay.kt` | 37 | `lib/domain/host_display.dart` | ✅ |
| `ui/MeasurementUnits.kt` | 31 | `lib/domain/measurement_units.dart` | ✅ |
| `ui/SessionNotificationPayload.kt` | 22 | `lib/platform/session_notification_payload.dart` | ⬜ |
| `ui/MultiSshLayout.kt` | 6 | `lib/domain/multi_ssh_layout.dart` | ⬜ |
| `ui/theme/Theme.kt` | 182 | `lib/ui/theme/theme.dart` | ✅ |
| `ui/theme/Color.kt` | 67 | `lib/ui/theme/colors.dart` | ✅ |
| `ui/theme/Type.kt` | 56 | `lib/ui/theme/typography.dart` | ✅ |

### 3.7 Widgets & billing (728 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `ui/widget/OmniTermWidget.kt` | 478 | native Glance (Android) + WidgetKit (iOS) via `home_widget` — see §7.3 | ⬜ |
| `ui/widget/OmniTermWidgetConfigActivity.kt` | 211 | ditto | ⬜ |
| `billing/LicenseController.kt` | 39 | `lib/platform/license_controller.dart` (in_app_purchase) | ⬜ |

---

## 4. Layout / navigation architecture to preserve (verbatim from `AppUi.kt`)

The `Screen` enum has **15 values** and must be preserved exactly:

```
Servers, Fleet, Monitor, Shell, SFTP, Infra, Tools,
Alerts, QuickScripts, Network, AuthKeys, Backup, HealthScoring, Settings, About
```

**Bottom navigation — 7 items, in this order, with these labels/colours:**

| Screen | Label | Icon | Accent |
|---|---|---|---|
| `Servers` | "Servers" | `Dns` | cyan |
| `Fleet` | "Fleet" | `Hub` | green |
| `Monitor` | "Monitor" | `Speed` | amber |
| `Shell` | **"Term"** | `Terminal` | cyan |
| `SFTP` | **"Files"** | `FolderZip` | orange |
| `Infra` | **"Containers"** | `Layers` | purple |
| `Tools` | "Tools" | `Build` | red |

The remaining 8 screens are **Tools sub-screens** (`isToolSubScreen()`); while one is active the
Tools nav item stays highlighted.

**Scaffold structure (`AppCoreScaffold`) — must be reproduced 1:1:**
- `topBar`: `OmniAppBar` (home, alerts w/ badge, keep-screen-on toggle) + `FreePlanBanner` when
  `showMonetizationUi && !unlocked`.
- `bottomBar`: `AdBanner` when `showMonetizationUi && !adsRemoved`, then `OmniBottomNav`.
- **Compact terminal IME rule:** when `Screen.Shell` + IME visible + landscape, **both** global bars
  are hidden and an alerts FAB is shown top-end instead. This exists because a landscape keyboard
  otherwise leaves the terminal zero drawable rows.
- Global gestures (`pullRefresh` + horizontal `swipeTabs`) are enabled on every screen **except**
  `Screen.Shell`.
- Global overlays mounted above the screen body regardless of tab: `ActionStreamDialog`,
  `AlertsPopup`, `SudoAuthDialog`, battery-saver dialog.

**Design palette (`OmniColors`, ported from the `nexuscomplete.jsx` prototype)** — reproduce exactly:
```
bg0 #000000  bg1 #0A0E15  bg2 #101622  bg3 #161D2E  bg4 #1C2438
border #1E2D44  borderHi #2A3F60
cyan #00E5FF / dim #00233A      green #00E676 / dim #00231A
amber #FFAB00 / dim #2A1F00     red #FF1744 / dim #2A0008
purple #D500F9 / dim #1E0026    orange #FF6D00
textPrimary #C8D4E8  textSecondary #56708A  textMuted #2C3E52
```
`hostColor(name)` = `hostColors[name.codeUnits.sum % 6]` where
`hostColors = [cyan, amber, orange, green, red, purple]`. **Must stay byte-identical** or saved
hosts change colour after the migration.

---

## 5. Architecture decisions (with rationale)

### 5.1 Pattern: MVVM + repository (matches Flutter's official guide *and* the existing app)
Flutter's official architecture guide recommends MVVM with a repository layer, which maps almost
exactly onto the existing Compose `AppViewModel` + `AppRepository` + Room/JSch services split. So
"keep the architecture the same" and "follow Flutter best practice" agree here.

- **View** → Flutter widgets (`lib/ui/screens/…`)
- **ViewModel** → `ChangeNotifier` (`lib/ui/view_model/…`), exposed with `provider`
- **Repository** → `lib/data/app_repository.dart` (source of truth)
- **Services** → Drift DB, dartssh2 transport, RemoteFsClient implementations

`ChangeNotifier` + `provider` is chosen over Riverpod/BLoC deliberately: Compose's
`mutableStateOf`-on-a-ViewModel model is observably identical to `ChangeNotifier`, so screens port
with the least behavioural drift. This is the lowest-risk mapping, which constraint 2 demands.

### 5.2 `AppViewModel.kt` is 12,310 lines and will be split
It is a single god-object today. It will be split **by feature** into
`ServersViewModel`, `ShellViewModel`, `SftpViewModel`, `MonitorViewModel`, `InfraViewModel`,
`FleetViewModel`, `ToolsViewModel`, sharing an `AppState` root — while keeping every public
property/method name so screen logic ports mechanically. This is the one place the internal
structure improves; **external behaviour is unchanged**.

### 5.3 Dependency map (Kotlin → Dart)

| Concern | Legacy (Android/JVM) | Flutter (Android + iOS) | Confidence |
|---|---|---|---|
| SSH / SFTP / tunnels | JSch (`com.github.mwiede`) | **dartssh2 2.22.5** (pure Dart, verified iOS) | High — actively maintained, published days ago |
| Terminal rendering | custom `TerminalEmulator` + Compose | **xterm 4.0.0** (`TerminalView`) | Medium — see §7.2 |
| Database | Room (schema v18) | **drift** + `sqlite3_flutter_libs` | High |
| Secure storage | Android Keystore AES-GCM | **flutter_secure_storage** (Keystore + iOS Keychain) | High |
| Biometrics | AndroidX Biometric | **local_auth** | High |
| SMB 2/3 | smbj | *none viable* | ⚠️ **Blocked — §7.1** |
| FTP | Apache Commons Net | **ftpconnect** | Medium |
| WebDAV | OkHttp | **dio** + `xml` | High |
| HTTP | OkHttp/Retrofit/Moshi | **dio** + `json_serializable` | High |
| Foreground session | Foreground service + WakeLock | **flutter_foreground_task** + `wakelock_plus` (Android); iOS differs — §7.4 | Medium |
| Notifications | NotificationManager | **flutter_local_notifications** | High |
| Home widget | Glance AppWidget | **home_widget** + native Glance/WidgetKit | Medium — §7.3 |
| Billing | Play Billing | **in_app_purchase** (Play + StoreKit) | High |
| Ads | Google Mobile Ads | **google_mobile_ads** | High (add at flavor step) |
| Crypto | JCA / Bouncy Castle | **pointycastle 4.0.0** / `cryptography` | High |

---

## 6. Android/iOS parity notes

| Capability | Android | iOS | Resolution |
|---|---|---|---|
| Background SSH session | Foreground service (`connectedDevice`) keeps sockets alive indefinitely | **iOS has no equivalent.** Sockets are suspended shortly after backgrounding | tmux-backed reconnect becomes the primary iOS story; document the difference in-app |
| Local network access | `ACCESS_LOCAL_NETWORK` (API 37) | `NSLocalNetworkUsageDescription` + Bonjour entitlement | Add to `Info.plist` |
| Wake-on-LAN UDP broadcast | fine | allowed, needs local-network permission | ok |
| Keystore | Android Keystore | Secure Enclave/Keychain | `flutter_secure_storage` |
| Home widget | Glance | WidgetKit (Swift, separate extension target) | `home_widget` bridges data; UI written twice |
| App lock / biometrics | BiometricPrompt | FaceID/TouchID (`NSFaceIDUsageDescription`) | `local_auth` |
| Flavors (`openSource`/`playStore`) | product flavors | Xcode schemes/configurations | mirror via `--dart-define` + schemes |

---

## 7. Open risks / blockers

### 7.1 ⚠️ SMB has no viable pure-Dart client (BLOCKER for the Shares tab)
`smb_connect` is the only real candidate and it **cannot be used**: it pins `pointycastle ^3.9.1`
while `dartssh2 >= 2.15.0` requires `pointycastle ^4.0.0` — a hard, unresolvable version conflict
(verified by `flutter pub add`, output recorded below). It is also 18 months stale, published by an
unverified uploader, and caps at **SMB 2.1** — the app advertises SMB 2/3.

Options (decide before the Shares port):
1. **Write a minimal SMB2/3 client in Dart** (largest effort, full control, works on iOS).
2. Fork `smb_connect` and bump it to pointycastle 4 (medium effort, inherits stale code).
3. Platform-channel to smbj on Android + SMBClient on iOS (splits the codebase; contradicts "entire project to Flutter").

**Nothing is decided yet — the rest of the migration proceeds around it.** SMB is 173 LOC of the
app's client code but gates a headline feature.

### 7.2 Terminal emulator: port vs. adopt `xterm`
The app has its **own** 1,177-LOC `TerminalEmulator` plus a documented compatibility matrix
(`docs/TERMINAL_COMPATIBILITY.md`), tmux control-mode integration, reflowing scrollback on resize,
and a custom `TuiScrollRouter`. `xterm.dart` gives rendering + a solid VT core but will not
reproduce these behaviours exactly. Plan: use `xterm`'s `TerminalView` for rendering, but port the
app's own emulator semantics where they diverge, driven by the existing test suite.

### 7.3 Home widgets are inherently non-portable
Glance and WidgetKit are separate native UIs. `home_widget` shares *data*, not layout. The Android
Glance code may be kept nearly as-is; the iOS widget is new Swift work.

### 7.4 iOS background execution
See §6 — this is a genuine platform capability gap, not a porting problem. It will change how
long-lived sessions behave on iOS and needs a product decision.

### 7.5 ~~`sqlite3_flutter_libs` resolved as `0.6.0+eol`~~ — RESOLVED
Not a problem: `0.6.0+eol` is an intentional **no-op stub**. The package only ever existed to ship
SQLite for `sqlite3` 2.x; `sqlite3` 3.x bundles the library itself, and the stub is published purely
so dependents can pin it and be sure the old build scripts are excluded. It has been **removed** from
the dependency set and `sqlite3` added explicitly. The matching
`applyWorkaroundToOpenSqlite3OnOldAndroidVersions()` call is likewise obsolete and is not used.

### 7.6 `file_picker` is unusable — replaced by `file_selector`
`file_picker` 11.0.3 (newest stable; 12.x is beta-only) pins `win32 ^5.9.0`, while every `*_plus`
plugin we use (`wakelock_plus`, `share_plus`, `network_info_plus`, `connectivity_plus`) requires
`win32 ^6.0.1`. Forcing `dependency_overrides: win32: ^6.0.1` resolves but then **fails the Android
build**: Dart still type-checks `file_picker`'s Windows sources against the new win32 API
(`HRESULT` signature changes), so the kernel snapshot errors out even though Windows is never a
target. Replaced with **`file_selector`** (Flutter-team maintained, C++ Windows impl, no win32 Dart
dependency) plus **`flutter_file_dialog`** (zero transitive deps) for Android SAF save flows.

### 7.8 ~~Latent bug in `inferLevel`~~ — **FIXED** (see §15.1)
Originally reproduced verbatim to preserve parity. Under requirement 9 it is now fixed in the port.

### 7.7 Plugins still applying the Kotlin Gradle Plugin
`flutter_file_dialog`, `flutter_foreground_task` and `home_widget` apply KGP directly. Flutter warns
that **future versions will fail to build** on this. Not blocking today; track upstream.

---

## 8. Recovery procedure (read this after any context loss)

1. `cd /home/sbvino/Omniterm && git branch --show-current` → must be `migration-to-flutter`.
2. `export PATH="/home/sbvino/sdks/flutter/bin:$PATH"` (Flutter is NOT on PATH by default).
3. Read this file's [Progress log](#14-progress-log) — the last entry is the resume point.
4. `git log --oneline origin/main..HEAD` shows everything committed so far this migration.
5. Check the task list (TaskList tool) for per-phase status.
6. Legacy behaviour questions are answered by `app/src/main/java/com/jetsetslow/omniterm/…`
   (never deleted until final cut-over) and by `docs/`.
7. Resume at the first ⬜/🟨 row in §3, honouring the phase order in §9.

---

## 9. Phase order

1. **Scaffold** — Flutter project, deps, CI, analysis options. *(in progress)*
2. **Theme + shell** — `OmniColors`, typography, `OmniAppBar`, `OmniBottomNav`, `AppCoreScaffold`,
   15-screen routing. Gives a navigable skeleton early.
3. **Data layer** — Drift tables/DAOs/repository + secret store.
4. **Pure-logic ports** — `RemoteParsers`, `HealthScoring`, validators, encoders (these carry their
   unit tests across and are the safest, highest-value early wins).
5. **SSH transport** — dartssh2 behind the existing `SshTransport` interface.
6. **Terminal** — emulator + tmux + shell screen.
7. **Feature screens** — Servers → Monitor → Infra → Fleet → SFTP → Tools.
8. **Shares** — pending the §7.1 decision.
9. **Platform integrations** — billing, ads, notifications, widgets, background.
10. **Cut-over** — flavors, CI, release signing, then retire `app/`.

---

## 11. End-to-end UI automation (requirement 6)

**Primary: [Patrol](https://patrol.leancode.co)** — chosen after comparing it against Maestro and
Appium. Flutter paints its own pixels with Skia rather than emitting native views, so generic native
automation sees one opaque canvas. Patrol extends Flutter's `integration_test` with real native
interaction (permission dialogs, notifications, system settings), tests are written in Dart next to
the app, and the same suite runs on Android and iOS — which requirement 3 demands.

**Secondary: [Maestro](https://maestro.mobile.dev)** — YAML flows against the built APK/IPA, used as
the CI smoke suite. Patrol has had reported CI stability issues through late-2025/2026, so a
black-box suite that does not depend on the Dart test harness is a deliberate hedge.

Appium + Flutter driver is **not** adopted: setup cost is high and it duplicates what Patrol does
better, with known animation/hybrid-view limitations. UIAutomator is reachable *through* Patrol for
the Android-only surfaces (home-screen widget, foreground-service notification, biometric prompt).

**Hard requirement on every ported screen:** each interactive widget must carry a stable
`Key`/semantics identifier as it is written, so flows can target it on both platforms. Retrofitting
keys after 36k LOC of UI is far more expensive than adding them during the port.

Coverage target: every screen reachable, every control exercised, and every navigation path
**entered and left** — including the guard-intercepted ones (unsaved Settings, leave-terminal
transaction), which are exactly where the legacy app has had regressions.

---

## 12. CI/CD pipeline port (requirement 7)

Legacy workflows live in `.github/workflows/` (`android-release.yml`, `android-debug.yml`, PR gates)
and encode real constraints that must survive: the `VERSION_CODE` packing scheme
(`major*10^7 + minor*10^5 + patch*100 + build`, bare release = build 99), the two product flavors,
release signing from secrets, and the AdMob-ID guard that fails a Play release built with Google's
sample IDs.

Flutter pipeline to build:
- `flutter analyze --fatal-infos` + `dart format --set-exit-if-changed` + `flutter test --coverage`
- Android: `build apk`/`build appbundle` per flavor, signed from the existing secrets
- **iOS: `build ipa`** — requires a macOS runner, which the current pipeline has never needed
- Patrol E2E on an Android emulator; Maestro smoke on both
- Version identity derived from the tag exactly as today

---

## 13. Open-source tooling baseline (requirement 8)

| Concern | Tool | Why |
|---|---|---|
| Lints | `very_good_analysis` | Much stricter than `flutter_lints`; catches real bugs |
| Mocking | `mocktail` | Null-safe, no codegen |
| E2E | `patrol` + `maestro` | §11 |
| Golden/visual | `alchemist` | Deterministic goldens in CI (replaces Roborazzi) |
| Coverage | `flutter test --coverage` + `lcov` | Legacy had a coverage gate |
| DB | `drift` | Compile-time-checked SQL, real migration tests |
| Serialization | `json_serializable` | Replaces Moshi codegen |
| Crash reporting | keep the existing on-device `CrashLog` | No new cloud dependency — the app's selling point is "no cloud account" |

**Constraint on "feature enrichment":** requirement 2 (keep functionality/layout/architecture the
same) still governs *incidental* change — tooling is upgraded freely, but the UI and behaviour are
not redesigned mid-migration. Requirement 9 carves out the exception: a **genuine defect** is fixed
in the port rather than reproduced. Every such fix is logged in §15 with the observable
before/after, so a behavioural difference found during testing can still be traced to a deliberate
decision rather than mistaken for porting drift.

---

## 14. Progress log

> Append one entry per work session. Newest last. Never rewrite history here.

### 2026-08-03 — Session 1
- Created branch `migration-to-flutter` from `origin/main`.
- Surveyed legacy app: 175 Kotlin files / ~59,418 LOC + 101 test files; 13 Room entities; 15 screens.
- Researched Flutter best practices: official MVVM+repository architecture guide; dartssh2, xterm,
  drift, smb_connect ecosystem status. Established that **iOS support forces a pure-Dart core**
  (recorded in §1).
- Installed Flutter `3.44.8` / Dart `3.12.2` to `/home/sbvino/sdks/flutter`.
- Scaffolded `flutter_app/` with `--platforms=android,ios`, org `com.jetsetslow`.
- Added dependencies: dartssh2, xterm, drift(+flutter, sqlite3_flutter_libs), path_provider,
  provider, flutter_secure_storage, local_auth, shared_preferences, package_info_plus,
  device_info_plus, connectivity_plus, network_info_plus, wakelock_plus, share_plus, file_picker,
  ftpconnect, dio, pointycastle, cryptography, flutter_local_notifications, flutter_foreground_task,
  home_widget, intl, collection, url_launcher.
- **Discovered blocker §7.1:** `smb_connect` is incompatible with `dartssh2` (pointycastle 3 vs 4).
  Excluded `smb_connect`; SMB support deferred pending a decision.
- Wrote this document.
- Commit: `8fad45b` "Scaffold the Flutter migration (Android + iOS) and record the plan".

### 2026-08-03 — Session 1 (continued): Phase 2, theme + shell

Received four further requirements mid-session (iOS parity, E2E automation, CI port, best-of-OSS
tooling) — folded into §1 and detailed in §11–§13. Scheduled the 15-minute resume loop
(cron `*/15 * * * *`, job `3fab2233`) so a usage limit costs at most one interval.

Ported and verified:
- `ui/theme/Color.kt` → `lib/ui/theme/colors.dart`. `hostColor` sums **UTF-16 code units**
  (`String.codeUnits`), matching Kotlin's `Char.code`; summing runes would diverge outside the BMP
  and silently recolour saved hosts. Locked down by tests with values computed from the algorithm.
- `ui/theme/Type.kt` → `lib/ui/theme/typography.dart`, shipping the **same four .ttf binaries** the
  Android build uses (copied to `assets/fonts/`).
- `ui/theme/Theme.kt` → `lib/ui/theme/theme.dart`. All five schemes (dark/light/AMOLED/high-contrast
  ×2) and the original `when`-chain priority. Compose's `background` role has no Flutter equivalent
  (deprecated in `ColorScheme`) and the legacy themes set it *differently* from `surface` (bg0 vs
  bg1), so it is carried separately into `ThemeData.scaffoldBackgroundColor`.
- Navigation → `lib/ui/navigation.dart`: the 15-screen enum (with `wireName` round-tripping the
  Kotlin constant names for persisted state/shortcuts/widgets), `isToolSubScreen`, `swipeNavOrder`,
  `subtabCount`, and `NavigationController` reproducing `commitNavigation` / `navigateBack` /
  `swipeNavigate` exactly — including the Servers-collapses-the-stack and revisit-unwinds rules.
  The `navigateTo` guards (unsaved Settings, leave-terminal transaction) are modelled as a
  `NavigationGuard` list so their precedence survives without importing the 12k-line ViewModel.
- `OmniAppBar` + `OmniBottomNav` → `lib/ui/widgets/omni_chrome.dart` (exact 52dp/48dp/2px/1px
  metrics and the three renamed labels: Term, Files, Containers).
- `AppCoreScaffold` → `lib/ui/app_scaffold.dart`, including the compact-terminal-IME rule and
  gesture suppression on Shell. 15 placeholder screens name their legacy source.

**Verified:** `flutter analyze` clean, **30/30 tests pass**, and `flutter build apk --debug`
**succeeds** (161 MB debug APK). Not yet run on a device — per `MEMORY.md`
(validate-on-device-before-reporting-done) that is required before any parity claim.

Build fixes needed along the way (see §7.6, §7.7):
- `file_picker` → replaced with `file_selector` + `flutter_file_dialog`; the win32 override approach
  was tried and **fails the build**, so it was reverted rather than left in.
- Enabled core library desugaring (`desugar_jdk_libs 2.1.5`) for `flutter_local_notifications`.
- Set `minSdk = 24` and `applicationId = com.jetsetslow.omniterm.app` to match the legacy app.

**Next:** Phase 3 — Drift data layer (§3.2), then the pure-logic ports (§3.5/RemoteParsers), which
carry their existing unit tests across.

### 2026-08-03 — Session 2: Phase 3, Drift data layer

**Correction to an earlier assumption:** the live schema is **v22, not v18**. The README says v18 and
this document repeated it; `AppDatabase.kt` declares `version = 22` and the exported schemas run to
`22.json`. Inventory and §3.2 corrected. There are **14** entities, not 13.

The central design point: **the Flutter app opens the same database file the native app created.**
Android's `SQLiteOpenHelper` (which Room is built on) records the schema version in
`PRAGMA user_version`, and that is exactly the pragma Drift reads. So a Drift schema declared at
version 22, whose tables match Room's shape, sees an existing database as "already current" and runs
no migration — the user's hosts, keys, scripts and alerts simply open. That makes the table
definitions a **binary compatibility surface**, not a style choice:
- `build.yaml` sets `case_from_dart_to_sql: preserve`, because Drift would otherwise snake_case
  every camelCase column and rename the entire schema.
- Defaults use `clientDefault` (Dart-side), not `withDefault` — Room's Kotlin defaults are *not* SQL
  `DEFAULT` clauses, and the exported DDL has none.
- `_open()` resolves the Room directory (`<app data>/databases/`, derived from
  `getApplicationSupportDirectory()`'s parent) rather than `path_provider`'s documents directory,
  and keeps the extension-less file name `omniterm_database`. `drift_flutter`'s `driftDatabase()`
  helper cannot be used for this: it always appends `.sqlite` to the name.

Ported: all 14 tables (`lib/data/tables.dart`), the database + full Room migration chain 8→22
(`lib/data/app_database.dart`), and the historical preset identities the 19→20 back-stamp needs
(`lib/data/legacy_presets.dart`).

**Verified — 42 tests pass, `flutter analyze` clean, debug APK builds.** The schema tests compare
against Room's **committed schema export**, not a transcription of it, so a renamed column or lost
index fails locally instead of on a device:
- all 14 tables present with identical column names, order, types and nullability
- all 4 indices reproduced, including uniqueness
- a database stamped `user_version = 22` reopens with its rows intact and no migration
- the chain migrates v8/v12/v18/v21 fixtures (built from Room's own exports) up to v22
- the semantically tricky steps are pinned: the 15→16 `useHttps` port backfill (443/8443, case-
  insensitive, WebDAV only), the 18→19 duplicate-incident dedup keeping the newest row, the 19→20
  `backgroundedAt = createdAt` seeding, and the 19→20 rule that a name/category match does **not**
  claim a row when that preset family is disabled.

**Closed risk §7.5:** `sqlite3_flutter_libs 0.6.0+eol` is an intentional no-op stub — obsolete once
`sqlite3` 3.x bundles the library. Removed from the dependency set; `sqlite3` added explicitly.

**Next:** Phase 4 — pure-logic ports, starting with `RemoteParsers.kt` (1,604 LOC) and its existing
JVM unit tests, which are the highest-value, lowest-risk translations remaining.

### 2026-08-03 — Session 3: Phase 4, pure-logic ports

Ported the parsing and scoring layer — pure `String in, model out` code with no I/O and no platform
dependency, which is exactly why it moves to iOS unchanged and why its Kotlin tests come across
almost verbatim.

- `data/RemoteModels.kt` → `lib/data/remote_models.dart` (all 17 models). The Kotlin `var` fields
  that call sites mutate in place stay mutable so the screen ports remain mechanical.
- `data/RemoteParsers.kt` (the `RemoteParsers` object) → `lib/data/remote_parsers.dart`. Covers
  processes, systemd/OpenRC services, journald, docker/podman ps/images/volumes/networks/restart
  counts, transfer conflicts, and the four per-OS metric probes (Linux, FreeBSD, Darwin, Windows)
  plus `/proc` stat/diskstats/net-dev parsing.
- `RemoteCommands.normaliseOs` → `lib/data/remote_commands.dart` (**partial**: the ~940 lines of
  shell command strings land with the screens that issue them).
- `data/HealthScoring.kt` → `lib/domain/health_scoring.dart`.

**`lib/data/kotlin_strings.dart` is new and load-bearing.** Kotlin's
`split(Regex, limit)` has no Dart equivalent, and it is what lets `ps` keep a command containing
spaces in a single field. `takeChars`/`removePrefix`/`substringAfter`/`ifBlank`/`distinctBy` are in
the same file for the same reason: these parsers' tolerance for malformed remote output *is* the
feature (a poll that throws blanks the whole Monitor screen; one that skips a line shows the rest),
and reimplementing those idioms approximately is how that tolerance gets lost. Implemented once,
tested directly.

Two translation traps worth recording:
- `coerceAtLeast(0)` is a **lower bound only**. Using Dart's `clamp(0, x)` also caps the upper end
  and throws when `lower > upper`; all six sites use `math.max(0, …)` instead.
- Kotlin sums UTF-16 code units and renders `Float` as "50.0" — the health-scoring `encode()` string
  must match byte for byte, since it is persisted in `app_settings`. Pinned by a test.

**Found a latent bug in the original (§7.8) and deliberately did not fix it.** `inferLevel`'s
pattern `\b(warn|warning|deprecat|timeout|retry)\b` has a trailing `\b` that makes the `deprecat`
stem dead — "deprecated option in use" is classified INFO, not WARN. The port reproduces this
exactly and a test pins it, because changing behaviour mid-migration would make a genuine
behavioural difference indistinguishable from an intentional one. Fix after parity.

**Verified — 122 tests pass, `flutter analyze` clean.** The parser tests reuse the Kotlin fixtures
verbatim, so they are evidence the port is faithful rather than merely self-consistent. Still no
on-device run: no parity claim.

**Next:** finish Phase 4's remaining pure-logic files (`InputValidation`, `MeasurementUnits`,
`OperationGeneration`, `HostDisplay`, `ScriptFilters`, `MonitorHistory`, `AlertBreachTracker`,
`AppLockTimeoutPolicy`, `TerminalKeyEncoder`), then Phase 5 — the dartssh2 transport.

### 2026-08-03 — Session 4: Phase 4 complete

Ported the nine remaining pure-logic files: `InputValidation`, `MeasurementUnits`,
`OperationGeneration`, `HostDisplay`, `ScriptFilters`, `MonitorHistory`, `AlertBreachTracker`,
`AppLockTimeoutPolicy`, and `TerminalKeyEncoder` (which brings `TermKey` and
`terminalKeyAllowedInReadOnly` across with it). All now live under `lib/domain/`.

Three places where a literal translation would have been wrong:

- **`@Synchronized` / `ConcurrentHashMap` do not translate.** `OperationGeneration` and
  `AlertBreachTracker` are lock-free in Dart because an isolate is single-threaded and only yields
  at an `await`. `publishIfCurrent` keeps a **synchronous** callback parameter on purpose — an
  `async` one would reintroduce exactly the check-then-publish race the Kotlin `synchronized` block
  existed to close.
- **`HostDisplay` was a Compose-observable `object`.** It becomes a `ChangeNotifier` singleton so
  leaf widgets can still render a masked label without the ViewModel threaded through.
- **`formatTemperature` deliberately uses the *default* locale**, unlike `humanBytes` which forces
  `Locale.US`. Reproduced by formatting with `toStringAsFixed` (which rounds half away from zero, as
  Java's `%f` does) and then substituting the locale's decimal separator — using `NumberFormat`
  directly would have applied half-even rounding and disagreed at exact .5 boundaries.

Two smaller fidelity notes: `macAddressError` checks hex digits explicitly because Dart's
`int.tryParse(radix: 16)` accepts a leading `+`/`-` where Kotlin's `toIntOrNull(radix = 16)` does
not; and `chartEndpointLabels` takes a `utc` flag in place of Kotlin's `TimeZone` parameter, since
Dart's `DateTime` only distinguishes local from UTC — the tests use it to stay host-independent.

**Caught a bug in my own port before it shipped:** the `csi`/`ss3` helpers in `TerminalKeyEncoder`
initially omitted the ESC (0x1B) introducer, which would have sent `[A` instead of `ESC [ A` for
every arrow key. The byte-level tests are what surfaced it.

**Verified — 198 tests pass, `flutter analyze` clean, debug APK builds.** Phase 4 is done.

**Next:** Phase 5 — the dartssh2 transport (§3.4), starting with the `SshTransport` interface so the
rest of the SSH layer can be written against it.

### 2026-08-03 — Session 5: Phase 5 begins — SSH interface + host-key trust

Ported the SSH contract and the security control that sits under it:
`SshTransport.kt` → `lib/data/ssh/ssh_transport.dart`, `CappedTextBuffer.kt`, and
`SshHostKeyTrust.kt` → `lib/data/ssh/ssh_host_key_trust.dart`.

The interface port was nearly free. The Kotlin was deliberately written without a single JSch type,
in anticipation of becoming an `expect`/`actual` boundary under Compose Multiplatform — so the whole
contract carried over and only the implementation behind it changes. Mappings: `suspend fun` →
`Future`, `Flow<ByteArray>` → `Stream<Uint8List>`, `StateFlow<T>` → `ValueListenable<T>`.

**The host-key trust port needed a real design decision (§7.9).** JSch handed its
`HostKeyRepository` the raw public key blob; dartssh2's `SSHHostkeyVerifyHandler` is
`(String type, Uint8List fingerprint)` — only the SHA-256 fingerprint, and **no host at all**. So:

- Pins are now the OpenSSH `SHA256:…` fingerprint. Not a security downgrade — pinning a digest is
  as strong as pinning its preimage, and it is the value OpenSSH shows the user to compare.
- **Legacy pins convert losslessly on read**, using the same computation the Kotlin `listKnownHosts`
  used. This is the difference between a silent migration and re-prompting a user's whole fleet —
  which would train them to click through the one dialog meant to stop an interception.
- The verify handler must be built per connection, closing over host and port.
- All three legacy alias forms (`host`, `host:port`, `[host]:port`) are still recognised.

**One concurrency finding worth contrasting with Phase 4.** There I noted that `@Synchronized` does
not translate, because a Dart isolate cannot interleave purely synchronous methods. That reasoning
does **not** extend here: the trust store read is `await`ed, so a second connection to the same host
genuinely can run between this one's read and its write. The Kotlin
`synchronized(firstPinCommitLock)` therefore needed a real equivalent, and got one (`_AsyncLock`).
A test drives two concurrent first connections with different keys and asserts the first pin wins.

Also simplified: the Kotlin needed `runBlocking` + `withTimeoutOrNull` because JSch called the
repository synchronously. dartssh2 awaits the handler, so approval is a plain `Future` with a
timeout that fails closed on decline, timeout, or a throwing handler.

**Verified — 232 tests pass, `flutter analyze` clean.** The 34 trust tests are written around the
ways pinning could *wrongly succeed*: a changed key with an auto-approving handler still reports
`changed`; a corrupt entry fails closed rather than matching; import never overwrites a verified
pin; `toString` leaks no secrets.

**Next:** the transport implementation itself — `JschSshTransport.kt` (533 LOC) → dartssh2, then the
session, SFTP, pool and tunnel manager.

---

## 15. Deliberate behaviour fixes (requirement 9)

Defects found in the Kotlin and **corrected** in the Dart port. Each entry records the observable
before/after so a difference spotted during testing is traceable to a decision, not to drift.

### 15.1 Log severity was silently misclassified (`inferLevel`)

`RemoteParsers.inferLevel` classified journald lines with:

```
ERROR: \b(error|fail|failed|fatal|critical|denied|refused|panic|segfault)\b
WARN:  \b(warn|warning|deprecat|timeout|retry)\b
```

The **trailing `\b` disabled every stem in both lists.** A stem only matches when the word ends
exactly there, so `fail` could not match "failure" or "failing", `error` could not match "errors",
and `deprecat` — plainly written as a stem — could only ever match the literal string "deprecat".

Observable effect in the shipped app, verified against the actual patterns:

| Log line | Before | After |
|---|---|---|
| `connection failure` | INFO | **ERROR** |
| `disk errors detected` | INFO | **ERROR** |
| `task is failing` | INFO | **ERROR** |
| `deprecated option in use` | INFO | **WARN** |
| `deprecation notice` | INFO | **WARN** |
| `warned twice` | INFO | **WARN** |
| `retrying now` | INFO | **WARN** |
| `timeouts observed` | INFO | **WARN** |

Real errors were being shown as ordinary INFO lines in the Monitor → Logs view and in Fleet
Broadcast output — exactly backwards for triage. **Fixed** by dropping the trailing boundary from
both patterns; the leading `\b` is kept so a stem must still start a word and cannot match
mid-token ("shutdown" stays INFO). Pinned by tests both ways.

**This defect exists in the shipped Android app today** and is worth a separate fix on `main` if
the Kotlin build ships again before cut-over.


### 2026-08-03 — Session 6: the dartssh2 transport, and a policy change

Ported `JschSshTransport.kt` → `lib/data/ssh/dartssh_transport.dart`, with
`classifyTerminalClose` split out to `terminal_close.dart` and `Utf8StreamDecoder.kt` brought
forward from Phase 6 (the transport needs it to decode chunked output).

**The rewrite is substantially smaller than the original, and that is the point.** JSch's channel
streams are blocking, so the Kotlin needed a dedicated daemon thread per shell reading into a
bounded coroutine `Channel` to get backpressure, plus a 50 ms `available()` polling loop in `exec`
because a blocking read could not be cancelled. dartssh2 exposes `Stream<Uint8List>` directly and
Dart streams carry backpressure natively, so the reader thread, the bounded channel, the
`trySendBlocking` dance and both polling loops all disappear.

What was deliberately **kept** is the behaviour that was hard-won:
- at-most-once semantics — a failed command is never retried, because the request may already have
  reached the server; the suspect connection is evicted instead;
- the exit-status/EOF classification distinguishing a real `exit` from a network drop (a drop must
  never normalise to status 0, or a tmux-backed session with running work is killed instead of
  reconnected);
- secrets travel via channel stdin, never inside the command string, so they cannot appear in `ps`,
  shell history or sshd debug logs. Dart needs `stdin.close()` after the write, or a command reading
  to EOF (`sudo -S`) hangs forever.

Jump hosts use `forwardLocal` through the bastion, mirroring `ssh -J`, with the target's own host
key still verified end-to-end and the bastion torn down with the target.

**Requirement 9 arrived mid-session: fix real bugs found in the Kotlin rather than reproducing
them.** That reverses the earlier decision on §7.8, which is now fixed and documented in the new
§15. Re-examining it turned up that the *same* boundary flaw affects the ERROR pattern, which is
the more serious half: "connection failure", "disk errors detected" and "task is failing" were all
classified INFO in the shipped app. Fixed both, kept the leading `\b` so stems still cannot match
mid-token, and pinned it with tests in both directions.

**Verified — 253 tests pass, `flutter analyze` clean.**

**Next:** the remaining SSH files — `SshSessionPool` (a richer pool than the map used here),
`JschSession`, `JschSftp`, `SshTunnelManager` — then Phase 6, the terminal emulator.

### 15.2 Pool key omitted credentials (defect introduced by the port, caught before commit)

The first cut of `DartSshTransport` keyed its connection pool on `SshCredentials.endpointKey`
(`user@host:port`) — the Kotlin `SshSessionPool.key()` deliberately fingerprints the password,
private key, passphrase, proxy settings, keepalive and compression as well.

Consequence had it shipped: editing a host's password, or switching it from password to key auth,
would keep handing back the connection **already authenticated with the old credentials**. Commands
would keep succeeding, hiding both that the new credentials were wrong and that an authorisation
the user meant to revoke was still in use.

Fixed by porting the real pool and keying on the full fingerprinted identity. The key holds
*fingerprints*, never plaintext, so no secret is ever a map key. Pinned by tests: a changed password
and a password→key switch each force a new connection, and the key is asserted to contain none of
the secrets.


### 2026-08-03 — Session 7: the session pool, and a self-inflicted bug caught

Ported `SshSessionPool.kt` → `lib/data/ssh/ssh_session_pool.dart`, generic over the client type so
its lifecycle logic is testable without a socket, and extracted the shared `AsyncLock` into
`async_lock.dart` (the host-key trust and the pool both need it).

**Reading the Kotlin exposed a defect I had introduced last session (§15.2).** My first transport
keyed its pool on `user@host:port`, while the Kotlin fingerprints every secret into the key. Editing
a host's password would have kept reusing the connection authenticated with the *old* one — masking
both a wrong new credential and a revocation the user intended. Fixed by using the real pool.

Concurrency mapping, continuing the theme:
- The Kotlin's `AtomicInteger` lease counter and `AtomicBoolean` retired flag become **plain fields**
  — every read-modify-write on them is synchronous and cannot interleave on one isolate.
- The per-key `Mutex` **is** kept as an `AsyncLock`, because `acquire` awaits the connect. Without
  it, two concurrent callers for the same host each dial out. A test proves one connection results.
- The generation counter is kept verbatim: `closeAll` bumps it and removes only older-generation
  entries rather than clearing the map, so an acquire that publishes late fails its recheck and
  retires its own connection instead of leaking it. A test drives exactly that interleaving.

The lease model is preserved too: `evict` during an in-flight command retires the entry but defers
the actual disconnect until the last lease closes, and passing the *suspect* connection stops a slow
failure from evicting the healthy replacement that already took its place.

**Verified — 271 tests pass, `flutter analyze` clean.**

**Next:** `JschSession` and `JschSftp`, then `SshTunnelManager`, then Phase 6 (terminal emulator).

### 2026-08-03 — Session 8: key validation and the remote-filesystem abstraction

`JschSession.kt` splits in two on the way across. Its **connection setup** (proxy wiring, keepalive,
preferred-auth ordering, cipher/compression config) has no separate home in the Dart port: dartssh2
takes those as `SSHClient` constructor arguments, so that half was already absorbed into
`dartssh_transport.dart`. What genuinely needed porting is the **key validation**, now
`lib/data/ssh/ssh_private_key.dart`.

That validation is worth its own file because all of its value is diagnostic. JSch threw
`JSchException("invalid privatekey: " + byte[])`, and the array rendered as `[B@1a2b3c` — which is
what reached users. The guards run *before* parsing: a pasted **public** key gets its own message
(the two files differ only by a `.pub` suffix), text without PEM markers is rejected outright, line
endings are normalised with a guaranteed trailing newline (phone pasting introduces CRLF or strips
it), and any parser message that would leak an internal representation is suppressed in favour of
the passphrase hint. Tests assert the absence of both `[B@` and Dart's equivalent `Instance of`.

**Fixed a mismatch I had introduced:** the transport was passing `creds.passphrase` when parsing the
*jump host's* key. That field belongs to the target key, so it would try to decrypt the bastion key
with the wrong secret. Kotlin passed null; now so does the port, with the resulting limitation
(encrypted jump keys unsupported) written down rather than left implicit.

Also checked, and correct by construction: the Kotlin needed `setHostKeyAlias` so a jump target was
pinned to its **logical** host rather than the ephemeral `127.0.0.1:<random>` forward endpoint. The
Dart port cannot get this wrong — dartssh2 hands us the verify callback instead of deriving identity
from the socket, and the transport closes over `creds.host`/`creds.port`.

`RemoteFsClient.kt` → `lib/data/shares/remote_fs_client.dart`, the seam SFTP and every share protocol
implement. Java's `InputStream`/`OutputStream` become `Stream<Uint8List>`/`StreamSink<List<int>>`,
which also removes the manual read loops. One more entry in the running concurrency theme: the
Kotlin wrapped its date formatter in a `ThreadLocal` because `SimpleDateFormat` is not thread-safe
and two shares genuinely browse at once on the IO dispatcher — **Dart needs no such guard**, since
an isolate is single-threaded. The 64 KiB / 150 ms progress throttle *is* kept: an unthrottled
callback per chunk floods the UI thread and makes a fast transfer slower than a throttled one.

**Verified — 286 tests pass, `flutter analyze` clean, debug APK builds.**

**Next:** `JschSftp` on top of the new abstraction, then `SshTunnelManager`, then Phase 6.
