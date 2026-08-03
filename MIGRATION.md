# OmniTerm → Flutter Migration (running log)

**This file is the single source of truth for the migration.** If context is lost, compacted, or
the session restarts, read this file top-to-bottom first — it is written so that work can resume
without re-deriving anything.

- **Branch:** `migration-to-flutter` (created from `origin/main` at `7a4e836`… see `git merge-base`)
- **Started:** 2026-08-03
- **Status:** Phase 1 (scaffolding + core ports) — see [Progress log](#progress-log)

---

## 1. Goal & constraints (from the user, verbatim intent)

1. Migrate the **entire** OmniTerm project from native Android (Kotlin + Jetpack Compose) to **Flutter**.
2. **Keep all functionality, layout and architecture the same.**
3. The Flutter app must be **truly multiplatform — iOS as a first-class target**, not Android-only.
4. Research best practices online rather than guessing.
5. Work should run in a **loop that retries every 15 minutes** if a usage/rate limit is hit, and
   resume automatically from this document.

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
| `data/RemoteParsers.kt` | 1604 | `lib/data/remote_parsers.dart` (pure Dart, portable 1:1) | ⬜ |
| `data/Daos.kt` | 362 | `lib/data/dao/*.dart` (Drift) | ⬜ |
| `data/AppDatabase.kt` | 352 | `lib/data/app_database.dart` (Drift, schema v18) | ⬜ |
| `data/Entities.kt` | 271 | `lib/data/tables.dart` (13 tables) | ⬜ |
| `data/CrashLog.kt` | 206 | `lib/data/crash_log.dart` | ⬜ |
| `data/RemoteModels.kt` | 203 | `lib/data/remote_models.dart` | ⬜ |
| `data/AppRepository.kt` | 191 | `lib/data/app_repository.dart` | ⬜ |
| `data/BiometricCryptoGate.kt` | 167 | `lib/platform/biometric_gate.dart` (local_auth) | ⬜ |
| `data/HealthScoring.kt` | 119 | `lib/domain/health_scoring.dart` | ⬜ |
| `data/SecretStore.kt` | 71 | `lib/platform/secret_store.dart` (flutter_secure_storage) | ⬜ |

### 3.3 Network shares (705 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `data/shares/RemoteFsClient.kt` | 132 | `lib/data/shares/remote_fs_client.dart` (abstraction) | ⬜ |
| `data/shares/WebDavFsClient.kt` | 217 | `lib/data/shares/webdav_fs_client.dart` (dio + xml) | ⬜ |
| `data/shares/FtpFsClient.kt` | 183 | `lib/data/shares/ftp_fs_client.dart` (ftpconnect) | ⬜ |
| `data/shares/SmbFsClient.kt` | 173 | `lib/data/shares/smb_fs_client.dart` | ⚠️ **blocked — see §7.1** |

### 3.4 SSH (1,984 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `data/ssh/JschSshTransport.kt` | 533 | `lib/data/ssh/dartssh_transport.dart` | ⬜ |
| `data/ssh/SshTunnelManager.kt` | 333 | `lib/data/ssh/ssh_tunnel_manager.dart` | ⬜ |
| `data/ssh/SshHostKeyTrust.kt` | 315 | `lib/data/ssh/ssh_host_key_trust.dart` | ⬜ |
| `data/ssh/JschSftp.kt` | 294 | `lib/data/ssh/dartssh_sftp.dart` | ⬜ |
| `data/ssh/JschSession.kt` | 219 | `lib/data/ssh/dartssh_session.dart` | ⬜ |
| `data/ssh/SshSessionPool.kt` | 144 | `lib/data/ssh/ssh_session_pool.dart` | ⬜ |
| `data/ssh/SshTransport.kt` | 123 | `lib/data/ssh/ssh_transport.dart` (interface — port first) | ⬜ |
| `data/ssh/CappedTextBuffer.kt` | 23 | `lib/data/ssh/capped_text_buffer.dart` | ⬜ |

### 3.5 Terminal (1,486 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `data/term/TerminalEmulator.kt` | 1177 | `lib/data/term/terminal_emulator.dart` — see §7.2 | ⬜ |
| `data/term/TmuxControl.kt` | 232 | `lib/data/term/tmux_control.dart` | ⬜ |
| `data/term/Utf8StreamDecoder.kt` | 77 | `lib/data/term/utf8_stream_decoder.dart` | ⬜ |

### 3.6 UI (36,033 LOC — the bulk)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `ui/AppViewModel.kt` | **12310** | `lib/ui/view_model/` (split by feature, see §5.2) | ⬜ |
| `ui/ToolsScreen.kt` | 5005 | `lib/ui/screens/tools/` | ⬜ |
| `ui/SftpScreen.kt` | 3474 | `lib/ui/screens/sftp/` | ⬜ |
| `ui/ShellScreen.kt` | 3175 | `lib/ui/screens/shell/` | ⬜ |
| `ui/AppUi.kt` | 2806 | `lib/ui/app_scaffold.dart` + `lib/ui/screens/servers/` | ⬜ |
| `ui/ComposeBuilder.kt` | 2100 | `lib/ui/screens/infra/compose_builder.dart` | ⬜ |
| `ui/MonitorScreen.kt` | 1185 | `lib/ui/screens/monitor/` | ⬜ |
| `ui/InfraScreen.kt` | 1020 | `lib/ui/screens/infra/` | ⬜ |
| `ui/FleetScreen.kt` | 878 | `lib/ui/screens/fleet/` | ⬜ |
| `ui/CodeEditor.kt` | 850 | `lib/ui/widgets/code_editor.dart` | ⬜ |
| `ui/OmniComponents.kt` | 779 | `lib/ui/widgets/omni_components.dart` | ⬜ |
| `ui/LanHostnameResolver.kt` | 295 | `lib/domain/lan_hostname_resolver.dart` | ⬜ |
| `ui/ShellSession.kt` | 252 | `lib/domain/shell_session.dart` | ⬜ |
| `ui/ScriptEditorDialog.kt` | 230 | `lib/ui/widgets/script_editor_dialog.dart` | ⬜ |
| `ui/TerminalSessionManager.kt` | 200 | `lib/domain/terminal_session_manager.dart` | ⬜ |
| `ui/CodeHighlighter.kt` | 198 | `lib/ui/widgets/code_highlighter.dart` | ⬜ |
| `ui/ImagePreview.kt` | 164 | `lib/ui/widgets/image_preview.dart` | ⬜ |
| `ui/TerminalBufferText.kt` | 120 | `lib/ui/screens/shell/terminal_buffer_text.dart` | ⬜ |
| `ui/ShortcutHelper.kt` | 120 | `lib/platform/shortcut_helper.dart` | ⬜ |
| `ui/AppLockTimeoutPolicy.kt` | 120 | `lib/domain/app_lock_timeout_policy.dart` | ⬜ |
| `ui/TuiScrollRouter.kt` | 118 | `lib/domain/tui_scroll_router.dart` | ⬜ |
| `ui/TerminalViewportState.kt` | 93 | `lib/domain/terminal_viewport_state.dart` | ⬜ |
| `ui/TerminalKeyEncoder.kt` | 72 | `lib/domain/terminal_key_encoder.dart` | ⬜ |
| `ui/TerminalContrast.kt` | 71 | `lib/ui/theme/terminal_contrast.dart` | ⬜ |
| `ui/MonitorHistory.kt` | 65 | `lib/domain/monitor_history.dart` | ⬜ |
| `ui/AlertBreachTracker.kt` | 64 | `lib/domain/alert_breach_tracker.dart` | ⬜ |
| `ui/InputValidation.kt` | 54 | `lib/domain/input_validation.dart` | ⬜ |
| `ui/ScriptFilters.kt` | 41 | `lib/domain/script_filters.dart` | ⬜ |
| `ui/LinkOpener.kt` | 41 | `lib/platform/link_opener.dart` (url_launcher) | ⬜ |
| `ui/OperationGeneration.kt` | 37 | `lib/domain/operation_generation.dart` | ⬜ |
| `ui/HostDisplay.kt` | 37 | `lib/domain/host_display.dart` | ⬜ |
| `ui/MeasurementUnits.kt` | 31 | `lib/domain/measurement_units.dart` | ⬜ |
| `ui/SessionNotificationPayload.kt` | 22 | `lib/platform/session_notification_payload.dart` | ⬜ |
| `ui/MultiSshLayout.kt` | 6 | `lib/domain/multi_ssh_layout.dart` | ⬜ |
| `ui/theme/Theme.kt` | 182 | `lib/ui/theme/theme.dart` | ⬜ |
| `ui/theme/Color.kt` | 67 | `lib/ui/theme/colors.dart` | ⬜ |
| `ui/theme/Type.kt` | 56 | `lib/ui/theme/typography.dart` | ⬜ |

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

### 7.5 `sqlite3_flutter_libs` resolved as `0.6.0+eol`
Pub resolved an end-of-life release. Revisit before the Drift work lands.

---

## 8. Recovery procedure (read this after any context loss)

1. `cd /home/sbvino/Omniterm && git branch --show-current` → must be `migration-to-flutter`.
2. `export PATH="/home/sbvino/sdks/flutter/bin:$PATH"` (Flutter is NOT on PATH by default).
3. Read this file's [Progress log](#progress-log) — the last entry is the resume point.
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

## 10. Progress log

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
