# OmniTerm → Flutter Migration (running log)

> ## ▶ NEXT ACTION (read this first)
>
> **Task #8 is under way.** Sessions 35–38 landed the SSH transport wiring, the host-key prompt,
> the app lock (PIN + biometrics), `FLAG_SECURE`, link opening, backup file save/restore, and alert
> notifications.
>
> **Immediate task: the rest of #8** — the platform-native SMB client (§7.1), the iOS
> `willResignActive` screen cover (`FLAG_SECURE` is Android-only), and the background/foreground
> service that keeps a session alive with the app closed (`SessionService.kt`).
>
> **The Kotlin app is maintained in parallel** on `fix/kotlin-parity-defects` — see §15.6. A §15
> entry is not finished until it is fixed on both branches.
>
> **Shell parity gaps (§18) are a second Shell iteration:** split panes, quick connect, tmux
> persistent sessions, the tunnel manager UI, text selection.
>
> ⚠️ **Nothing since session 34 has been exercised on a device.** The transport wiring, host-key
> prompt, app lock, file dialogs and notifications all need an on-device run before they count as
> finished.
>
> Then #9 (Patrol/Maestro E2E) and #10 (CI/CD).
>
> ⚠️ **Read §16.4 before porting anything else** — port the feature set, not the code set.
>
> Then, in the §9 order — for each: a feature ViewModel reading from `AppState`, then the screen,
> replacing its placeholder in `lib/ui/app_scaffold.dart`: Monitor → Infra → Fleet → SFTP → Tools.
>
> **Four conventions established so far — follow all:**
> 1. Every interactive widget gets a stable `ValueKey('<screen>.<element>')` (Patrol has no native
>    view tree to fall back on).
> 2. Anything reading an observable singleton (`HostDisplay`) must **listen** via
>    `ListenableBuilder` — Compose recomposed readers automatically, Flutter does not.
> 3. Logic that is a security control or easy to get wrong goes in a plain testable class beside the
>    widget, not inside `build()`.
> 4. Anything a screen needs from the SSH layer arrives through an **injected, nullable** dependency
>    (`ServersViewModel({SshTransport? transport})`). Absent means the feature is disabled and says
>    so — never a stub that reports success.
>
> ✅ **Both former blockers are decided (session 23).** §7.10 is **built and verified** — the Android
> bridge, the Dart channel and the one-pass migration all exist and are tested; the only thing left
> is a check on a real device carrying real `enc:v1:` data. §7.1 is decided in favour of
> platform-native SMB behind `RemoteFsClient`, **not started**.
>
> Working rules that are easy to lose: never `git add -A` (`shared/` must stay untracked, stage
> explicit paths); `export PATH="/home/sbvino/sdks/flutter/bin:$PATH"`; run `flutter analyze` and
> `flutter test` from `flutter_app/` before every commit; append a §14 progress entry and commit
> each iteration.

**This file is the single source of truth for the migration.** If context is lost, compacted, or
the session restarts, read this file top-to-bottom first — it is written so that work can resume
without re-deriving anything.

- **Branch:** `migration-to-flutter` (created from `origin/main` at `7a4e836`… see `git merge-base`)
- **Started:** 2026-08-03
- **Status:** Phase 7 — first screen rendering end-to-end; remaining ViewModels + screens next — see [Progress log](#14-progress-log)

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
10. **Modularise as far as is reasonable.** One responsibility per file, dependencies pointing
    inward (UI → domain → data), and no module reaching around its neighbour's abstraction. See §16.
11. **Reuse and centralise; never duplicate where it is avoidable.** A helper gets one home. See §16.
12. **Security takes priority over everything else — meaning *code* security.** Memory/parsing
    safety, injection, secret handling, unmaintained or unaudited dependencies. It does **not** mean
    refusing to talk to a weak endpoint: users define their own hosts and know an old SMB server or
    a plaintext FTP share is not encrypted. The app's job there is to **warn**, not to block. See §17.
13. **Feature parity, not code parity.** Every shipped *capability* must survive; the *structure* is
    free to change (indeed §16 requires it to). A restructure that preserves behaviour is correct;
    dropping a capability to make the migration easier is not.

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
| `data/Daos.kt` | 362 | `lib/data/dao/{server,alerts,app_data}_dao.dart` | ✅ |
| `data/AppDatabase.kt` | 352 | `lib/data/app_database.dart` (Drift, schema **v22**) | ✅ |
| `data/Entities.kt` | 271 | `lib/data/tables.dart` (**14** tables) | ✅ |
| `data/CrashLog.kt` | 206 | `lib/data/crash_log.dart` | ⬜ |
| `data/RemoteModels.kt` | 203 | `lib/data/remote_models.dart` | ✅ |
| `data/AppRepository.kt` | 191 | `lib/data/app_repository.dart` | ✅ |
| `data/BiometricCryptoGate.kt` | 167 | `lib/platform/biometric_gate.dart` (local_auth) | ⬜ |
| `data/HealthScoring.kt` | 119 | `lib/domain/health_scoring.dart` | ✅ |
| `data/SecretStore.kt` | 71 | `lib/platform/secret_store.dart` | ✅ (⚠️ needs the §7.10 Android bridge) |

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
| `data/ssh/SshTunnelManager.kt` | 333 | `lib/data/ssh/ssh_tunnel_manager.dart` (+ `tunnel_generation.dart`) | ✅ |
| `data/ssh/SshHostKeyTrust.kt` | 315 | `lib/data/ssh/ssh_host_key_trust.dart` | ✅ |
| `data/ssh/JschSftp.kt` | 294 | `lib/data/ssh/dartssh_sftp.dart` | ✅ |
| `data/ssh/JschSession.kt` | 219 | `lib/data/ssh/ssh_private_key.dart` (key validation); connection setup absorbed into `dartssh_transport.dart` | ✅ |
| `data/ssh/SshSessionPool.kt` | 144 | `lib/data/ssh/ssh_session_pool.dart` (+ `async_lock.dart`) | ✅ |
| `data/ssh/SshTransport.kt` | 123 | `lib/data/ssh/ssh_transport.dart` (interface) | ✅ |
| `data/ssh/CappedTextBuffer.kt` | 23 | `lib/data/ssh/capped_text_buffer.dart` | ✅ |

### 3.5 Terminal (1,486 LOC)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `data/term/TerminalEmulator.kt` | 1177 | `terminal_unicode` + `terminal_snapshot` + `terminal_parser` + `terminal_cell` + `terminal_palette` + `terminal_emulator` | ✅ (reflow pending — §18) |
| `data/term/TmuxControl.kt` | 232 | `tmux_control_event.dart` + `tmux_control_parser.dart` + `tmux_control_commands.dart` | ✅ |
| `data/term/Utf8StreamDecoder.kt` | 77 | `lib/data/term/utf8_stream_decoder.dart` | ✅ |

### 3.6 UI (36,033 LOC — the bulk)
| File | LOC | Flutter destination | Status |
|---|---|---|---|
| `ui/AppViewModel.kt` | **12310** | `lib/ui/view_model/` (split by feature, §5.2) | 🟨 `AppState` + `ServersViewModel` done |
| `ui/ToolsScreen.kt` | 5005 | `lib/ui/screens/tools/` | ✅ all 8 tool views + hub |
| `ui/SftpScreen.kt` | 3474 | `lib/ui/screens/sftp/` | 🟡 3 of 4 tabs; Shares blocked on §7.1 |
| `ui/ShellScreen.kt` | 3175 | `lib/ui/screens/shell/` | 🟡 single-session terminal done; §18 lists the rest |
| `ui/AppUi.kt` | 2806 | `lib/ui/app_scaffold.dart` + `lib/ui/screens/servers/` | 🟨 scaffold, nav, Servers list + form logic done; form **widget** pending |
| `ui/ComposeBuilder.kt` | 2100 | `lib/ui/screens/infra/compose_builder.dart` | ⬜ |
| `ui/MonitorScreen.kt` | 1185 | `lib/ui/screens/monitor/` | 🟡 4 of 6 tabs; Scripts/CRON pending |
| `ui/InfraScreen.kt` | 1020 | `lib/ui/screens/infra/` | 🟡 4 of 5 tabs; Builder pending |
| `ui/FleetScreen.kt` | 878 | `lib/ui/screens/fleet/` | ✅ |
| `ui/CodeEditor.kt` | 850 | `lib/ui/widgets/code_editor.dart` | ⬜ |
| `ui/OmniComponents.kt` | 779 | `omni_chrome.dart` + `omni_components.dart` | 🟨 chrome, card, stat box, section header, formatters done |
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

### 7.1 ⚠️ SMB — options, under the *corrected* reading of requirement 12
**An earlier version of this section argued SMB 2.1 was disqualifying because it lacks SMB 3.x
encryption. That reasoning is withdrawn.** Requirement 12 is about *code* security, and the user has
been explicit: a homelab user pointing the app at their own old NAS knows it is not encrypted. The
right response is a **warning in the UI**, not a refusal to connect. Blocking there would have
removed a working feature to protect users from a choice that is theirs to make.

What actually remains against `smb_connect`, and it is still decisive:
1. **A hard dependency conflict.** It pins `pointycastle ^3.9.1`; `dartssh2 >= 2.15.0` requires
   `^4.0.0`. Verified unresolvable by `flutter pub add`. SSH is the app's core, so dartssh2 wins.
2. **It is a code-security concern in its own right** — 18 months stale, unverified publisher, and
   an SMB implementation is a large attacker-reachable parser. That is exactly the kind of
   dependency requirement 12 is about.

**Remaining options:**
1. **Platform-native SMB behind the ported `RemoteFsClient` seam** — smbj on Android (already
   trusted and shipping), a native client on iOS. Best on code security: a mature, maintained,
   widely-audited implementation instead of an unmaintained one or a from-scratch parser. Cost: two
   native implementations, and a partial retreat from "entire project to Flutter" — acceptable under
   requirement 13, which asks for feature parity, not implementation purity.
2. **Fork `smb_connect` and bump it to pointycastle 4.** Cheapest to reach working SMB, but inherits
   an unmaintained parser the project would then own.
3. **Write SMB2/3 in Dart.** Largest effort, and the *worst* option on requirement 12: a
   from-scratch implementation of an attacker-reachable wire protocol, written under migration
   pressure, is precisely what should not be hand-rolled.

**Leaning: option 1.** Recorded, not yet decided — it is the user's call and blocks nothing until
Phase 8, because `RemoteFsClient` makes the choice swappable.


**DECIDED (session 23), user: "go platform native".** SMB will be implemented natively behind the
existing `RemoteFsClient` interface — SMBJ on Android, and on iOS the `NSFileProvider`/SMB stack —
rather than forking `smb_connect` or writing SMB2/3 in Dart. The Dart side sees one interface, so
the choice stays confined to the platform folders and the Shares screen needs no knowledge of it.
Not started; Network Shares stays unported until it is.

### 7.10 ~~**BLOCKER: existing credentials cannot be decrypted**~~ — RESOLVED (session 23)
**User decision, 2026-08-04: "do it".** Built and verified.

The Kotlin `SecretStore` encrypted **every** credential — server, sudo and proxy passwords, imported
private keys, credential-profile and share passwords — with AES-GCM under a non-exportable Android
Keystore key (alias `omniterm_local_secret_key`). The Dart port necessarily uses its own key and
tags output `enc:v2:`, so shipped without a bridge an updating user would have opened the app to
find every saved secret **silently blank** — `decrypt` returns null on failure by contract.

**Now implemented, three parts:**
- `android/.../LegacySecretBridge.kt` — a method channel decrypting `enc:v1:` under the original
  alias. Constants mirror `data/SecretStore.kt` exactly; they describe data already on disk, not
  choices. Unlike the original it never *creates* a key: a fresh install has no legacy data, and
  generating one there would only ever decrypt nothing.
- `lib/platform/legacy_secret_channel.dart` — the Dart half. Android-only (`Platform.isAndroid`,
  not `defaultTargetPlatform`, which reports the *design* platform and would try a missing channel
  in a desktop preview). Caches the has-key probe so a fresh install pays one round trip rather than
  one per secret. Every failure — no key, a key invalidated by the user dropping their device lock,
  a failed GCM tag, a host build without the bridge — returns null.
- `AppRepository.migrateLegacySecrets()` — one pass over every stored credential.

**The design point that matters:** the pass works on the **raw, still-encrypted** rows, not through
the decrypting accessors. Those map an unreadable secret to null or `""`, so a read-then-write pass
would overwrite precisely the values this exists to save. A field that cannot be read is left
byte-identical on disk — a later OS or app version may still recover it; an overwrite is final.
`SecretStore.upgradeLegacy` returns *ciphertext*, so the migration never holds a plaintext password
in a variable.

Idempotent and cheap to re-run (an `enc:v2:` value never reaches the channel again), so it runs at
startup in `main.dart` rather than lazily per read — a user whose upgrade lands mid-session must not
find some hosts working and others not.

**Verified:** 14 tests, and `flutter build apk --debug` compiles the Kotlin. **Not yet verified on a
real device carrying real `enc:v1:` data** — that is the one check that cannot be done here, and it
should be done before cut-over.

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

---

## 16. Modularisation rules (requirement 10)

The legacy app concentrates enormous responsibility in a few files — `AppViewModel.kt` alone is
12,310 lines. The port deliberately does not reproduce that shape.

**Rules being applied:**
1. **One responsibility per file.** Where the Kotlin bundled several, the port splits them. Already
   done: `classifyTerminalClose` out of the transport into `terminal_close.dart`; key validation out
   of connection setup into `ssh_private_key.dart`; the shared `AsyncLock` out of the trust store.
2. **Dependencies point inward:** `ui → domain → data`. `lib/domain/` imports no Flutter widget and
   no transport; `lib/data/` imports no UI.
3. **Depend on an abstraction, not a neighbour's internals.** `DartSshSftp` takes an
   `SshConnectionLease` rather than the pool or `SSHClient`, so it can express "retry only on a
   *dropped* connection" while knowing nothing about pooling or dartssh2.
4. **Extract the pure decision.** Policy that is easy to get wrong and hard to test through I/O
   becomes a standalone function: `classifyTerminalClose`, the SFTP retry rules, `entryPredatesReset`.
5. **Generic over the transport where it buys testability.** `SshSessionPool<C>` is generic purely so
   its lifecycle can be tested without a socket.
6. **One home per helper (requirement 11).** Three private copies of `firstOrNull` had already
   appeared across `remote_commands`, `remote_parsers` and `remote_fs_client`; they are now a single
   `KotlinIterableOps` extension. Divergent copies of a "safe accessor" are how an unsafe one
   eventually slips in. `TransferProgressThrottle` is likewise shared by SFTP and every share client
   rather than each re-deriving the 64 KiB / 150 ms cadence.

**Still to do:** the big one is §5.2 — splitting `AppViewModel.kt` (12,310 lines) into per-feature
ViewModels over a shared `AppState`, keeping every public member name so the screen ports stay
mechanical. Likewise `ToolsScreen.kt` (5,005 lines) becomes one file per tool view.


### 2026-08-03 — Session 9: SFTP, and modularisation becomes a stated requirement

Ported `JschSftp.kt` → `lib/data/ssh/dartssh_sftp.dart` on the `RemoteFsClient` seam.

The performance shape is preserved exactly, because it is the whole design: authenticating a
connection dominates every SFTP call on a high-latency link, so the connection stays warm in the
pool and only a lightweight SFTP client is opened per operation — one open + `ls` per folder rather
than a full handshake. Each operation gets its own short-lived client so a long transfer never
blocks a folder listing on the same connection.

**The retry rule is the part that matters most**, and it is subtle enough that it was extracted into
a standalone decision function and tested directly rather than only through I/O:
- a failure *opening* the client is always retried once — nothing has happened yet, so a reconnect
  has no side effects;
- a failure *inside* a metadata read is retried once;
- a **transfer is never retried**, because the caller's sink already holds bytes or their source is
  already partly read, so a retry would duplicate downloaded bytes or upload only the leftover tail;
- a logical error (no such file, permission denied) never evicts the warm connection.

Two smaller decisions: `readText` applies its cap *while streaming*, so opening a multi-GB file for
editing costs at most `maxBytes` rather than the file's size; and listing renders `modDate` from the
epoch seconds rather than trusting SFTP's `longname`, which is free-form and varies by server.

`cancelActiveTransfers` simplifies. The Kotlin had to close the caller-side stream *first*, because
JSch could stay blocked inside `put()`/`get()` after a channel disconnect. Dart's streaming loops
check a cancellation flag per chunk and unwind themselves, so the flag suffices.

**Requirement 10 arrived mid-session: modularise as far as reasonable.** Recorded in §16 with the
rules already being applied (one responsibility per file; dependencies pointing inward; depend on an
abstraction rather than a neighbour's internals; extract the pure decision; generic where it buys
testability). SFTP is the clearest example so far — it takes an `SshConnectionLease` rather than the
pool or `SSHClient`, so it can express its retry policy while knowing nothing about pooling or
dartssh2. The outstanding item is the big one: splitting the 12,310-line `AppViewModel`.

**Verified — 298 tests pass, `flutter analyze` clean.**

**Next:** `SshTunnelManager` (333 LOC) finishes Phase 5, then Phase 6 — the terminal emulator.

---

### 16.4 Port the feature set, not the code set (user directive, 2026-08-04)

> *"you're building from scratch so anything that was added on as a feature later in the app like
> the temperature alert which needs backfill for others is not applicable to you — you should go by
> the feature set not code set. architecture is brand new in destination when it comes to
> implementation"*

Much of the Kotlin's shape is a record of **how it grew**, not of what it does. A column added in
v20 needed a back-stamp migration for rows already on devices; a preset added after that column
existed did not. Those are facts about one codebase's history, and re-encoding them here would make
the Flutter app carry scars it never earned — and, worse, make a *new* preset fail a test suite for
a reason unrelated to whether it works.

**The rule:** implement what the feature does. Reach for the Kotlin to learn the behaviour, the edge
cases and the reasons — not to reproduce its internal seams.

**Where this already bit, and was corrected (session 29):** two preset test suites asserted that the
seed lists matched the Kotlin's `LEGACY_*_PRESETS` back-stamp lists *exactly*, in both directions.
That is a code-shaped constraint. `alert.temperature` was added after the `presetKey` column, so it
has no legacy entry — and under the old assertion, adding any new preset would have failed the
build. Both suites now assert the **feature** contract (keys unique, well-formed, families
disjoint), and treat the legacy lists as what they are: a one-way *data-compatibility* check for
rows an older Android build actually wrote, skipped where no counterpart exists.

**Still legitimate, and not affected:** §7.10's credential bridge and the Room-compatible schema.
Those are not historical residue — they are the difference between an update and a data-loss event
for a real user's device.


## 17. Security precedence (requirement 12)

**Scope, as clarified by the user:** this is about *code* security — parsing safety, injection,
secret handling, and the provenance of dependencies. It is **not** about refusing to connect to
endpoints the user has deliberately configured. A weak endpoint gets a **warning**; the user decides.

Decisions taken under the code-security reading, so they are not silently revisited:

- **Host keys fail closed.** No approval UI (background worker, early init) ⇒ an unknown host is
  rejected, never trusted unattended. A corrupt trust entry is treated as absent rather than as a
  match. A changed key is *never* auto-accepted, even with an approving handler registered.
- **Backup restore cannot become an interception vector.** Imported pins never overwrite a key this
  device already verified.
- **Legacy pins convert rather than re-prompt.** Re-prompting a whole fleet trains users to click
  through the one dialog meant to stop an interception.
- **Secrets never enter a command string** — they travel via channel stdin, so they cannot appear in
  `ps`, shell history or sshd debug logs. `SshCredentials.toString()` prints only the endpoint.
- **The connection pool keys on secret *fingerprints*.** No plaintext secret is a map key, and a
  changed credential cannot reuse a connection authenticated with the old one (§15.2).
- **Overlong UTF-8, surrogates and out-of-range code points are rejected** by the decoder, not
  passed through — these are filter-bypass primitives, not merely untidy input.
- **~150 lines of hand-rolled SOCKS parsing deleted** (§18). dartssh2 forwards dynamically itself, so
  the app no longer owns a byte-level parser for an attacker-reachable protocol.
- **Unmaintained dependencies are treated as a security concern**, which is what actually rules out
  `smb_connect` (§7.1) — not its protocol version.

### Warnings owed to the user (to implement with the Shares/Settings screens)
Under the corrected reading, these are **warnings, not blocks**:
- SMB shares negotiating < 3.x → note that the transport is unencrypted.
- FTP and WebDAV-over-plain-HTTP → note that credentials and data are in the clear.

### 2026-08-04 — Session 10: Phase 5 complete, and two corrections from the user

Ported `SshTunnelManager.kt` → `ssh_tunnel_manager.dart` + `tunnel_generation.dart`. **Phase 5 is
done**: the whole SSH layer (1,984 LOC) is across.

**The headline is a deletion.** JSch does not implement `ssh -D` — its string overload parses an
OpenSSH *local-forward* spec, so a dynamic request always threw. The Kotlin therefore hand-wrote a
complete SOCKS4 / SOCKS4a / SOCKS5 proxy: ~150 lines of byte-level parsing of an attacker-reachable
wire protocol. dartssh2 forwards dynamically itself, so **all of it is gone**. `-L` still needs a
local accept loop (dartssh2's `forwardLocal` opens one channel, it does not bind a listener), but
that only pipes bytes and parses nothing.

`stop()` deliberately does not take the per-tunnel lock — stopping must never queue behind a start
hung dialling an unreachable host — so `TunnelGeneration` is what stops a tunnel surviving its own
stop. Extracted as a pure token and tested directly.

#### Two corrections to earlier reasoning, both from the user

1. **Security means *code* security, not protocol-version security.** My §7.1 argued SMB 2.1 was
   disqualifying for lacking SMB 3.x encryption. **Withdrawn.** A homelab user pointing the app at
   their own old NAS knows it is unencrypted; the right response is a **warning**, not a refusal.
   Blocking would have removed a working feature to protect users from their own informed choice.
   `smb_connect` is still ruled out — but for the *right* reasons: an unresolvable dependency
   conflict with dartssh2, and an unmaintained, unverified-publisher parser, which is itself a
   code-security concern. §7.1 and §17 rewritten; §17 now also lists the warnings owed to the user
   (sub-3.x SMB, plaintext FTP/WebDAV) rather than treating those as blockers.

2. **Feature parity, not code parity.** Every shipped capability must survive; the structure is free
   to change — which is what §16 asks for anyway. This resolves the tension I flagged earlier
   between "parity is non-negotiable" and the §15.1 bug fix: fixing a defect preserves the
   capability, so the two requirements never actually conflicted.

**Parity gap to decide (§18):** dartssh2's dynamic forward is **SOCKS5 only** (NO AUTH, CONNECT);
the Kotlin also accepted SOCKS4 and SOCKS4a. Under "feature parity", this is a real if narrow gap —
a client that only speaks SOCKS4 would stop working. Almost everything modern uses SOCKS5. Flagged
rather than silently dropped.

**Verified — 304 tests pass, `flutter analyze` clean.**

---

## 18. Known parity gaps (requirement 13)

**Shell (session 34)** — the single-session terminal is complete; these are a second Shell iteration:
- **Split panes (multi-SSH).** `ShellSession` is already per-session for geometry, scroll position
  and read-only precisely so this drops in: the screen shows one pane, not the model.
- **Quick connect** — a connect-without-saving sheet. Needs the entitlement gate the Kotlin puts
  around it.
- **tmux persistent sessions**, the session picker and the background-session list. The control-mode
  parser (`tmux_control_*.dart`) is ported and tested; the attach/reattach lifecycle is not.
- **The tunnel manager UI.** `ssh_tunnel_manager.dart` is ported; nothing drives it yet.
- **Text selection and the copy dialog.** The surface paints a snapshot rather than selectable text,
  so copying output is not yet possible.
- **"Smart swipe" editor input mode.** Only the higher-fidelity stream mode is ported; swipe typing
  commits whole words through the same path.


**Backup (session 31):**
- ~~**Reading and writing the file itself.**~~ **Done in session 37** — the system document picker,
  via `BackupFileStore`.
- **Sections not yet carried:** firing alerts, alert history, network shares, port forwards and
  crash logs. The selection model already knows them and their dependencies; the serialiser does
  not. Shares and port forwards are blocked on their own screens being ported.

**Network (session 30):**
- **Traceroute** — needs per-hop TTL control, which `dart:io`'s `Socket` does not expose. Options:
  a platform channel, or shelling out to `traceroute` over SSH from a chosen host (a different
  feature, arguably a better one — it traces from the server rather than the phone).
- **WHOIS** — a plain TCP query to port 43 and a text response; straightforward, just not done.
- **Speed test** — needs a bandwidth endpoint and a policy on how much data to pull on a metered
  connection. Worth a product decision before implementing.
- **Tunnels** — the Kotlin's ninth tab manages SSH port forwards. `ssh_tunnel_manager.dart` is
  ported; the UI is not, and it belongs with the Shell screen's session lifecycle.

**Scripts (session 28):**
- **Per-OS / per-platform filtering of quick scripts** — the columns (`targetOs`, `targetSystem`) are
  stored and round-trip through the editor, and `quickScriptMatchesHost` is ported, but the editor
  has no pickers for them and the per-host Quick Scripts row that would apply the filter lives on
  the Shell screen, which is not ported.
- **Drag-to-reorder** within a category. `moveScript` exists; no UI drives it.

**SFTP (session 26):**
- **Network Shares** — the whole tab, blocked on §7.1 (platform-native SMB). Renders a note saying so.
- **The file editor** — the Kotlin opens text files in an in-app editor with save-and-verify. The
  transport calls (`readText`/`writeText`) are ported; the editor UI is not.
- **Copy/move between hosts** (the cross-clipboard bar), **folder sizes via `du`**, **sudo mode**,
  and **remote search** — all present in the Kotlin browser, none ported.

**Fleet (session 25):**
- **Quick-script presets in Broadcast** — the Kotlin offers saved fleet-enabled quick scripts as
  pickable command presets, with a search box and an inline editor. Not ported; the command field is
  free text only. Blocked on the Quick Scripts store, which lands with Tools.
- **The refresh countdown** in the summary bar — needs the telemetry poller, as Monitor's does.

**Infra (session 24):**
- **The visual Compose Builder** — not ported; the tab renders a note saying so. It is a whole YAML
  editor (`ComposeBuilder`, plus `parseDockerComposeYaml` and the atomic deploy flow) and deserves
  its own iteration.
- **Stack scale, ports detail and logs dialogs** — the Kotlin has modal sheets for scaling a
  service, listing published ports and streaming compose logs. The underlying commands are ported
  (`dockerComposeAction` covers scale/serviceLogs/followLogs); the dialogs are not.

**Monitor (session 22):**
- **Scripts and CRON tabs** — not ported; both render a note saying so rather than a blank pane.
- **Overview sparklines** (`MetricLineChart`) and the **health-breakdown dialog** — both need the
  telemetry history poller, which is not ported. Overview shows current numbers only.
- **The telemetry poller itself** — the Kotlin polls every host on a 15s cadence and feeds the
  refresh countdown, the per-host metrics map and the alert evaluation. Monitor currently fetches
  metrics on demand when its Overview tab opens, so there is no countdown ring and no background
  refresh.

Capabilities where the Dart port does not yet match the Kotlin. Each needs a decision, not silence.

| Gap | Kotlin | Dart port | Impact |
|---|---|---|---|
| Dynamic forward protocol | SOCKS4, SOCKS4a **and** SOCKS5 | **SOCKS5 only** (dartssh2 native) | A client that speaks only SOCKS4 stops working. Rare — modern clients use SOCKS5. Fixing it means re-adding a hand-written SOCKS4 front end, which is what §17 just removed. |
| Encrypted jump-host keys | Not supported (Kotlin passed a null passphrase) | Not supported | No regression; documented so it is not mistaken for one. |
| SMB browsing | smbj (SMB 2/3) | **Not implemented** — see §7.1 | Blocks a headline feature. Must be resolved before cut-over. |
| Resize reflow | Soft-wrapped runs are re-joined and re-wrapped at the new width | Grid resize only: content preserved top-left, cursor clamped | A narrowed window truncates wrapped lines instead of re-wrapping them. `docs/TERMINAL_COMPATIBILITY.md` lists reflow as Supported, so this must be closed before cut-over. The `softWrapped` bookkeeping the algorithm needs is already ported and maintained. |
| Unicode combining marks | JVM `Character.getType` (full Unicode database) | Explicit range table | An exotic script's marks could render one column wide instead of zero. Conservative by design; the compatibility matrix already scopes width to a bounded subset. |


### 2026-08-04 — Session 11: tmux control mode

Ported `TmuxControl.kt` → three files by responsibility (§16): `tmux_control_event.dart` (the event
hierarchy), `tmux_control_parser.dart` (the wire protocol), `tmux_control_commands.dart` (command
construction). One 232-line file with three jobs became three files with one each.

Control mode is what makes fast output safe: tmux streams **every** byte as `%output` instead of
rendering a UI, so the "fast output collapses into a repaint and unseen rows are lost" failure of a
regular attach cannot happen by construction.

Two properties carried over deliberately, both code-security relevant (§17):

1. **Parsing stays byte-level.** `%output` escapes control bytes as exactly three octal digits, but
   bytes ≥ 0x80 pass through **raw** — so decoding a line to a String before parsing would mangle
   every multi-byte character in the pane. Tested with a CJK payload and with an escape split across
   two chunks.
2. **The 1 MiB buffer cap is a DoS guard, not tidiness.** Without it a remote that never sends a
   newline grows the buffer until the app dies. Both the unterminated tail and a single reply body
   are bounded, and both are tested.

Also preserved: only `%end`/`%error` terminate a reply block, because body lines legitimately start
with `%` (that is what `list-panes` prints); and every pane id is validated against `%\\d+` before
interpolation, since these strings become tmux command lines and an unvalidated id is command
injection. A test drives `%0; kill-server` through all four command builders.

**Verified — 338 tests pass, `flutter analyze` clean.**

**Next:** `TerminalEmulator.kt` (1,177 LOC), the largest single file left in the non-UI layers.

### 2026-08-04 — Session 12: terminal width rules and snapshot types

Started the emulator by taking the two pieces everything else depends on, so the 1,177-line class
lands in tested slices rather than one unverifiable dump: `terminal_snapshot.dart` (TermSpan,
TermRow, TerminalSnapshot) and `terminal_unicode.dart` (display-width rules).

**One thing could not be ported directly.** The Kotlin asked the JVM for a code point's Unicode
general category — `Character.getType` ⇒ `NON_SPACING_MARK` / `COMBINING_SPACING_MARK` /
`ENCLOSING_MARK` — to decide that a mark occupies zero columns. **Dart ships no Unicode category
database.** That lookup is replaced by an explicit combining-mark range table, which is what wcwidth
implementations have always done.

The table is a bounded subset, and that is consistent with the stated contract:
`docs/TERMINAL_COMPATIBILITY.md` already says "Unicode width remains a bounded terminal subset rather
than a shaping engine for every complex script". It covers the ranges that actually appear in
terminal output — Latin/Greek/Cyrillic marks, Hebrew/Arabic points, Indic and South-East Asian
scripts, CJK/Kana marks, and the emoji modifier machinery. It is deliberately conservative: a code
point wrongly *included* would be swallowed into the previous cell, which is far more visible than
one wrongly omitted, which merely takes a column of its own.

Width is not cosmetic — the emulator lays out cells by these numbers, so an error shifts every
following glyph on the row. Hence 26 tests covering marks from several scripts, the presentation
selectors (U+FE0E forces one column, U+FE0F two), keycaps, regional-indicator flags, ZWJ sequences,
skin-tone modifiers, and Hangul jamo (wide lead, zero-width tail).

`terminal_snapshot.dart` keeps colours as packed ARGB ints and imports nothing from Flutter, exactly
as the Kotlin kept them free of Compose — that is what lets the emulator live in `lib/data/` with the
dependency arrow pointing away from the UI.

**Verified — 364 tests pass, `flutter analyze` clean.**

**Next:** the emulator state machine, split into cell/parser/emulator files per §16.

### 2026-08-04 — Session 13: the escape-sequence parser and the grid cell

Ported the state machine and the cell type. The parser is the one place this port deliberately
**restructures** rather than transcribing, which requirement 13 now explicitly permits (feature
parity, not code parity).

**The Kotlin parser called screen operations directly** — `dispatchCsi` invoked `moveCursor`,
`eraseInDisplay` and friends inline. Here it is a pure lexer that owns only parse state and reports
semantic events to a `TerminalSink` interface, which is the shape vte and vtparse use. The payoff is
immediate: sequence handling is now testable without a screen at all, and the 38 tests in
`terminal_parser_test.dart` assert ESC/CSI/OSC/DCS handling directly rather than inferring it from
rendered output.

Behaviour is unchanged, including the defensive parts that matter:
- unknown sequences are **ignored**, never rendered as text (the contract in
  `docs/TERMINAL_COMPATIBILITY.md`), and C0 controls other than the handled ones are dropped rather
  than printed as glyphs — printing them is the classic way a terminal shows garbage on binary output;
- OSC payloads (titles, hyperlinks, **OSC 52 clipboard writes**) are parsed and discarded, never
  acted on;
- a control sequence longer than 1024 chars is abandoned rather than buffered, so a remote that
  never sends a final byte cannot grow memory without bound.

**A test of mine was wrong, not the port.** I asserted that an over-long sequence's remaining
parameter bytes were dropped. Tracing the Kotlin shows it clears the buffer and returns to *ground*,
so those bytes then print as ordinary text. Test corrected to assert the real behaviour, and to pin
the property that actually matters — nothing is buffered indefinitely and no giant CSI ever
dispatches.

`terminal_cell.dart` keeps the cell **mutable**, deliberately: the emulator rewrites cells tens of
thousands of times a second while a build scrolls past, and allocating an immutable cell per write
would make that path allocation-bound. The immutable view is `TermSpan`, built only at snapshot time.

**Verified — 402 tests pass, `flutter analyze` clean.**

**Next:** `terminal_emulator.dart` — the screen grid, scrollback, scroll regions, alt screen, SGR
pen and reflow.

### 2026-08-04 — Session 14: the terminal emulator — Phase 6 complete

Ported the screen model, finishing `TerminalEmulator.kt`. The 1,177-line class is now six files
(§16): width rules, snapshot types, parser, cell, palette, and the emulator itself.

Covered: printing with soft-wrap tracking, wide-glyph and combining/ZWJ cluster handling, cursor
movement, erase/insert/delete, scroll regions, scrollback with trimming, the alternate screen
(47/1047/1048/1049 with their different cursor semantics), SGR including 256-colour and truecolor,
and windowed snapshots.

Details worth keeping visible:
- **The palette's blue is deliberately non-standard.** Indices 4 and 12 are lifted well above the
  ANSI values because pure blue is very low luminance and unreadable on the near-black background.
  A test pins the exact value so it is not "corrected" later.
- **The Kitty-keyboard guard survives.** `CSI u` restores the cursor only in its *bare* form;
  modern clients send `CSI >1u` etc., and treating those as SCORC is what made a TUI's exit paint
  over stale rows.
- **`_softWrapped` and the span cache are keyed by row identity.** Dart's `List` does not override
  `==`, so a plain `Map` already behaves as an identity map — the Kotlin needed an explicit
  `IdentityHashMap` to say the same thing.
- **The cluster/wide-cell repair logic is ported intact**, including the case where a variation
  selector widens a glyph already sitting in the last column and it must be moved to the next row.

**Two parity gaps recorded in §18 rather than glossed over:**
1. **Resize reflow is not implemented.** The Kotlin re-joins soft-wrapped runs and re-wraps them at
   the new width; this port preserves content top-left and clamps the cursor. A narrowed window
   therefore truncates wrapped lines. The compatibility matrix lists reflow as *Supported*, so this
   must close before cut-over — the `softWrapped` bookkeeping the algorithm needs is already ported
   and maintained, so it is additive work rather than a redesign.
2. The Unicode combining-mark table (from session 12) is a bounded substitute for the JVM category
   database.

**A test of mine was ambiguous, not wrong-headed:** the combining-mark case used a literal `é`,
and the two literals in the file differed in normalisation form. Rewritten to state explicitly that
it exercises the decomposed sequence, and to assert the glyph/width split rather than just the text.

**Verified — 447 tests pass, `flutter analyze` clean.** Phase 6 done.

**Next:** Phase 7 — the ~36k LOC of feature screens, starting with the `AppViewModel` split.

### 2026-08-04 — Session 15: SecretStore, and a data-loss blocker found

Started closing out the data-access layer that Phase 7 depends on, beginning with the
security-critical piece: `SecretStore.kt` → `lib/platform/secret_store.dart`.

**Porting it surfaced the most serious issue of the migration (§7.10).** The Kotlin encrypts every
stored credential under a key generated *inside the Android Keystore* — non-exportable by design,
and unusable from Flutter. The Dart implementation therefore has to use its own key and tag output
`enc:v2:`, which means **every `enc:v1:` value already on a user's device is unreadable**. Shipped
as-is, an updating user would open the app to find every saved password and private key blank — and
silently, because `decrypt` returns null on failure by contract.

The fix is a ~40-line Android method channel that decrypts `enc:v1:` with the original Keystore
alias. The Dart side is already built for it: `legacyDecryptor` is the seam and `onUpgraded` reports
the re-encrypted value so the repository can write it back, making the migration a once-per-value
transparent upgrade on first read. iOS needs nothing. Recorded as a **blocker**, not a nice-to-have.

Design notes on the port itself:
- The wire layout matches the Kotlin (`iv || ciphertext || tag`, base64, no wrapping), so only the
  key differs — which is what makes a bridged migration possible at all rather than a re-entry prompt.
- The pass-through contract is preserved exactly: null/empty unchanged, encryption idempotent, and
  **decrypting plaintext returns null** — callers depend on that to tell "no secret stored" from
  "stored but unreadable".
- A tampered payload fails closed; AES-GCM authentication is asserted by a test that flips bytes.

**Security trade-off recorded honestly (requirement 12):** the v2 key is retrievable into app memory,
where the v1 key was not. Accepted because the alternative is two hand-maintained native crypto
implementations — a larger code-security surface than the one it removes — and because the at-rest
protection (a Keystore/Keychain-guarded key) is preserved.

**Verified — 463 tests pass, `flutter analyze` clean.**

**Next:** `Daos.kt` → Drift DAOs and `AppRepository.kt`, which is where the §7.10 upgrade hook gets
wired, then Phase 7.

### 2026-08-04 — Session 16: the Drift DAOs

Ported `Daos.kt` — 14 Room interfaces — into three Drift accessors grouped by domain
(`server_dao`, `alerts_dao`, `app_data_dao`) rather than 14 near-empty files. Most of these are
plain CRUD; the value is in the handful of queries whose shape is deliberate, and those are what the
24 new tests target, running against a real in-memory database.

Three behaviours worth naming, because each would be easy to lose in a mechanical port:

- **`getLatestMetricsForAllServers` keeps its raw SQL.** The `MAX(id)` tie-break is not decoration:
  two samples written in the same millisecond — a manual refresh racing the periodic poller — would
  otherwise both return and the dashboard would flicker between them. Tested directly. This is also
  the query the `(serverId, timestamp)` index exists for (150k rows: 469s → 0.008s).
- **`serverId != 0` in the "delete except these hosts" queries protects the fleet-wide rule.**
  Rule 0 applies to every host, so a restore keeping a subset of hosts must not delete it —
  dropping it would silently disable fleet-wide alerting. Tested.
- **Alert-history pruning stays raw SQL** with its counting subquery and `(historyTime, id)`
  ordering, applied *per server* so one noisy host cannot evict another's history. A naive
  `ORDER BY … LIMIT -1 OFFSET n` delete is not portable across SQLite builds.

Also pinned: `resetAllConnectionStates` clearing every live field at startup (a persisted "online"
is a lie until re-probed), auth state tracked independently of TCP reachability, and
`deleteSftpBookmarksExcept` touching only bookmark rows rather than taking unrelated settings with it.

**Verified — 487 tests pass, `flutter analyze` clean.**

**Next:** `AppRepository.kt`, which owns the encrypt/decrypt boundary and is where the §7.10 legacy
upgrade must be persisted.

### 15.3 Insert of a new record overwrote the previous one (defect introduced by the port)

Drift's `toCompanion(false)` carries the primary key through even when it is 0, and SQLite accepts 0
as a literal rowid. Room, by contrast, omits an `autoGenerate` key when it is 0. Combined with
`InsertMode.replace`, the first cut of `AppRepository` therefore wrote **rowid 0 for every new
record and silently replaced the previous one** — adding a second host would have deleted the first,
and the same for keys, credential profiles and shares.

Caught by a repository test asserting that two inserted hosts both survive. Fixed with
`_newOrExisting`, which makes the id absent when it is 0. Pinned by tests in all four tables.


### 2026-08-04 — Session 17: the repository — data-access layer complete

Ported `AppRepository.kt`. With it the whole data-access layer is done: tables, the v22 migration
chain, DAOs, the repository, and `SecretStore`.

The repository's real job is **credential hygiene**, and the port keeps that concentrated in exactly
one place: every secret is encrypted on the way in and decrypted on the way out, so no plaintext
reaches the database and no ciphertext reaches the UI. The ViewModels deliberately get no access to
`SecretStore` at all — scattering that boundary is how a password eventually gets written in the
clear. Tests assert it from both directions: they read the raw columns to prove no plaintext is
stored, and read through the repository to prove the UI sees plaintext.

**A defect I introduced, caught by those tests (§15.3).** Drift's `toCompanion(false)` carries the
primary key through even when it is 0, and SQLite accepts 0 as a literal rowid — where Room omits an
`autoGenerate` key when it is 0. With `InsertMode.replace` that meant **every new record was written
as rowid 0 and silently replaced the previous one**: adding a second host would have deleted the
first, and likewise for keys, profiles and shares. Fixed and pinned in all four tables.

Behaviours preserved deliberately:
- `deleteServerAndDependents` is **transactional** — a half-deleted host leaves orphaned alert rules
  firing against an id that resolves to nothing.
- `keepOnlyServers` keeps its `Int.MIN_VALUE` sentinel, because an empty `IN ()` is handled
  inconsistently across SQLite versions; fleet-wide rows (serverId 0) survive via the DAO guard.
- Alert-history limits are **clamped at the repository**, not trusted from callers: a 0 would wipe
  the history on the next prune.
- Only `app_pin` is an encrypted setting; encrypting the theme name would make it unreadable to no
  benefit.

**Verified — 502 tests pass, `flutter analyze` clean.**

**Next:** Phase 7 — the ~36k LOC of UI, starting with the `AppViewModel` split.

### 2026-08-04 — Session 18: Phase 7 begins — AppState and the first ViewModel

Started the §5.2 split of `AppViewModel.kt` (12,310 lines) with the two pieces everything else
hangs off: `AppState` (the shared host list, selection and persisted settings) and
`ServersViewModel`.

The shape matters more than the volume here. Each feature ViewModel reads the host list **from
`AppState`** rather than keeping its own copy — two copies of the fleet is how a screen ends up
acting on a host the user already deleted. And no ViewModel gets access to `SecretStore`: the
encrypt/decrypt boundary stays entirely inside `AppRepository`, because widening it to the
presentation layer is how a password eventually gets logged.

Three behaviours carried across deliberately, each with a test:
- **`selectedServer` falls back to the first host** when nothing is chosen, so screens are usable on
  a cold start — but an id that no longer resolves yields **null, not a substitute**. Silently
  falling back there would run a command against the wrong machine.
- **A concrete id is bound as soon as the list loads.** The Kotlin comment explains why: per-tab
  loaders guard with `server.id != selectedServerId`, so leaving the id null leaves their spinner
  stuck until a host is picked by hand.
- **Changing the selection notifies host-scoped draft owners** (the Compose Builder), while
  re-selecting the same host does not — otherwise a stray tap discards an in-progress edit.

Also pinned: leaving multi-select clears the ticks (a stale tick would let a later bulk action hit a
host the user can no longer see selected); search matches name **and** address case-insensitively;
and a malformed `metrics_retention_days` falls back to 7 rather than 0, which would delete all
history on the next prune.

**Verified — 527 tests pass, `flutter analyze` clean.**

**Next:** the remaining feature ViewModels, then the screens themselves.

### 2026-08-04 — Session 19: the first real screen, end to end

Ported the shared components (`OmniCard`, `OmniStatBox`, `SectionHeader`, the field styling and the
byte/uptime formatters) and the **Servers screen**, then wired the database → repository →
`AppState` → ViewModel → widget chain into `lib/main.dart`. The first placeholder is gone and the
app now renders live data from Drift.

This was worth doing before the remaining ViewModels: it proves the whole stack rather than another
layer in isolation, and it establishes two conventions the other 14 screens inherit.

**Convention 1 — every interactive widget carries a stable `ValueKey('<screen>.<element>')`.**
Flutter paints its own pixels, so the Patrol suite has no native view tree to fall back on. Adding
keys while a screen is written costs nothing; retrofitting them across 36k LOC does not.

**Convention 2 — observable singletons must be *listened* to, not merely read.** A widget test
caught this: "Hide sensitive info" appeared to do nothing. In Compose `HostDisplay` was a
`mutableStateOf`, so every reader recomposed on change; a Flutter widget that reads a
`ChangeNotifier` without subscribing simply never rebuilds. Fixed with `ListenableBuilder`, and the
test now asserts the address actually disappears — which is the entire point of the feature.

Smaller decisions preserved from the Kotlin: the offline stat is red **only when non-zero** (a
permanent red zero is noise the eye learns to ignore); the empty state distinguishes "no hosts" from
"no matches" (the same blank screen for both leaves the user thinking their fleet vanished); the
group chip bar is hidden when only "All" exists; and a card reports **authentication failed**
separately from offline, because calling a credential rejection "online" sends the user hunting the
wrong fault.

**Verified — 539 tests pass, `flutter analyze` clean, debug APK builds.** Still not run on a device.

**Next:** Monitor, then Infra/Fleet/SFTP/Tools, plus the Servers add/edit sheets.

### 2026-08-04 — Session 20: the server form's logic (two security controls)

Extracted `AddServerSheet`'s logic into `server_form_state.dart`, a plain `ChangeNotifier` with no
widget dependencies, because two of its rules are **security controls rather than presentation** and
both deserve direct tests:

1. **Stored secrets never reach the form.** On an edit the password fields start empty; an empty
   field means "keep the saved value", and only an explicit `forget…` flag clears one. A saved
   password is therefore never rendered into a text field where it could be shoulder-surfed,
   screenshotted, or read out by an accessibility service. Typed text wins over the forget flag,
   since typing a replacement is the more explicit intent.
2. **Saving requires a passing connection test for the *current* configuration.**
   `connectionSignature` fingerprints every connection-relevant field, so changing a host,
   credential or proxy invalidates a previous pass — which is what stops the first-connect host-key
   approval from being skipped by editing an already-tested host. Cosmetic edits (name, group,
   colour, notes) deliberately do not force a retest, and a saved host counts as already tested. A
   test iterates all twelve connection fields and asserts each one invalidates the pass.

**Caught while writing it:** I documented the signature as NUL-joined and then wrote a *space*
separator. A space is exactly the forgery the comment warns about — `("a", "b c")` and
`("a b", "c")` would produce the same fingerprint, so a crafted username could make a changed host
look already-tested. Fixed to the NUL separator the Kotlin used, with a test that the two cannot
collide.

Duplicate semantics preserved: it seeds the source's secrets (the point of "reuse credentials") but
saves through the add path with id 0, faces the host-key gate afresh, and does **not** inherit the
source's health or status — a copy shares no live state with its source.

**Verified — 564 tests pass, `flutter analyze` clean.**

**Honest status:** this is the form's *logic* only. The sheet **widget** is not written, so the app
still cannot add a host — the Servers screen remains read-only. That is the next task.


---

### Session 21 — the server form sheet: the app can now create a host

`lib/ui/screens/servers/server_form_sheet.dart` (~460 lines) — the add / edit / duplicate modal,
ported from `AddServerSheet` (`ui/AppUi.kt` line 2213). Three tabs in the Kotlin's order — Connect
(name, host, port, user, group, colour), Auth (password / key / profile), Advanced (notes,
keepalive, compression, persistent session, agent forwarding, sudo password, proxy) — so a user's
muscle memory survives the migration. The widget is presentation only; every rule it enforces lives
in the already-tested `ServerFormState`.

**The Servers screen is now writable.** A FAB (`servers.add`) opens the add sheet; a long press on a
card opens it in edit mode. Both go through one `openServerForm` entry point rather than each
wiring the repository call themselves.

**New: `lib/domain/server_credentials.dart` — one credential resolver for the whole app.**
Turning a stored `Server` row into `SshCredentials` was about to be needed by Test Connection, the
terminal, the monitor poller, SFTP and the fleet runner. Written once (§16, requirement 11), because
duplicating it per screen is how a host ends up connecting with different credentials depending on
which button was pressed. Its refusals are the interesting part — all four raise
`CredentialResolutionException` rather than falling back:

| Situation | Behaviour |
|---|---|
| `authType == 'key'`, alias no longer saved | Error. A silent fall back to the stored password would send a credential somewhere the user never agreed to send it, and would hide the real fault. |
| `authType == 'key'` | The stored password is dropped from the credential set entirely, so a server that rejects the key cannot then harvest the password. |
| Credential profile deleted or unset | Error, rather than connecting as the host row's own user. |
| Jump-host key missing | Error, rather than attempting the jump with the target's key. |

A profile is treated as an indirection, not a third mechanism: it supplies the identity, then the
ordinary password/key rules apply to what it supplied — including the key rules above.

`ServersViewModel` gained an **injected, nullable** `SshTransport`. Null means Test Connection is
unavailable and the button is disabled; it is never stubbed to report success. That is now
convention 4 in the NEXT ACTION block. The test runs against the *unsaved* form row, so it
exercises exactly what is about to be written rather than what is currently stored.

**Verified — 592 tests pass (28 new), `flutter analyze` clean.** The 14 widget tests drive the sheet
the way a user does: fill three fields, test, save, and assert the row that came out. They cover the
end-to-end create path, an edit updating in place, a duplicate, both save refusals (untested
configuration, failed test), a retest forced by changing the host after a pass, and — through the
rendered widget, not just the state class — that a saved password never reaches the text field, that
leaving it blank keeps the stored value, and that only the explicit Forget tick clears it.

**Still not done on this screen:** the key picker lists aliases passed in by the caller, and the
Servers screen does not yet pass them (Auth keys live in Tools, not yet ported), so a key-auth host
cannot be created from the UI until Tools lands. Password and profile hosts work today.

---

### 15.4 Monitor kept showing a host that had gone offline

`MonitorScreen` (`ui/MonitorScreen.kt` line 42) chose its host as:

```kotlin
val explicitlySelected = serversList.find { it.id == viewModel.selectedServerId }
val srv = explicitlySelected ?: onlineServers.firstOrNull()
```

`explicitlySelected` matched on id alone, with no status check, while the selector bar directly
above it is built with `onlineOnly = true`. So once the selected host dropped offline:

| | Kotlin | Flutter |
|---|---|---|
| Body of the screen | keeps rendering the offline host | falls back to the first online host |
| Selector bar | no longer lists that host | lists the host being shown |
| Switching away | impossible from the bar — the current host is not in it | normal |
| Tabs | keep issuing SSH commands at a host that is down | query a host that can answer |
| "No online hosts" empty state | unreachable while a stale selection persists | shown when nothing is online |

The header and the body disagreed about which machine was on screen, and the only escape was to go
to Hosts and pick another. `MonitorViewModel.monitoredServer` now prefers the explicit selection
**only while it is still online**. Tests cover the fallback, the return to the empty state when the
last host drops, and that an online explicit selection still wins.

---

### Session 22 — Monitor: ViewModel, four working tabs, and the shell-quoting primitive

**`lib/ui/view_model/monitor_view_model.dart`** — host selection, the six-tab state, per-tab
loading, process sorting, the log filter and live tail, service actions and reboot. **`lib/ui/
screens/monitor/`** (`monitor_screen.dart` + `monitor_tabs.dart`, ~900 lines) — the selector bar
with health ring and reboot, the scrollable tab row, and Overview / Processes / Services / Logs.
Wired into `app_scaffold.dart`, replacing the placeholder, and into `main.dart`'s providers.

**`lib/data/remote_commands.dart` grew from a stub to the monitor slice**: `shellQuote`,
`sudoWrap`/`sudoShWrap`/`sudoStdin`, the per-OS process, service, log and metrics probes, plus
`serviceAction`, `rebootCommand` and `killProcessCommand`.

`shellQuote` is the injection-prevention primitive and had not been ported at all. Its tests assert
that `;`, `&&`, `|`, `$(…)`, backticks, newlines and globs all survive as literal text, that an
embedded `'` cannot end the quoting, and that an empty value still yields `''` — unquoted, an empty
argument vanishes and shifts every later argument by one position. Separately, the sudo password is
asserted **absent** from every command string it could appear in and present only on stdin: a
command line is visible in `ps`, auditd execve records and sshd debug logs on the remote.

**Three defects fixed while porting:**

1. **§15.4** (above) — Monitor rendered a host that had gone offline, with no way to switch away.
2. **A sort toggle cost a network round trip.** The Kotlin re-ran `ps` over SSH when the user
   switched CPU ⇄ MEM (`LaunchedEffect(srv.id, viewModel.processSortByCpu)`), so reordering a list
   already in hand waited on the host. Now sorted locally; a test asserts no new command is issued.
3. **A load completing after the screen closed would crash.** Caught by a test: leaving Monitor
   mid-fetch notified a disposed `ChangeNotifier`, which throws. This is ordinary use, not an edge
   case — every post-await notification now goes through a disposal guard, and a test disposes the
   view model with a fetch in flight.

**Stale replies are structurally prevented, not just guarded.** `_load` takes a callback that
*returns* a commit closure rather than mutating state directly, and `_load` invokes it only if the
user is still on the same host. Checking after the fact would have left the mutation already
applied. A test gates a slow `ps` reply, switches host mid-flight, and asserts the first host's
processes never appear under the second's name.

**Verified — 647 tests pass (55 new), `flutter analyze` clean.**

Also extracted `test/support/fake_secure_storage.dart`: three suites needed it, and a second
divergent copy is how a test starts passing against behaviour the real store does not have (§16,
requirement 11). `GaugeBar` and `OmniTag` joined `omni_components.dart` for the same reason.

**Honest status on this screen:** Scripts and CRON render a "not available in this build yet" note
rather than a blank pane — a blank pane reads as "this host has nothing", a different and misleading
claim. Overview shows the numbers but **not** the sparkline charts (`MetricLineChart`) or the health
breakdown dialog; both need the telemetry history poller, which is not ported. Added to §18.

---

### Session 23 — the §7.10 blocker is closed, plus Infra foundations

The user decided both open blockers this session: **"1. do it and 2. go platform native"**. §7.10 is
built and verified; §7.1 is recorded as a decision and not yet started.

**§7.10 — Kotlin-era credentials can now be read.** Three parts, described in full in §7.10 above:
the Android `LegacySecretBridge` method channel, the Dart `LegacySecretChannel`, and
`AppRepository.migrateLegacySecrets()`.

The design decision worth restating: the migration walks the **raw, still-encrypted** rows rather
than reading through the decrypting accessors and writing back. Those accessors map an unreadable
secret to null or `""`, so the obvious read-then-write implementation would have overwritten exactly
the values the bridge exists to rescue — turning a recoverable problem into a permanent one. A field
that cannot be read is now left byte-identical on disk. `SecretStore.upgradeLegacy` returns
ciphertext rather than plaintext, so a pass over every credential on the device never holds a
password in a variable.

14 tests cover it, including the properties that matter most: an unreadable secret keeps its exact
bytes, one bad value does not block the rest, a device with no bridge changes nothing, the pass is
idempotent, and a fresh install never touches the platform channel at all. `flutter build apk
--debug` compiles the Kotlin.

**Infra foundations** (the screen itself is *not* done):
- `lib/domain/stack_summary.dart` — rolls a flat container list into one row per compose project.
  Grouped by **(runtime, project)** rather than project alone: a host running both Docker and Podman
  can have same-named projects under each, and merging them would produce one row whose buttons hit
  whichever runtime happened to sort first.
- The container command slice in `remote_commands.dart` — ps, images, volumes, networks, restart
  counts, runtime detection, per-resource actions and prune.

The container commands needed care that is easy to underrate: Dart's `$` interpolation collides with
the shell's, and a mis-escaped `$` produces a command that still reads correctly in source but
silently expands to nothing on the host. One such bug (`\$ids` instead of `$ids` in the restart-count
probe) was introduced and caught by a test asserting the generated text contains no backslash-dollar.
The tests also pin the per-engine template differences that are genuinely load-bearing: Docker has a
`.Label "key"` method and a string `.Labels`; Podman has no `.Label` and a map `.Labels`; Docker's
inspect field is `.Id` and Podman's is `.ID`. Using either engine's syntax on the other errors out.

**Verified — 676 tests pass (30 new), `flutter analyze` clean, debug APK builds.**

**Honest status:** Infra is still a placeholder in `app_scaffold.dart`. `InfraViewModel` and the
screen are the next task, and the Compose Builder inside it deserves its own iteration.

---

### Session 24 — Infra: containers, stacks and the downed-stack registry

`lib/ui/view_model/infra_view_model.dart` and `lib/ui/screens/infra/` (`infra_screen.dart` +
`infra_tabs.dart`), wired into `app_scaffold.dart` in place of the placeholder. Four of the five
tabs work — Stacks, Images, Volumes, Networks. The Compose Builder renders a note saying it is not
in this build yet.

The compose command slice joined `remote_commands.dart`: `dockerComposeAction` (with the run-time
entrypoint resolver that copes with all four of `docker compose`, `docker-compose`,
`podman compose` and `podman-compose`) and `composeConfigPresent`.

**Things the port had to get right, and why:**

| | |
|---|---|
| Six probes issued **concurrently** | Serialising independent probes multiplies round-trip latency by six on exactly the screen a user opens to check something quickly. |
| A transport failure **clears** every list | Keeping the previous rows would present one refresh's state as current; keeping the *registry* rows would report stacks as "down" on no evidence at all. |
| Image "in use" matched **within a runtime** | A host running both engines pulls the same `repo:tag` into each. Crossing them would let the UI offer to delete an image that is actually running. |
| Restart counts keyed `runtime:id` first | A Docker and a Podman container can share an id prefix. |
| Every action **refetches** rather than patching locally | Guessing the post-action state is how a UI ends up quietly disagreeing with the host. |
| Compose actions always `cd` into the working directory | Compose resolves relative bind mounts and `.env` against the working directory, so running from elsewhere can silently bring up a *different* stack from the same file. |

**The downed-stack registry** is ported in full: a compose project brought down with `compose down`
has no containers, so it would vanish from a `ps`-derived list entirely — but its file is still on
disk and it can be brought back. Projects are remembered per host, and one with no resolvable
working directory is deliberately *not* recorded: no compose action could ever run for it, including
a later "up", so there is nothing actionable to remember. Bringing one back up probes that the
compose file still exists first, because a file can be moved behind the app's back and compose's own
missing-file error is confusing; the app says plainly that it is gone and offers to forget the stack.
Forgetting is local only — a test asserts it sends nothing to the host.

**Destructive actions are gated by what they actually destroy.** A container or image can be
re-pulled, so removal is one tap. A volume *is* the data, so its dialog says the contents cannot be
recovered, and the volume prune warns that it includes named volumes. Built-in networks (`bridge`,
`host`, `none`, `podman`) get no delete button at all: removing them breaks container networking and
they cannot be recreated identically.

Compose output is shown **verbatim and selectable**. Compose failures are diagnosed from their exact
wording and get pasted into issue trackers, so paraphrasing them is worse than useless.

**Verified — 710 tests pass (34 new), `flutter analyze` clean.**

---

### 15.5 The destructive-command warning missed `dd if=… of=…`

`commandDangerHits` (`ui/FleetScreen.kt` line 862) is Fleet's last check before a command runs on
every selected host at once. Two of its patterns only matched when the destructive flag came *first*:

```kotlin
Regex("""\bdd\s+\S*of=""")                      // dd
Regex("""\biptables\s+(-\w+\s+)*-F\b""")        // iptables
```

`\S*` cannot cross a space, so after `dd ` it can only reach an `of=` inside the *same* token.

| Command | Kotlin | Flutter |
|---|---|---|
| `dd if=/dev/zero of=/dev/sda bs=1M` | **not flagged** | flagged |
| `dd of=/dev/sda if=/dev/zero` | flagged | flagged |
| `dd if=/dev/sda of=/backup/disk.img` | **not flagged** | flagged |
| `iptables -F` | flagged | flagged |
| `iptables -t nat -F` | **not flagged** | flagged |

The first row is the textbook disk-destroyer, written the way every tutorial writes it — and it was
the one form the warning did not catch. Broadcast it across a fleet and every host is wiped with no
extra confirmation. Both patterns now scan to the end of the command segment (`[^;&|\n]*`) instead of
one token, and a test pins that flag order does not decide whether a command is caught.

This defect exists in the shipped Android app today.

---

### 15.6 The Kotlin fixes are shipping too — branch `fix/kotlin-parity-defects`

The Flutter release is not imminent and the Kotlin app still ships, so the defects above are fixed
in **both** codebases. Branch `fix/kotlin-parity-defects` (cut from `origin/main`) carries §15.1,
§15.4 and §15.5 back to Kotlin with 15 new unit tests — `LogSeverityStemsTest` and
`CommandDangerHitsTest` — and 484 unit tests pass on it.

§15.2 and §15.3 are **not** back-ported: both were defects the port introduced and caught before
commit, and neither exists in the Kotlin.

**From here on, a §15 entry is not finished until it is fixed on both branches.**

---

### Session 25 — Fleet: dashboard, broadcast and merged logs

`lib/ui/view_model/fleet_view_model.dart` and `lib/ui/screens/fleet/`, wired into
`app_scaffold.dart`. All three tabs work. `lib/domain/command_danger.dart` holds the
destructive-command classifier as testable logic, per convention 3.

**§15.5 above is the headline:** the Kotlin's `dd` rule missed the canonical
`dd if=/dev/zero of=/dev/sda`, and its `iptables` rule missed `iptables -t nat -F`. Both are fixed,
with 35 tests over the classifier.

**Broadcast is the security-sensitive surface here, and the design follows §17: warn, never block.**
The user picked these hosts and may run what they like on them — a fleet-wide `reboot` is a
legitimate thing to want. What justifies interrupting is the *multiplier*: the same typo costs one
host or forty. So the confirmation dialog **names every host** rather than saying "5 hosts", which is
not something a user can check, and adds the danger sentence when one applies.

**The targets shown are the targets used.** `runBroadcast` takes the list the dialog displayed rather
than re-resolving it. Cached reachability can change between confirming and running, or simply be
stale after a resume; re-resolving would silently drop a host the user explicitly approved. Better to
attempt it and show that host's real SSH error.

Three concurrency properties, each tested:
- **At most six hosts at once.** Unbounded fan-out opens one SSH connection per host simultaneously —
  a self-inflicted connection storm on a large fleet, and on a phone it exhausts sockets and battery.
- **A run generation counter.** `timeout` abandons the wait but cannot cancel the workers, so they
  keep running; without the counter they would write into whatever run is current when they finally
  return, resurrecting a finished card as "running" or mixing one run's output into the next.
- **Anything not finished when the workers return is marked failed**, so an abandoned run never keeps
  showing a spinner.

Stale targets are pruned as hosts go offline — otherwise a ticked host that dropped would still be
counted, and the user would confirm "run on 5 hosts" and get four with no explanation. Group mode
resolves to *currently online* members, so a group is never a promise about hosts that cannot answer.

The dashboard sorts **worst score first** (offline last): the reason to open a fleet dashboard is to
find what needs attention, and a name-sorted list buries it. An offline host shows an OFFLINE tag
rather than its last score — a score for an unreachable host is a stale number pretending to be
current. Fleet logs merge across hosts newest-first with the host name leading each line, and one
unreachable host does not empty the view.

**Verified — 782 tests pass (72 new), `flutter analyze` clean.**

---

### Session 26 — SFTP: browser, bookmarks and transfers

`lib/ui/view_model/sftp_view_model.dart` and `lib/ui/screens/sftp/`, wired into `app_scaffold.dart`.
Three of the four tabs work. Shares renders a note pointing at §7.1.

Two new domain files, both extracted because they are easy to get subtly wrong and worth testing
directly (convention 3):

**`lib/domain/remote_path.dart`.** These are always *remote* paths, so `dart:io`'s `path` package is
deliberately not used — it follows the *host* platform's separator, and on Windows it would build
`C:\srv\www` for a Linux server. The two rules worth naming:
- `isWithin` compares **segment-wise, not as a string prefix**. `/srv/www-old`.startsWith(`/srv/www`)
  is true, but it is a sibling — a prefix test would refuse a legal move, or permit one into a
  directory the user never named.
- `uniqueName` puts the counter **before** the extension (`notes (2).txt`) so the copy still opens in
  the same application, and treats a leading dot as a whole name — `.bashrc` becomes `.bashrc (2)`,
  never ` (2).bashrc`.

**`lib/domain/sftp_sort.dart`.** Directories lead in every mode except "files first", including size
and date. That is deliberate: a directory's reported size is its *inode's*, not its contents', so
interleaving folders by size would order them by a number that means nothing to the user. Ties fall
back to name so the order is stable between runs.

**Two defects found and fixed while building this:**

1. **An error raised by a file operation was wiped before it could be read.** `_mutate` set `_error`
   and then called `refresh()`, whose first act is `_error = null`. A failed delete or mkdir would
   have flashed and vanished. The order is now: run, refresh, *then* report — so a partly-succeeded
   operation still leaves the listing current and the error still reaches the user.
2. **The rename/new-folder dialogs disposed their `TextEditingController` too early.** Disposing it
   as soon as `showDialog` returns leaves the still-running exit animation rebuilding a `TextField`
   around a disposed controller, which throws. Caught by a widget test. The controller now lives in a
   small `_NameDialog` widget so it dies with the dialog.

Other behaviour worth recording:
- A listing failure **clears the rows**. Leaving the previous directory's entries visible under a
  path that failed to open invites acting on the wrong files.
- Navigating **clears the selection** — carrying it into another directory would let a delete act on
  names that happen to match there.
- An upload **never silently overwrites**: a clashing name gets a `(2)` suffix. Replacing a file the
  user did not mean to touch is unrecoverable.
- A delete dialog says how many *folders* are included and that their contents go too, which is the
  part users misjudge.
- Bookmarks are stored **per host** in the Kotlin's exact `|||`-joined format, so an upgraded install
  reads the bookmarks it already had. A host with none gets a useful default list.
- A transfer with an unknown size gets an **indeterminate** progress bar rather than a made-up
  fraction.

`SftpViewModel.start()` is explicit rather than constructor-driven: the host list may already have
been emitted by `AppState` before the view model subscribed, in which case no change notification is
coming and nothing would ever load. That bug was caught by the first test run.

**Verified — 856 tests pass (74 new), `flutter analyze` clean.**

---

### Session 27 — Tools, part 1: Auth Keys, and the server form's key picker

`lib/domain/ssh_key_import.dart`, `lib/ui/view_model/auth_keys_view_model.dart` and
`lib/ui/screens/tools/auth_keys_screen.dart`, wired into `app_scaffold.dart`. Three sections:
credential profiles, SSH keys, and pinned host keys — together they are the app's whole answer to
"who am I, and who am I talking to".

**The server form's key picker now works.** It has been inert since session 21 because there was no
key store to populate it; `ServersViewModel.savedKeyAliases()` now feeds it, so a key-authenticated
host can be created from the UI for the first time. That closes the gap flagged in the session 21
commit message.

**`privateKeyParseError` was added to `ssh_private_key.dart`** so bad key material is rejected at the
moment it is pasted rather than stored and failed at connect time, where the message arrives while
the user is doing something else and gives no hint the key was at fault. An *encrypted* key is
explicitly not a failure — it parses once its passphrase is supplied, which the app asks for at
connect time.

**Security decisions in this screen:**

| | |
|---|---|
| The fingerprint hashes the **decoded** base64 blob | So it matches `ssh-keygen -lf` on the host exactly. A fingerprint you cannot compare with the one the server prints has no purpose. It is also selectable, because comparing means copying. |
| A key profile never carries a password | A server that rejects the key could otherwise harvest it — the same rule the credential resolver enforces at connect time (§ session 21). |
| Deleting names the dependent hosts | "Delete this key" gives no sense of the blast radius, and the private material cannot be recovered. |
| Revoking a host key explains what it costs | Forgetting a pin removes the protection that would otherwise catch an interception, so the dialog says the next connection asks again, and when that is the right thing to do. |
| Editing a profile never shows the stored password | Same rule as the host form: an empty field means "unchanged". |
| Renaming a key updates the hosts that reference it | The alias is what a host records; leaving it stale would break authentication silently. |

**A bug caught by the tests:** `splitHostPort` originally took the last colon, which mangles the
`[host]:port` form the trust store actually writes — the revoke would then have matched nothing and
silently failed. It now parses the bracketed form first, which also makes a bare IPv6 address
(full of colons) resolve correctly instead of having its last group read as a port.

**Verified — 907 tests pass (51 new), `flutter analyze` clean.**

---

### Session 28 — Tools, part 2: Scripts, and Fleet's preset picker

`lib/data/script_presets.dart`, `lib/ui/view_model/scripts_view_model.dart` and
`lib/ui/screens/tools/scripts_screen.dart`, wired into `app_scaffold.dart`. Two lists over one table:
Quick scripts run on the selected host, Fleet commands are broadcast.

**Fleet's broadcast preset picker now works** — the gap flagged in the session 25 commit. It reads
the same scripts store the tool manages rather than carrying its own command list, so the two cannot
drift apart. Tapping a preset **fills the command field rather than running it**: the confirmation
dialog is where a broadcast gets approved, and a preset must not be a way around it.

**The preset keys are the load-bearing part.** A seeded row is claimed as the app's by its
`presetKey`, never by its name or command — matching on text would miss a renamed row and, worse,
could delete a user's own script that happened to share a name. A test cross-checks the seed list
against `kLegacyScriptPresets` (the 19 → 20 migration's back-stamp list) in both directions, so a key
or name that drifts between them is caught rather than silently leaving rows unclaimed on an upgraded
install.

Preset lifecycle, all tested:
- Enabling **re-seeds**, which resets edits — the confirmation says so, and the editor repeats it
  when you open a preset.
- Enabling twice does not duplicate: the existing row id is reused, so the family cannot accumulate
  on each toggle.
- Disabling removes only rows carrying that family's keys; the user's own scripts survive, and so
  does a renamed preset's removal.
- Both operations run in **one transaction** — a half-seeded family with the flag already flipped
  would show an "on" toggle over a partial list, and re-toggling would not repair it.

A row that is neither quick nor fleet is refused: it would be invisible everywhere. For the same
reason a script cannot be toggled out of its *last* list.

**A small UI fix made while testing:** the editor's validation error sat at the bottom of a scrolling
list, so on a phone you had to scroll to find out why Save did nothing. It now sits directly above
the Save button.

`_companion` builds the row with an **absent** id for a new script rather than a literal 0 — the
§15.3 defect in a different table, where `InsertMode.replace` would have made every new script
overwrite the previous one. A test covers it.

**Verified — 960 tests pass (53 new), `flutter analyze` clean.**

---

### Session 29 — Tools, part 3: Alerts, and a correction to how presets are tested

`lib/domain/alert_evaluation.dart`, `lib/data/alert_presets.dart`,
`lib/ui/view_model/alerts_view_model.dart` and `lib/ui/screens/tools/alerts_screen.dart`, wired into
`app_scaffold.dart`. Three tabs — what is firing, the rules behind it, and the archive — plus the
evaluation path itself, which raises and resolves incidents from telemetry samples.

**§16.4 is the important part of this session.** The user's directive — *port the feature set, not
the code set* — is now recorded, and two test suites written earlier this week were corrected under
it. They asserted the preset seed lists matched the Kotlin's legacy back-stamp lists exactly, which
is a fact about how the Android app grew rather than about what the feature does; under it, adding
any *new* preset would have failed the build. Both now assert the feature contract and treat the
legacy lists as a one-way data-compatibility check.

**Two defects found and fixed while building this:**

1. **`evaluate` read its own writes through a lagging stream.** Active alerts and rules came from the
   stream-backed caches, which trail their own writes by a microtask. Evaluating several hosts in one
   poll — the normal case — meant a rule could raise the same incident twice, or fail to resolve one
   raised moments earlier. It now reads from the repository, as the Kotlin did, and a freshly raised
   incident is visible to the rest of the same pass.
2. **The rule editor's preview did not update as you typed.** It restates the rule in words
   ("CPU Usage above 75% for 5m"), which is the whole point of having it, but it only rebuilt when a
   dropdown changed — so the number it showed was the previous one.

Behaviour worth naming, all tested:

| | |
|---|---|
| A temperature rule never fires on a host with no sensor | `currentValueFor` returns **null**, not 0. Substituting zero would make every VM look permanently cool — the same outcome by accident rather than design. |
| A disk rule watches its own mount | The aggregate figure is a fallback for `/` only. Reporting root usage under a `/srv` rule would name the wrong filesystem. |
| A fleet-wide rule fires **per host** | One rule id is shared across hosts, so the host is part of the incident match; otherwise one machine's incident would suppress every other machine's. |
| A sampling gap restarts the window | An alert about a period nobody measured is not evidence of anything. |
| Editing a rule's terms clears its incident | It was raised under a threshold the rule no longer has. Editing a *note* does not. |
| A percentage threshold above 100 is refused | A rule that can never fire looks healthy, and nothing signals it is broken. |
| Muting keeps the incident listed | It stops the re-alert, not the problem — the sheet says so, and the tab badge counts unmuted incidents only. |
| History stores the host name, not a live lookup | An archived incident must stay readable on its own terms; a later rename does not rewrite what it said. |

**Verified — 1025 tests pass (66 new), `flutter analyze` clean.**

---

### Session 30 — Tools, part 4: Network

`lib/domain/network_tools.dart`, `lib/data/network/network_probe.dart`,
`lib/ui/view_model/network_view_model.dart` and `lib/ui/screens/tools/network_screen.dart`, wired
into `app_scaffold.dart`. Five tabs: Host scan, Wake-on-LAN, Ping, Port scan, DNS.

**Everything here runs from the device, not over SSH** — these are the tools you reach for precisely
when a host is *not* answering and you cannot get a shell on it.

**Written against the protocols, not transcribed (§16.4).** The magic packet and the DNS wire format
are standards; the Kotlin was consulted for behaviour choices (which record types, which ports,
timeouts) rather than copied. `network_tools.dart` deliberately imports no `dart:io`, so every
byte-level decision is testable without a socket — DNS is a format where an off-by-one in a length
prefix produces a query the server silently ignores, which at the UI is indistinguishable from "no
records".

**The probe layer is an interface** so no test touches a real network. A test that depends on the
dev machine's own LAN passes here and fails on a laptop in a café, which is exactly the
host-dependence the memory notes warn about.

**Decisions worth naming:**

| | |
|---|---|
| Ping is a **TCP connect**, not ICMP | An echo request needs a raw socket — root on Android, unavailable to a sandboxed iOS app. The screen says so plainly, because a host that is up with nothing on the port reads as down and the user needs that to interpret the result. |
| DNS falls back to a second resolver | One provider being blocked on a locked-down network is common; a single resolver would report that as "DNS is broken". |
| …but **not** after a server *answers* | NXDOMAIN and REFUSED stop the fallback. Asking another resolver would turn a clear answer into a vague timeout. |
| Each query carries a random transaction id | The echoed id is the only cheap check that a reply answers *this* question rather than a previous one. |
| Name compression has a jump cap | A malformed or hostile response can point a name at itself; without the cap, parsing would spin forever inside the app. |
| A sweep skips `.0` and `.255` | Neither is a host, and a reply from the broadcast address is an echo rather than a device. |
| Results sort numerically | `.10` before `.9` reads as though addresses are missing. |
| Port scans are capped and bounded | A fat-fingered `1-65535` would start a scan that never visibly finishes; unbounded fan-out exhausts a mobile process's descriptors and is slower, not faster. |
| Only open ports are listed | Two dozen closed rows bury the answer. |
| An invalid MAC is refused at **save** time | A saved target with a bad MAC looks fine in the list and silently does nothing every time it is tapped. |
| The broadcast is derived from the host's own IP | A directed broadcast reaches a sleeping machine; many routers drop `255.255.255.255`. |

**A bug caught by the tests:** the broadcast derivation guarded on `subnetPrefixOf('0.0.0.0')` but
then dereferenced `subnetPrefixOf(ipAddress)` — different expressions, so saving a target with no IP
threw a null-check error instead of falling back.

**Verified — 1100 tests pass (75 new), `flutter analyze` clean.**

---

### Session 31 — Tools, part 5: encrypted Backup and restore

`lib/domain/backup_selection.dart`, `lib/data/backup/` (envelope + payload),
`lib/ui/view_model/backup_view_model.dart` and `lib/ui/screens/tools/backup_screen.dart`, wired into
`app_scaffold.dart`.

**The envelope format is deliberately unchanged from the Android app**, so a backup taken there
restores here: AES-256-GCM over gzipped JSON, keyed by PBKDF2-HMAC-SHA256 at 600 000 iterations.
Like §7.10, that is data compatibility for a real user's file rather than historical residue (§16.4).

**A backup file is untrusted input** — it arrives from a cloud drive, a chat message, or an
attacker. Every guard below exists for that, and each is tested:

| | |
|---|---|
| A wrong passphrase is reported **as a wrong passphrase** | The whole reason for an authenticated cipher. Without the GCM tag a bad key decrypts to garbage that then fails to parse, and the user is told their backup is corrupt. |
| The declared KDF work factor is range-checked | A crafted file claiming one iteration makes an offline guess of the passphrase cheap; one claiming a billion wedges the device. |
| Decompression is bounded by **ratio and absolute size** | A zip bomb is a small file that expands to gigabytes. The ratio catches it long before the absolute cap would. |
| JSON nesting depth is checked **before parsing** | Deep nesting is the standard way to blow a recursive-descent parser's stack — by the time the parser has recursed that far, the damage is done. String contents are excluded, so a legitimate backup containing `awk '{{{…}}}'` still opens. |
| Salt, IV and ciphertext lengths are validated | Including a floor of 16 bytes, below which there is not even a tag to authenticate. |

**Behaviour decisions:**

- **The referential closure is enforced in the model, not the UI.** Selecting alert rules pulls in
  hosts; selecting firing alerts pulls in both their rule and its host; and *unticking* hosts
  unticks everything that depends on them. Either direction, left alone, produces a backup whose
  rows restore into dangling references.
- **A restore is additive.** Nothing is deleted or overwritten, because there is no undo and
  restoring the wrong file would otherwise be unrecoverable. The screen says so before the button.
- **A rule whose host is not in the backup is skipped and reported**, not restored against an
  arbitrary host — which would silently point it at the wrong machine. A fleet-wide rule
  (`serverId == 0`) keeps its scope, since remapping it would narrow "every host" to one.
- **A restored host starts unprobed** rather than carrying its old health score, which would be a
  figure for a connection never made on this device.
- **The app lock PIN is never exported.** It is a credential for *this* device, not a preference;
  restoring it elsewhere would carry a lock the user never set there.
- **Pristine presets are not exported**; a fresh install re-seeds them, so carrying them would
  duplicate defaults. An *edited* preset is exported with its key, so the toggle can still remove it.
- **An unknown section in the file is ignored**, so a backup from a newer build is not unreadable by
  an older one.

**Verified — 1174 tests pass (74 new), `flutter analyze` clean.** The suite now takes ~50 s, most of
it PBKDF2 at the real work factor — which is the point of choosing that factor.

---

### Session 32 — Tools, part 6: Health Scoring

`lib/domain/health_tier_form.dart`, `lib/ui/view_model/health_scoring_view_model.dart` and
`lib/ui/screens/tools/health_scoring_screen.dart`, wired into `app_scaffold.dart`.

The scoring arithmetic was already ported (`domain/health_scoring.dart`, session 4). What this adds
is the editor around it — twenty-four numbers that decide every host's score — and the validation
that keeps them meaningful.

**The failure worth preventing is silent.** Thresholds that do not ascend make the middle tier
unreachable, so that metric quietly stops deducting anything and a struggling host keeps reporting
100. Nothing about the UI would look wrong. So the order check is a hard block on saving, flagged on
the metric it belongs to rather than as one message at the bottom of a long form.

**Decisions:**

| | |
|---|---|
| Fields hold **text**, not numbers | A half-typed value ("9" on the way to "90") must not be rejected mid-keystroke, and clearing a field must not silently substitute a zero. |
| The draft is separate from the saved config | Otherwise every host's score would shift under the user as they typed. |
| An empty field says "required", not "must be a number" | The latter reads as though what was typed was wrong, when nothing was typed. |
| One error at a time, in reading order | Six messages under a six-field form is noise rather than guidance. |
| Equal thresholds are **allowed** | Collapsing two tiers is a legitimate choice: it means "go straight to critical". |
| A zero penalty is allowed | It is how a user says "ignore this metric" without deleting anything. |
| Latency may exceed 100 | It is milliseconds; the other three are percentages and cannot. |
| A penalty above 100 is refused | The score starts at 100, so anything larger is meaningless. |
| Saving re-seeds the fields from what was stored | Otherwise the form could disagree with the rule it just wrote. |

**The live worked example is the point of the screen.** These numbers are abstract on their own —
"warn at 50" means nothing next to "a host at 60% CPU now scores 95". Sliders set a hypothetical
host's readings and the breakdown shows exactly which tiers fired and what each cost. When the draft
is unusable the preview is **withheld** rather than showing a score derived from half-typed
thresholds.

**Verified — 1208 tests pass (34 new), `flutter analyze` clean.**

---

### Session 33 — Tools, part 7: Settings, About, and the hub — Tools is complete

`lib/domain/app_preferences.dart`, `lib/ui/view_model/settings_view_model.dart`,
`lib/ui/screens/tools/settings_screen.dart`, `about_screen.dart` and `tools_hub_screen.dart`, all
wired into `app_scaffold.dart`. **Every tool view is now ported**, and the only placeholder left in
the app is the Shell screen.

**Settings** is twenty-six preferences behind one typed value. Each maps to the `app_settings` key
the Android app already writes, so an upgraded install keeps its choices instead of silently
reverting — data compatibility, like §7.10 and the backup envelope.

**The clamping is the substance, not the plumbing.** These values feed timers, buffers and retention
windows, and nothing stored is trusted unbounded:

| | |
|---|---|
| Telemetry interval floored at 5 s | Zero busy-loops the radio and hammers every host; the ceiling keeps "live" meaning something. |
| Scrollback capped at 100 000 lines | A memory bound, not a preference — two million lines exhausts a phone. |
| Every numeric read is bounded and every unparseable one falls back | One corrupt settings row must never stop the app starting. |
| An unknown terminal theme falls back to a real one | Otherwise the terminal renders with a scheme that does not exist. |
| A test asserts every default sits inside its own range | A default outside its bounds would be rewritten on first read. |

**Behaviour decisions:**

- **Edits are staged and applied on save.** Applying per keystroke would restart the telemetry
  poller on the way from "1" to "15".
- **Saving writes only the keys this screen owns**, so a bookmark list or a preset toggle is never
  clobbered. A test pins that, listing the foreign keys explicitly.
- **Contradictory combinations warn rather than block** — biometrics with no app lock, keep-alive
  with battery saver, a 5-second poll. Each is legal and probably not intended; refusing outright
  would be the app overruling the user.
- **A dependent switch is disabled, not hidden**, so both the option and its precondition stay
  visible.
- **A stepper disables at its bounds**, because a button that does nothing when tapped is worse than
  one plainly unavailable.
- **`hide_sensitive_info` is pushed to `HostDisplay`** on load and on save; every screen rendering an
  address observes that singleton directly.

**About** does two things: state plainly where data goes, and give a support request enough detail to
be actionable. The privacy text makes specific, checkable claims rather than a vague reassurance. The
diagnostics block carries the version, platform and Dart version and **nothing identifying** — a test
asserts there is no `@` in it — because a user is invited to paste it into a public issue. The
version comes from the build rather than a constant, since a hand-edited version is the fastest way
to make a bug report useless. The source link is **copied rather than launched**: opening a browser
needs a platform integration that has not landed, and a link that silently does nothing is worse
than one you can paste.

**Verified — 1258 tests pass (50 new), `flutter analyze` clean.**

---

### Session 34 — the Shell (terminal) screen — phase 7 is complete

`lib/ui/view_model/shell_session.dart`, `shell_view_model.dart`, `lib/ui/widgets/terminal_surface.dart`,
`terminal_key_bar.dart`, `lib/ui/screens/shell/shell_screen.dart`, plus two pure input modules
(`domain/terminal_soft_input.dart` and additions to `domain/terminal_key_encoder.dart`). Wired into
`app_scaffold.dart`. **`Screen.shell` was the last placeholder; there are none left.**

The engine was already ported and tested — emulator, tmux control parser, key encoder, `openShell`.
This session was the parts between the engine and the glass, and that is where the substance is.

**`ShellSession` — the model, and the four things a terminal must not get wrong:**

| | |
|---|---|
| **Repaints are capped at one frame; the emulator still eats every byte.** | `yes` delivers hundreds of chunks a second. Notifying per chunk pegs the UI thread painting frames nobody can perceive. A test feeds 200 chunks and asserts under 20 publishes *and* that no rows were lost. |
| **The scroll anchor is absolute, not buffer-relative.** | Once the scrollback limit is reached, every new line drops one off the head. A buffer-relative anchor would slide the text out from under the reader at exactly the rate the remote is talking. `trimmedRowCount` is the offset between the two spaces and exists for this. |
| **Resize is newest-wins, not a queue.** | Rotating the device emits a burst of sizes; replaying each one against the remote PTY makes it reflow visibly for geometry nobody saw. A gated fake proves the burst collapses to first + last. |
| **A remote exit and a dropped connection are different endings.** | Both end the read loop identically. `remoteExited` is the transport's judgement and the only honest signal. Calling a drop an "exit" is a lie the user acts on — it is the difference between reconnecting and starting over. |

The scrollback survives either ending. Blanking on disconnect destroys the only record of why.

**Input is one path, deliberately.** The hardware keyboard, the on-screen bar and paste are three
entry points, and a read-only guard on some of them is not a guard — so the check lives in
`ShellSession.write`. `write` returns whether anything was sent, because a key bar that reports
success on a dead session teaches the user to distrust the screen.

**The modifier rules are pure and tested**, because they are invisible when wrong:

- **Ctrl applies to the first code point only** and the rest of the commit survives — a soft keyboard
  can commit several characters at once.
- **Alt is an ESC prefix, not a bit.**
- **Text Ctrl cannot encode is passed through intact** rather than masked into some other byte, which
  in a shell is a different command.
- **Shift upper-cases one character**, never a run — that would rewrite a pasted line.
- **Modifiers are one-shot.** A touch keyboard cannot hold a key; a latch you forget turns the next
  `l` into a screen-clearing `^L`.
- **A paste ignores them entirely** and goes as one contiguous write, newlines normalised to CR. LF
  alone only moves the cursor, leaving the command sitting unsubmitted.
- **A lone newline from the IME is the Enter *key*,** not a newline character. Multi-line commits keep
  every line; an older Kotlin path submitted the first and silently dropped the rest.

**Bounds are re-applied on read.** The scrollback limit is clamped again when a session opens, with
the same range the Settings screen enforces — a corrupt or hand-edited row must not decide how much
memory the terminal takes. A test stores `1` and asserts the floor won.

**The screen states each say what they are**, never a black rectangle that resembles a working shell:
"add a host" and "no host is online" are different problems with different fixes and get different
sentences; the connecting view shows the transport's own phase so a ten-second hang names its step;
a failed connect leaves the Connect button in place. The address goes through `HostDisplay`, since
the terminal is the screen most likely to be on a shared display. Without a transport the button is
disabled and says why (Convention 4).

**Key-bar geometry is fixed across layers** — SYM and FN are always the last two caps. A cap that
moves between layers gets pressed by mistake, and on a terminal a mis-pressed key is a command
nobody meant to run. A test pins SYM's screen position across all three layers.

**Rendering** measures the cell from the shipped font rather than assuming a ratio, so the grid
matches what is painted. Spans of single-width glyphs are laid out once; a span containing a wide
glyph falls back to per-glyph placement, because a fallback font's advance for CJK and emoji is not
reliably two cells and letting it flow shifts the rest of the line.

**Deferred to a second Shell iteration and recorded in §18**: split panes, quick connect, the
host-key approval dialog, tmux persistent sessions, the tunnel manager UI, text selection.

**Verified — 1324 tests pass (66 new), `flutter analyze` clean.**

---

### Session 35 — wiring the SSH transport, and the host-key approval prompt

`lib/data/ssh/secure_host_key_store.dart`, `lib/ui/widgets/host_key_approval_host.dart`, the
`main.dart` provider graph, and a host-binding fix in `SftpViewModel`.

**The headline is not the dialog — it is that the app could not connect at all.** Every view model
was being constructed with `transport: null`. Each one degraded honestly (Convention 4: "monitoring
is unavailable in this build"), which is exactly why it was easy to miss: the screens looked
finished and said something reasonable. `DartSshTransport`, `SshHostKeyTrust` and `SecureHostKeyStore`
are now built once at the root and shared, so the connection pool, the host-key pins and the approval
prompt are consistent across every screen — a per-screen transport would re-prompt for the same host
on each tab.

**The approval prompt is what makes trust-on-first-use possible at all.** `SshHostKeyTrust.check`
fails closed when no handler is registered, so before this the *correct* outcome for a first-contact
host was refusal, with no way to say yes. Decisions:

- **Mounted above every screen, not on the Shell.** The monitor poller, SFTP, the fleet runner and a
  connection test all reach a first-contact host; a Shell-only prompt would leave those failing
  closed with nowhere to answer.
- **One prompt at a time.** Several hosts can be probed at once, and stacked dialogs would let a user
  approve one host's fingerprint while reading another's. Each queued request still times out on the
  trust store's own deadline, so queueing cannot hold a connection open indefinitely.
- **Tapping outside is a refusal**, not an accident to prevent. Making the dialog inescapable pushes
  a user who does not understand it toward the accept button.
- **Reject comes first and Trust is not the emphasised action.** This dialog appears exactly when
  someone is impatient to get connected.
- **The host is deliberately not masked** by `HostDisplay`. The user is authenticating this specific
  machine against its fingerprint; hiding the identity would defeat the decision being asked.
- **A changed key is never offered for approval** — `check` returns `changed` without prompting. A
  prompt there would let a user click through the one warning that matters. A test pins this.
- **The verification instructions are a command, not an exhortation.** `ssh-keygen -lf` against the
  right key file for the presented type, with "on the server's own screen (not over SSH)" — checking
  over the connection being attacked proves nothing.
- **Unmounting answers a pending prompt as "no"**, rather than leaving a completer hanging until its
  timeout.

**The Shell now names a host-key failure for what it is.** A changed key gets its own message
pointing at Tools › Auth & keys, separate from an ordinary auth failure: "wrong password" is a
nuisance, "this host's key changed" is either a rebuilt server or someone standing between you and
it, and blurring the two is how the warning gets ignored.

**`SecureHostKeyStore` namespaces its entries** under `hostkey.` and never calls the platform
`deleteAll()` — that would take the encryption key and every saved credential with it. "Forget every
host key" must mean exactly that. Pins are integrity-critical rather than secret: anyone who can
rewrite one can silently re-pin a host to their own key, and every later connection then succeeds
with no warning at all.

**Deliberate fix — SFTP was bound to one host (§15.6).** `SftpViewModel` held a single
`RemoteFsClient`, but an SFTP client is bound to one set of credentials while the screen switches
hosts. Wiring it as-was would have listed one machine's files under another's name — and deleted
from it. It now takes a resolver keyed on the browsed server. The resolver is asynchronous because
building a client needs the host's decrypted key or profile, and it is called per operation rather
than cached so that editing a host's credentials takes effect immediately.

**Testing note worth keeping.** The approval tests initially hung, then reported a null verdict. The
cause: `AsyncLock` chains onto a `Future` created at construction time, so a trust store built in
`setUp` belongs to the outer zone and its continuations never run under the widget tester's clock.
Building it inside the test body fixes it. Any future test of a lock-bearing collaborator needs the
same treatment.

**Verified — 1337 tests pass (13 new), `flutter analyze` clean. Not yet exercised against a real
host**, which per the standing rule is what "finished" requires.

---

### Session 36 — the app lock, FLAG_SECURE, and link opening

`lib/domain/app_pin.dart`, `lib/ui/view_model/app_lock_controller.dart`,
`lib/ui/widgets/app_lock_gate.dart`, `lib/platform/biometric_auth.dart`,
`lib/platform/screen_security.dart`, `android/.../ScreenSecurityBridge.kt`, plus the PIN setup flow
in Settings and `url_launcher` in About.

**The Settings screen already had these switches; none of them did anything.** "Lock the app",
"Unlock with biometrics" and "Block screenshots" wrote settings rows nothing read. A switch that
reports a protection it is not applying is worse than no switch, so this session made all three real.

**The PIN format is unchanged from the Kotlin** (`pin:v2:<iterations>:<salt>:<hash>:<length>`,
PBKDF2-HMAC-SHA256 at 210 000 rounds) — the same data-compatibility constraint as §7.10 and the
backup envelope. A migration that invalidated everyone's PIN would lock them out of their own hosts.

| Decision | Why |
|---|---|
| A cold start is always locked | Force-stopping an app is the easiest thing in the world to do to a phone you have just picked up; anything else is a way straight past the lock. |
| An enabled lock with no PIN stays **open** | "Locked with no way to unlock" is not a security feature, it is a brick. |
| The stored iteration count is range-checked on read | A record is not trusted to name its own work factor: `1` makes an offline attack free, a billion hangs the unlock screen. |
| Every malformed record verifies as *false* | This is the one screen between someone holding the phone and the host list. It fails closed on nonsense rather than throwing its way open. |
| The throttle counter is persisted | A throttle a force-stop resets is worth nothing against anyone willing to swipe the app away. |
| A failed biometric read costs no attempt | A wet finger is not an intrusion; burning attempts on it pushes the user to the PIN and then locks them out of that too. |
| The device PIN/pattern is accepted alongside biometrics | Refusing it locks out anyone whose sensor is worn out, and it is the same secret the device lock screen already trusts. |
| A zero timeout locks immediately (`>=`, not `>`) | Otherwise the setting asking for the most protection is the only one that never fires. |
| A configuration change does not start the timer | Reusing the already-ported `shouldRecordAppBackground`: rotating the phone is not leaving the app. |
| An old plaintext or v1 PIN is upgraded on successful entry | The only moment the PIN exists in the clear is when the user has just typed it. |
| The app below the lock is `ExcludeSemantics` + `ExcludeFocus` | Hiding it is not enough — a screen reader must not be able to walk the host list either. |
| The screen says there is no recovery | Nothing it could offer would help a user that an attacker holding the phone could not also use. A dead-end "forgot your PIN?" would be worse than the truth. |
| Setting a PIN requires confirming it | There is no recovery, so a typo is permanent. |

**`FLAG_SECURE` has no Flutter-side equivalent** — it is a window flag the platform enforces, and
nothing Dart draws substitutes for it. On a terminal app the task-switcher thumbnail is the real
exposure: captured automatically, persisting after backgrounding, and routinely containing a live
root shell. `ScreenSecurity.isSupported()` asks the platform rather than assuming, so **iOS reports
false** instead of implying a protection it is not applying; the iOS equivalent (covering the window
on `willResignActive`) is tracked, not faked. The binding is a widget rather than a startup call, so
toggling the setting takes effect at once — a protection that needs a restart is one users believe
they have when they do not.

**About now opens the project link** and keeps Copy alongside it, because a launch the platform
refuses must still leave a way to get the address off the screen. A refusal says so rather than
looking like a dead button.

**Testing note.** PBKDF2 costs ~680 ms per call in pure Dart here, so the lock-screen widget tests
deliberately use a legacy plaintext fixture — five real verifications in a throttle test is a
ten-minute `pumpAndSettle` timeout. The hashed path has its own tests. Also: once throttled the
screen runs a one-second ticker, so those tests pump explicitly rather than settling on a timer that
is meant to repeat.

**Verified — 1376 tests pass (39 new), `flutter analyze` clean. Not yet exercised on a device.**

---

### Session 37 — backup files, and the Kotlin app gets its fixes too

Two things: `lib/platform/backup_file_store.dart` wired into the Backup screen, and a **parallel
branch keeping the shipping Kotlin app fixed** (§15.6).

**Backup export and restore now use real files.** Until now the view model produced the text and the
screen showed it in a dialog saying saving "is not wired up in this build yet"; restoring took
pasted text. Both now go through the platform's own document picker.

- **The system picker, not a path the app chooses.** The user decides where a file holding their host
  list and credentials lands, and the app never gains standing access to a directory it was not
  handed.
- **The bytes go straight to the picker, never through a temp file.** A staging copy in the cache
  directory would outlive the save — including when the user cancels it — and a backup can contain
  every credential they have.
- **A size ceiling on read.** The file is read as one string, so a mis-picked video would be an
  out-of-memory crash rather than a message. 64 MB is far above any real backup.
- **Three outcomes, three behaviours.** A save **names where the file went** — a backup the user
  cannot find is one they will assume did not happen. A cancel says *nothing*, because the user
  cancelled and nothing was written. A failure says so rather than looking successful.
- **The passphrase warning is repeated at save time**, when the file becomes a real portable thing
  that can be lost — not only when the passphrase was chosen. An *unencrypted* backup says so just
  as plainly: anyone who opens it can read it.
- **`exportBackup` no longer reports "Backup ready."** It is half the job now, and that message left
  standing after a cancelled save claimed a file that was never written.
- **An unreadable file is named as unreadable**, not as a bad backup: "that file is not a text
  backup" and "that backup is corrupt" send the user to different places.

**§15.6 — the Kotlin app is now being fixed in parallel.** The Flutter release is not imminent and
the Kotlin app still ships, so branch `fix/kotlin-parity-defects` (from `origin/main`) back-ports
the three real defects found while porting:

| | |
|---|---|
| §15.1 `inferLevel` stems | A trailing `\b` disabled every stem, so "connection failure", "disk errors detected" and "task is failing" were all INFO in Monitor → Logs and Fleet broadcast output. |
| §15.5 `commandDangerHits` | `\S*` cannot cross a space, so `dd if=/dev/zero of=/dev/sda` — the canonical disk-destroyer — was the one form Fleet's last-chance warning did not catch. `iptables -t nat -F` likewise. |
| §15.4 Monitor host selection | Matching on id alone left the body rendering a host the selector bar no longer listed, with no way to switch away. |

Back-ported with two new test classes (`LogSeverityStemsTest`, `CommandDangerHitsTest`, 15 tests);
**484 Kotlin unit tests pass**. §15.2 and §15.3 are deliberately not back-ported — both were defects
the port introduced and caught before commit, and neither exists in the Kotlin.

**From here on a §15 entry is not finished until it is fixed on both branches.**

**Verified — Flutter: 1383 tests pass, `flutter analyze` clean. Kotlin: 484 unit tests pass.**

---

### Session 38 — alert notifications

`lib/domain/alert_notification.dart`, `lib/platform/alert_notifier.dart`, wired into
`AlertsViewModel`, with a warning card on the Alerts screen and `POST_NOTIFICATIONS` in the manifest.

**Until now the Alerts screen was a dashboard.** Rules evaluated, incidents were recorded, the list
updated — and none of it reached the user unless they happened to open the app. A rule that only
changes a colour on a screen nobody is looking at has not alerted anybody, which is the whole point
of the feature.

**The wording is pure and tested** (convention 3). A user is being interrupted, possibly while
asleep, so what the banner says is the substance rather than the plumbing:

- **The host leads the title** after the severity, because the first question on seeing an alert is
  always "which machine?".
- **The threshold is in the body, not just the value.** "94%" means nothing without knowing whether
  the line was drawn at 90 or at 50.
- **A disk rule names its mount point.** "Disk Usage at 95%" does not say which disk to go and clear.
- **Temperature is converted to the user's units** so the notification agrees with every screen.
- **The host's real name is used, never the masked one.** "Hide addresses" is for a shared screen; a
  notification you cannot attribute to a machine is useless at 3 a.m.

**The notification id is computed here rather than with `String.hashCode`**, which the Dart VM is
free to seed differently between runs. The id has to survive a restart — it is how a resolved alert's
banner gets cancelled — and an unstable one would leave "CPU at 97%" in the shade for a host that
recovered hours ago.

**Lifecycle decisions:**

| | |
|---|---|
| One incident, one banner | Re-posting on every poll while a condition persists is how a user learns to swipe them all away unread. |
| Resolving **and** dismissing clear the banner | Same reason, from the other end. |
| A failed post never fails the evaluation | Guarded in the view model, not only inside the notifier: the incident is already recorded, and a notification service that throws must not abort the loop and take every *other* rule's result with it. |
| Permission is requested when alerts are switched **on** | The system prompt arrives with the context that explains it, rather than at launch. Switching alerts off asks nothing. |
| A blocked permission is surfaced on the screen | Alerts firing with nothing reaching the shade is the least obvious kind of broken: everything works, and the user finds out about their full disk the next time they happen to open the app. |
| No notifier at all degrades to "no banner" | Convention 4 — the rule still fires and the incident is still recorded. |

**Verified — 1393 tests pass (10 new), `flutter analyze` clean. Not yet exercised on a device.**
