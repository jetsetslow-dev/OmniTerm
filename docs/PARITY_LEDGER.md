# Kotlin → Flutter parity ledger

Started 2026-08-09. Companion to `CLAUDE_HANDOFF_2026-08-09.md` (priority 1: "build a screen/subtab/
action/state ledger directly from Kotlin code and compare it to Flutter").

This file records what was **verified against code**, not what a checklist claims. Every "closed" row
names the evidence.

## Method

Three sweeps, then hand verification of every candidate:

1. Kotlin UI string literals (`app/src/main/java/**/ui/*.kt`) → 878 copy-shaped strings from the
   twelve Compose screen files; 469 absent from `flutter_app/lib` after normalising case, ellipsis,
   and whitespace.
2. `app/src/main/res/values/strings.xml` → 554 comparable entries, 325 absent after the same
   normalisation. (Android's `"…"` quote-wrapping is XML whitespace syntax and must be stripped
   first, or the diff reports ~95% false positives.)

**Both counts are candidate lists, not defect counts.** Hand verification of the largest clusters
showed the majority are rewordings of copy for features Flutter already has — Podman support, DNS
lookup, WHOIS, Wake-on-LAN, traceroute, high-contrast themes, `Acknowledge all`, tar.gz compression
and scrollback all exist under different wording. A string diff finds *candidates*; only reading both
implementations decides whether a feature is missing.

3. **Preference-consumer sweep**: for each `AppPreferences` field, whether anything outside the
   settings screen, the preference definition and generated code reads it. Found defect 12. Beware
   indirection — `terminalScrollbackLimit` looked orphaned but is read through
   `PreferenceLimits.terminalScrollback`, so every hit needs checking by hand.

4. **Settings-key diff**: the keys Kotlin reads versus every key Flutter reads or writes. A key
   Flutter never touches is a setting a migrating user silently loses. Found defect 13.

5. **Unreachable-code sweep** (added after defect 5): public declarations in `lib/` that nothing
   outside their own file references. This is the highest-yield probe so far — defects 5, 6 and 7
   were all found this way, and all three were *tested* code the app could not reach. A green suite
   is not evidence a feature is wired up. The raw list is noisy (class methods look unreferenced
   because they are called through instances), so it needs reading, not trusting.

## Confirmed defects

| # | Area | Defect | Status |
|---|---|---|---|
| 1 | Auth Keys | **SSH keypair generation missing entirely.** Kotlin offers Generate / Import / Profile from one "+"; Flutter offered only Import and Profile. No generation existed anywhere in `flutter_app/lib` (`grep -rn "Generat"` matched only unrelated operation-generation counters). Kotlin also shows the generated material once with copy buttons and a prefilled `authorized_keys` install command — none of which existed. | **Closed** — see below |
| 2 | Compose Builder | Kotlin has a dedicated "Podman modifiers" card (`testTag("podman-modifiers")`) whose **"Rootless keep-ID mapping" switch sets `usernsMode = "keep-id"` on every service at once** and clears it the same way. Flutter had no such card and no bulk toggle: the user had to type `keep-id` into a per-service free-text `userns_mode` field for each service. Flutter also dropped the card's explanatory text, the pod-name placeholder (`pod_<project>`) and its supporting text. | **Closed** — see below |
| 3 | Servers | Kotlin warns on a **duplicate IP address** when saving a host (`AppUi.kt:2783`, dialog with "Save anyway" / "Review" naming the clashing host). `server_form_sheet.dart` had no such check. | **Closed** — see below |
| 4 | Walkthrough test | `About reports a real version` settled the frame pipeline but the version arrives on a **platform channel**, whose future completes outside it. It passed alone and failed when run after the surface sweep — an order-dependent flake, not a product defect. | **Closed** — see below |
| 5 | SFTP transfers | **Destination conflict detection is half-ported and unreachable.** `TransferConflict`/`ConflictVerdict` and `parseTransferConflicts` exist and are unit-tested, but `compareForConflicts` was never ported, so nothing produced the parser's input, and no UI referenced any of it. Worse, the parser read field 0 as a **filename** while Kotlin emits a **source index** — its tests encoded a format the real producer never emits. | **Closed** — see below |
| 6 | Monitor | **The "7-DAY HISTORY" card is missing.** The telemetry poller writes `MetricHistory` rows, the DAO exposes three queries over them, the pruning setting trims them, and `buildHourlyMetricSeries` condenses them — fully implemented and unit-tested. Nothing in `lib/` called it, so Kotlin's three hourly-average charts (CPU, RAM, Temperature) had no Flutter counterpart. | **Closed** — see below |
| 7 | Monitor | **Overview ignored the Measurement system setting**, printing `Temp: 42°C` unconditionally where Kotlin calls `formatTemperature(it, measurementSystem)`. A user on imperial was shown Celsius. | **Closed** — see below |
| 8 | App lock (**security**) | **The background lock timer used the wall clock**, which Kotlin explicitly forbids at `AppViewModel.kt:833`: it uses `SystemClock.elapsedRealtime()` and documents that `currentTimeMillis` lets the timeout "be bypassed by moving the system clock backwards". Flutter's `AppLockController` used `DateTime.now().millisecondsSinceEpoch`, so winding the device clock back left the app **unlocked** after any period away. | **Closed** — see below |
| 9 | Shell / tmux control mode | **Typing did nothing.** In `tmux -CC` the channel is a command channel, not a PTY: tmux reads stdin as command lines. `ShellSession.write` sent raw bytes, so keystrokes were parsed as (invalid) tmux commands and never reached the pane. `TmuxControlCommands` — `sendKeysHex`, `refreshClientSize`, `capturePane`, `paneOutputState` — was fully written and unit-tested, and the entire file was unreferenced. Resize was equally unreported, so panes kept the geometry they attached at. | **Closed** — see below |
| 10 | SFTP transfers (**data safety**) | **Pasting a folder into its own subtree recursed without bound.** `_copyRemoteEntry` creates the destination, then lists the source — which now contains what it just created — and recurses into it forever, filling the remote disk and hanging the transfer. `isWithin` existed in `domain/remote_path.dart`, documented as being for exactly this ("stop a move that would drag a directory into itself"), and was never called. | **Closed** — see below |
| 11 | SFTP editor (**data safety**) | **A binary opened silently in the text editor, and saving corrupted it.** `looksBinary` existed in `domain/file_edit.dart`, documented as a warning signal for exactly this, and no route into the editor consulted it. The real hazard is worse than a NUL byte: the SFTP client reads with `utf8.decode(..., allowMalformed: true)`, so invalid bytes are already U+FFFD before the editor sees them — invisible on screen, and saving writes those three bytes over the original. | **Closed** — see below |
| 12 | Alerts | **The "Alert history limit" setting did nothing.** The preference was stored and shown, and `pruneAlertHistoryForServer` / `pruneAlertHistoryPerServer` both existed on the repository with the SQL already written — nothing called either. Kotlin applies the cap at three points (`AppViewModel.kt:10845` on archive, `:10536` on save, `:11804` after restore); Flutter applied it at none, so the table grew for the life of the install. | **Closed** — see below |
| 13 | SFTP | **The sort order was never persisted.** Kotlin writes `sftp_sort` on every change (`AppViewModel.kt:1410`) and reads it at startup (`:2166`); Flutter held `_sortOption` in memory only, so a browser asked to show newest-first was back on Name A-Z after every restart. The stored value also needed case-insensitive parsing: Kotlin's enum spells it `SizeDesc`, Dart's `.name` is `sizeDesc`. | **Closed** — see below |
| 14 | SFTP transfers | **The recursive-folder-copy opt-in was asked on every single paste and never remembered.** Kotlin treats it as a standing preference — a checkbox in the clipboard bar, persisted under `cross_paste_recurse` (`AppViewModel.kt:1228` / `:2172`) — so a user who always wants folder contents says so once. Flutter showed a modal every time. | **Closed** — see below |
| 15 | Backup | **"Last backup" was never recorded or shown.** Kotlin keeps `lastBackupExportTime` and renders `Last backup: Never` or the formatted date on the Backup screen (`ToolsScreen.kt:2691`). Flutter recorded nothing, so the screen could not distinguish a user who had never taken a backup from one who took one a year ago. | **Closed** — see below |
| 16 | Backup | **The export selection was never remembered.** Kotlin persists it under `backup_export_selection` (`AppViewModel.kt:2310`), so a user who excludes crash logs or alert history does it once. Flutter reset to "everything" on every visit to the screen. | **Closed** — see below |
| 17 | Reviews | **The in-app review nudge was not ported.** Kotlin counts successful SSH sessions (`ssh_success_count`), asks once at three (`review_prompt_shown`), and reaches the store through `flavorRequestInAppReview` — a no-op in its open-source flavor. Flutter had none of it. | **Policy closed, store call seamed** — see below |
| 18 | First run | `first_run_complete` / `isFirstRun` / `hasConnectedOnce` are **dead in Kotlin itself** — `completeFirstRun()` is never called, so the key can never even be written, and no consumer reads any of the three. | **Will not port** — see below |
| 19 | Tools hub / Auth Keys (**both**) | **Casing was inconsistent across the two apps, and inconsistent inside Kotlin itself** — `Crash history` and `Device & diagnostics` in sentence case beside `Alerts & Rules`, `Network Tools`, `OmniTerm Utilities`, `Trusted Host Keys` in Title Case. No test asserted any label on either side. | **Closed in both** — see below |
| 20 | Tools / AppViewModel (**Kotlin**) | **Dead code in Kotlin**: `CronJobsToolView` (declared, never called), and the `completeFirstRun()` / `isFirstRun` / `hasConnectedOnce` / `first_run_complete` cluster (the function is never called, so the setting can never be written and the two fields are never read). | **Removed from Kotlin** — see below |
| 21 | App exit (**data safety**) | **A single back press at the root killed the app and every live SSH session, with no warning.** Kotlin guards it twice (`AppUi.kt:482`): a first press only shows "Press back again to exit", and a second within 2 s either exits or — when something is still connected — asks first. Flutter's `PopScope` set `canPop` true as soon as the in-app history emptied, so Android popped the activity before any of the app's own logic ran. | **Closed** — see below |
| 22 | App lock / biometrics | **Returning to a locked app left a bare PIN screen.** Biometrics were offered only from `initState`. The lock screen is never rebuilt while the app stays locked, so once the platform cancelled the prompt — which it does whenever the app is backgrounded with the prompt up — there was no way back to biometrics except the button. Kotlin re-prompts on every `ON_RESUME` and documents exactly this (`ui/AppUi.kt:718`-`724`). | **Closed** — see below |
| 23 | Monitor (**security**) | **Privileged actions used a stored sudo password with no re-authentication.** Kotlin stages reboot and service start/stop/restart/enable/disable behind `withSudoAuth` (`AppViewModel.kt:2521`) and demands a PIN or biometric before the saved password is used. Flutter ran both behind a plain "are you sure?", so on a host with a saved sudo password anyone holding the unlocked phone could reboot the server or stop `sshd`. | **Closed** — see below |
| 24 | Shell / persistent sessions | **A persistent host without tmux connected silently as an ordinary shell.** Flutter's bootstrap commands self-guard with `command -v tmux`, so nothing failed and nothing was said — the user believed a dropped link would leave their work running, and it would not. Kotlin probes first and offers Install tmux / Connect non-resumable / Cancel (`ui/AppUi.kt:617`, `ui/AppViewModel.kt:5911`). | **Closed** — see below |
| 25 | Servers | **The "appears offline" warning fired on hosts nothing had checked.** A host's stored status is `offline` from creation, and Flutter gated the warning on status alone — so connecting to a host you had just added always warned. Kotlin only warns about a host it has probed *this run* (`ui/AppViewModel.kt:4496`). | **Closed** — see below |
| 26 | Monitor | **Remote command output was unreadable and uncopyable.** Kotlin puts the output of all fifteen streaming actions in one scrollable monospace box with a Copy button (`ActionStreamDialog`, `ui/AppUi.kt:263`). Flutter's Infra had an equivalent card; Monitor rendered the same kind of output as a bare proportional-font `Text` with no copy button and no height bound — a `systemctl` failure pushed the service list off the screen and the error could not be pasted anywhere. | **Closed** — see below |
| 27 | Monitor / Infra | **The host picker showed a nickname and nothing else.** Kotlin's `ServerSelectorBar` (`ui/AppUi.kt:83`) carries a status dot, the name, and `user@host · latency`. Flutter had grown a separate `DropdownButton` per screen — Monitor showed the bare name at 14sp default font, Infra `Containers · name` at 13sp mono — and **none of them said which machine the name referred to, or whether it was still answering**. | **Closed** — see below |
| 28 | SFTP transfers | **No aggregate progress: no overall bar, speed or ETA.** Kotlin's `TransferAggregateBar` (`ui/SftpScreen.kt:2886`) sums the running transfers and shows `X of Y · 18.4 MB/s · ETA 2m`. Flutter drew a bar per file and nothing above them — which answers "is this file moving?" but never "how long until my folder is across". | **Closed** — see below |
| 29 | SFTP sudo mode (**security**) | **Two defects.** (a) The warning dialog said "Browsing, renaming and deleting are unchanged and still run as you" — but with sudo on the view model runs `mkdir`, `mv` and **`rm -rf -- <paths>`** as root. (b) Kotlin authenticates before switching sudo on (`ui/SftpScreen.kt:1964`); Flutter only confirmed. | **Closed** — see below |
| 30 | SFTP editor (**security**) | **The editor never said a save would be written as root.** With sudo mode on, `saveText` writes through `_sudoWrite`, but the header read `Editing` and the button read `Save`. Kotlin puts `· sudo` in the subtitle in red and labels the button `Save as root` (`ui/SftpScreen.kt:3114`, `:3121`). | **Closed** — see below |
| 31 | SFTP transfers | **No way to download a file to the device.** `SftpViewModel.download` and `upload` existed with **no caller anywhere in the UI**, so the SFTP screen could not move a file on or off a host and the Transfers tab could only show transfers some other flow had started. | **Closed** — see below |
| 32 | SFTP bookmarks | **The Bookmarks tab only ever showed the host being browsed, and could not add, edit or clone.** With no host online it rendered "Bookmarks are saved per host — connect one first" and nothing else, so the jump list was unavailable in exactly the state it is most wanted. Kotlin's tab spans every host **and every share** (`ui/AppViewModel.kt:9039`, `ui/SftpScreen.kt:3152`). Shares could not be bookmarked at all, though `backup_payload.dart:439` already remaps a `share_bookmarks_` key nothing wrote. | **Closed** — see below |
| 33 | SFTP browser | **The browser could not be navigated by path.** Flutter had breadcrumbs and nothing else: no address box to type a destination into, and no home button — so a folder could only be reached by walking to it one listing at a time. `openPath('')` already resolved the remote home and **nothing in the UI ever called it**. Kotlin's path box is tappable, editable and prefilled (`ui/SftpScreen.kt:1806`), with `Go to home folder` beside it (`:1884`). | **Closed** — see below |
| 34 | SFTP search (**security-adjacent**) | **Host search ignored sudo mode, and reported the refusal as "nothing found".** Every other exec on the screen wraps in `sudoShWrap` when sudo is on; `searchHost` did not. Because `remoteSearchCommand` sends `find`'s errors to `/dev/null`, searching a tree the login cannot read returned an empty result rather than a permission error — so turning sudo on to search `/etc` produced a confident, wrong "nothing matched". Kotlin elevates (`ui/AppViewModel.kt:8962`) but **mis-reports its own hits**, covered below. | **Closed** — see below |
| 35 | SFTP transfers | **No batch download.** Kotlin's selection toolbar has `Download selected files` — pick one folder, every selected file lands in it (`ui/SftpScreen.kt:1747`, `ui/AppViewModel.kt:9717`). Flutter downloaded one entry at a time from the row menu, so twelve files meant twelve save dialogs. | **Closed** — see below |
| 36 | Network shares | **No way to find a share — only to type one in.** Kotlin sweeps a subnet for SMB/FTP/SFTP/NFS/WebDAV and offers each hit as a share to save (`ui/AppViewModel.kt:7372`, protocol selection at `:1177`, persisted under `share_scan_protocols`). Flutter's `SharesViewModel` had add/edit/delete/test and **no scanner at all**, so a NAS had to already be known by address before it could be saved. | **Closed** — see below |
| 37 | Shell sessions | **A session's age was not recorded, let alone shown.** Kotlin labels each session "Started 2h 05m ago" in the session dropdown (`ui/ShellScreen.kt:848`, `formatSessionAge` at `ui/OmniComponents.kt:504`). Flutter's `ShellSession` had **no start time field at all**, so the age was not merely unshown — it was unknowable. | **Closed** — see below |
| 38 | Shell terminal | **Read-only mode kept the full key bar, where nearly every key was inert.** `sendKey` accepts only page up and page down while read-only and silently drops the rest, so two dozen caps looked live and did nothing. Kotlin replaces the bar with `TerminalReadOnlyNavigationBar` — a label and exactly two keys (`ui/ShellScreen.kt:2657`, gated at `:632`). | **Closed** — see below |
| 39 | Monitor / cron (**data integrity**) | **Editing a cron line's schedule silently rewrote its command.** `parseCrontab` split the whole line on whitespace and rejoined the remainder with single spaces, so `--name "My  Backup"` became `--name "My Backup"` — a different argument. The schedule dialog seeds its command field from that value, so changing only the *minute* changed what the job does. Kotlin gets this right for free via `split(Regex("\\s+"), limit = 6)` (`ui/MonitorScreen.kt:422`). | **Closed** — see below |
| 40 | SFTP / shares | **No image preview, and tapping an image made things worse.** Kotlin opens a zoomable in-app viewer (`ui/ImagePreview.kt`, `ui/AppViewModel.kt:8105`). Flutter had none, and the row tap fell through to the *text* editor — which decodes the bytes as UTF-8 and offers to save them back, the one action guaranteed to corrupt the file. | **Closed** — see below |
| 41 | App lock (**security**) | **The PIN lockout did not survive a force-stop.** `load()` restored `pin_failed_attempts` but never `pin_locked_until`, and nothing ever wrote it — so killing the app cleared the wait. The throttle then rate-limited nothing: restart, try one PIN, restart, try another. Kotlin persists and restores it (`ui/AppViewModel.kt:2124`, `:3059`). | **Closed** — see below |
| 42 | Tools / AppViewModel (**Kotlin**) | **More dead code in Kotlin**: `saveThemeOption` writes `theme_dark`, has **no caller**, and `theme_dark` is **never read** — the real preference is `dark_mode`. | **Removed from Kotlin** — see below |
| 43 | Settings → terminal | **Changing the scrollback limit did nothing to running sessions.** Flutter read `terminal_scrollback_limit` only when *building* a session, and `TerminalEmulator.setScrollbackLimit` existed with **no caller**. Kotlin pushes the new limit into every active emulator immediately (`ui/AppViewModel.kt:1900`). | **Closed** — see below |
| 44 | Settings → accessibility (**a11y**) | **High contrast was toggleable, persisted, backed up — and inert.** `OmniThemeMode.highContrastDark` / `.highContrastLight` are fully defined schemes that `main.dart` **never selected**: the mode chain chose between light, dark and AMOLED only, and `prefs.accessibility` was consulted nowhere. Kotlin maps it to `highContrast`, above AMOLED in the chain (`ui/theme/Theme.kt:166`). | **Closed** — see below |
| 45 | Surface sweep (**test coverage**) | **The device sweep never painted the two high-contrast schemes.** It iterated `darkMode`/`amoled` only — three variants — so `highContrastDark` and `highContrastLight` had never been rendered against a single screen. That is why the sweep did not catch defect 44, and it left two complete colour schemes unexercised. | **Closed** — see below |
| 46 | Charts (**a11y**) | **Every screen with a chart clipped its axis at large text.** `MetricLineChart` gave its axis labels a fixed 56px height and a fixed 28px gutter; at 200% text `100` no longer fitted the gutter, wrapped onto three lines, and overflowed by **118px** on Fleet → Dashboard and Monitor → Overview in both orientations. | **Closed** — see below |
| 47 | Large text, several screens | **Seven surfaces overflowed at 200% text.** All closed across six turns — see defects 46, 49, 50 and 48. | **Closed** |
| 51 | Backup restore (**entitlement**) | **A restore walked straight past the free-tier host limit.** The cap is enforced when adding a host by hand, and the restore dialog selected **every** host in the file with no cap at all — so a free Play build could restore a ten-host backup and keep ten. Kotlin caps the same picker (`ui/ToolsScreen.kt:2970`). | **Closed** — see below |
| 52 | Host limit (**entitlement**) | **An install already over the free-tier limit stayed over it forever.** Flutter blocked *adding* a host past the cap and had nothing for hosts already saved — which a restore on an older build, a lapsed unlock or a refund all produce. Kotlin forces a "choose which to keep" reconciliation (`ui/AppViewModel.kt:966`, dialog at `ui/AppUi.kt:1169`). | **Closed** — see below |
| 53 | Monitor → Processes | **A first load looked like a host with nothing running.** Flutter showed a 2px progress bar above an empty list whether it was fetching for the first time or refreshing rows already on screen; Kotlin splits the two (`ui/MonitorScreen.kt`, `processesLoading && isEmpty`). There was also no empty state at all — a failed parse rendered as a blank pane. | **Closed** — see below |
| 54 | Infra | **A first probe read as "this host has no containers".** Flutter showed a 2px bar over the empty state whether it was asking for the first time or refreshing; Kotlin shows a centred spinner until the first result lands (`ui/InfraScreen.kt:87`). | **Closed** — see below |
| 55 | Settings (**iOS**) | **Two settings that cannot work on iOS were offered as live toggles.** "Keep polling in the background" needs a foreground service iOS has no equivalent of, and "Block screenshots" needs `FLAG_SECURE`, which `ScreenSecurityBridge.swift` already documents as having no iOS counterpart. Both persisted, looked live, and did nothing. | **Closed** — see below |
| 56 | Backup restore (**data integrity**) | **The document version was written into every backup and never read back.** A file from a newer build would be inspected and restored as though it had this build's shape — and `decode` already carries a v1→v2 migration, so shapes here really do change. | **Closed** — see below |
| 57 | Device coverage (**first install**) | **Nothing exercised a genuinely empty install.** Both device suites seeded a host before walking the app, so every screen was only ever rendered with data — and the two empty-state defects (53, 54) were both on paths that only appear when there is none. | **Closed** — see below |
| 58 | Startup (**crash loop**) | **A crash during startup left the app unopenable.** `main()` was unguarded, so an exception opening the database killed the app before any UI existed — and the next launch did the same. Kotlin catches it, shows a recovery screen, and refuses to relaunch into a recent startup crash (`MainActivity.kt:55`, `:342`). | **Closed** — see below |
| 59 | Launcher shortcuts | **A shortcut into a host failed on a cold start, and said nothing when its target was gone.** `connect_server` and `open_split` resolved the host from the *in-memory* list, which has not emitted yet on a cold start, so a working shortcut looked like a deleted host. Kotlin reads the row from the repository for exactly that reason and shows a toast when it is really missing (`ui/AppViewModel.kt:4533`, `:4537`). | **Closed** — see below |
| 60 | Home widget | **A widget that could not read its data told the user they had no hosts.** The receiver's `runCatching { … }.getOrElse { JSONArray() }` turned any unreadable payload into an empty one, and empty renders as "Open OmniTerm to add a host". Kotlin has three layouts — rows, empty, and `omniterm_widget_error`; Flutter had two. | **Closed** — see below |
| 61 | Permission prompt (**consent**) | **The local-network prompt explained the upside and not the cost.** Kotlin's explanation ends "If you choose Not now, internet hosts remain available but nearby-device features may not work" (`strings.xml:33`); the Flutter port dropped that sentence, leaving "Not now" looking free on a prompt the user cannot easily get back to. | **Closed** — see below |
| 66 | File editor Back (**data loss**) | **Back closed the remote file editor without the discard prompt its own close button enforces.** A modal sheet is popped by the system without consulting anything inside it, so the guarded path was the ✕ and the unguarded one was Back. Kotlin routes Back through the same check (`CodeEditor` installs `BackHandler { onClose() }`; the SFTP host passes `attemptDismiss`, `ui/SftpScreen.kt:3112`). A second defect in the same guard: it required edit mode as well as a changed buffer, so disarming the pencil with unsaved edits skipped the prompt. | **Closed** — back axis complete |
| 65 | Compose Builder Back (**navigation**) | **Back on the Builder tab discarded an edited stack with no prompt, and could not leave the tab.** Kotlin confirms first (`ui/ComposeBuilder.kt:1236`) and then returns to Stacks, because clearing alone leaves the user on a tab that immediately rebuilds an empty draft — a press that appears to do nothing. Flutter had neither half. | **Closed** — completes the back axis for the builder |
| 64 | Compose Builder (**data loss**) | **An unsaved compose draft was destroyed by a glance at another tab.** The draft lived in `BuilderTab`'s `State`, and `InfraScreen` builds that tab only while it is selected — so switching to Stacks, or leaving Infra, discarded it silently with nothing to undo. Kotlin holds the equivalent on the view model (`AppViewModel.activeComposeDraft`) with a comment saying it exists "so edits survive a tab switch". | **Closed** — see below |
| 63 | Android Back (**navigation**) | **The whole layer of screen-level Back handling was never ported.** Kotlin installs five `BackHandler`s — image preview, code editor, the SFTP browser, the share browser and the compose builder — and *disables* its app-level one while any overlay is up (`ui/AppUi.kt:482`). Flutter shipped only the root `PopScope`, so Back from three folders deep left the SFTP screen entirely instead of walking up one, and Back with an image preview open navigated away while leaving the preview loaded underneath it. | **Closed for SFTP and the preview** — builder and editor noted below |
| 62 | Settings save (**security**) | **Saving Settings never re-authenticated, so the app lock could be turned off without knowing the PIN.** Kotlin gates the whole save behind the PIN whenever one is stored (`ui/ToolsScreen.kt:3902`). Flutter applied the draft directly — and disabling the lock *clears the stored PIN outright*, so a briefly-unlocked phone was enough to remove it, along with screenshot blocking and sensitive-info masking. | **Closed** — see below |

### 1 — SSH keypair generation (closed)

Ported from `generateSshKey` in `ui/AppViewModel.kt:3372` and its two dialogs in `ToolsScreen.kt`
(`:2290` generate, `:2556` result).

- `lib/domain/ssh_keygen.dart` — RSA 4096 via PointyCastle, seeded from `Random.secure()` through
  Fortuna. Encodes a PKCS#1 PEM private key and an `ssh-rsa` OpenSSH public line by hand, because
  JSch's `writePrivateKey`/`writePublicKey` have no Dart equivalent. Same refusals as Kotlin,
  including the verbatim "not supported by the bundled SSH library" message for non-RSA types.
- `auth_keys_view_model.dart` — `generateKey()` with a `keygenRunning` guard, running on a spawned
  isolate via `compute`. A `SshKeyGenerator` seam lets tests shrink the modulus.
- `auth_keys_screen.dart` — third FAB, the generate dialog (alias + spinner button), and the
  result dialog showing private key, public key and the `authorized_keys` install command, each
  copyable. It is the only place the private key is ever displayed.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,897 passed** (was 1,886; +8 keygen, +3 screen) |
| `test/ssh_keygen_test.dart` | 8 passed, including **agreement with real `/usr/bin/ssh-keygen`**: it re-derives the same public line from our PEM (`-y`) and prints our fingerprint (`-lf`) |
| `integration_test/key_generate_test.dart`, API 35 `emulator-5554` | 2 passed — a real 4096-bit key generated on device in ~10 s, shown, stored, deleted |
| Negative control (AGENTS.md "seen it fail") | with `rsaKeyBits` forced to 1024 the device guard failed for the expected reason: `Expected: a value greater than <700> / Actual: <204>` |
| `app_surface_stress_test.dart` + `app_walkthrough_test.dart`, API 35 | 7 passed after the change |

Device commands used:

```bash
cd /home/sbvino/Omniterm/flutter_app
/home/sbvino/sdks/flutter/bin/flutter test \
  integration_test/key_generate_test.dart \
  -d emulator-5554 --dart-define=OMNITERM_PLAY_STORE=true
```

### 2 — Podman modifiers card (closed)

Ported from `PodmanModifiersEditor` in `ui/ComposeBuilder.kt:1729`, rendered where Kotlin renders it
(`:1675`, above the services list, gated on `runtime == "podman"`) rather than inline in the stack
settings where Flutter had put the pod switch.

- `compose_builder_logic.dart` — `podmanKeepIdEnabled()` and `setPodmanKeepId()`. The logic lives
  here, not in the widget, matching how this codebase already separates the two. Commented-out
  services are excluded from the reading; clearing removes only the value the switch set, so a
  hand-written `userns_mode` survives.
- `compose_builder.dart` — `_PodmanModifiersCard` with the purple accent, the explanatory line, the
  bulk keep-id switch, the pod switch with its `x-podman.in_pod` subtitle, and the pod-name field
  carrying the `pod_<project>` placeholder and supporting text.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,903 passed** (+6 over the previous 1,897) |
| `test/compose_builder_logic_test.dart` | 11 passed, including that the mapping reaches the rendered YAML — a switch that does not change the deployed file would be worthless |
| `app_surface_stress_test.dart`, API 35 `emulator-5554` | passed — all routes/subtabs/themes/orientations with the new card in place |

### 3 — Duplicate address warning (closed)

Ported from `confirmDuplicateHost` in `ui/AppUi.kt:2782` and its trigger at `:2765`.

`server_form_sheet.dart` now checks `existingServers` (already passed in) for a case-insensitive,
trimmed address match before saving, and shows the Kotlin dialog — "Duplicate IP address", the body
naming the clashing host through `HostDisplay` so it obeys Hide addresses, and Review / Save anyway.
Matches Kotlin's scope: add and duplicate warn, edit does not, so editing a host never warns about
itself.

It is a warning rather than a validation error on purpose: two entries for one machine is a
legitimate setup (a root login and an unprivileged one), so the collision is reported and the
decision left with the user.

### 4 — Order-dependent walkthrough flake (closed)

`pumpAndSettle` proves only that no animation is running; it cannot wait for a platform-channel
future. The About version assertion therefore passed in isolation and failed when the device was
still busy after the 60-second surface sweep. Replaced with a bounded 10-second wait on the value
itself, which is the synchronisation the assertion actually needs. AGENTS.md is explicit that an
order- or load-dependent failure is a test defect to fix at the synchronisation boundary, not to
rerun until green.

Evidence for 3 and 4:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,909 passed** (+6 over 1,903) |
| `test/server_form_sheet_test.dart` | 20 passed, covering warn / Review / Save anyway / case- and space-insensitive matching / distinct address / editing-does-not-self-warn |
| `app_surface_stress_test.dart` + `app_walkthrough_test.dart`, one invocation, API 35 | **7 passed** — the combination that previously failed |

### 5 — SFTP destination conflict scan (closed)

The most serious finding so far, because the tests were **green over unreachable code**.

What Kotlin does (`RemoteParsers.kt:868`, `AppViewModel.sftpBeginPaste:9417`): before pasting, it
compares each source against the same basename in the destination, hashing both sides when the sizes
match, and opens a per-item resolution dialog (Overwrite / Skip / Keep both, with Apply to all) only
when something really clashes. It says so explicitly when the host has no digest tool, so an
unverifiable pair is never presented as a match.

What Flutter did: `pasteClipboard` calls `uniqueName(...)` unconditionally, so **every** paste
auto-renames. There is no way to overwrite a file by copy/paste at all — updating a config file in
place is impossible, and the user is never told a clash occurred.

Done this iteration:

- `remote_commands.dart` — `compareForConflicts` and `conflictScanOk`, ported faithfully including
  the index-keyed wire format and the digest-tool probe.
- `remote_parsers.dart` — `parseTransferConflicts` now takes the source list and resolves index →
  basename, dropping rows whose index addresses nothing rather than guessing. Previously it read the
  index *as* the name, so wiring the real command in would have labelled every conflict `0`, `1`, `2`.
- `test/remote_parsers_test.dart` — rewritten onto the real wire format it had never been tested
  against.

Then completed in the following iteration:

- `sftp_view_model.dart` — `beginPaste` scans before transferring, `confirmPasteConflicts` /
  `cancelPasteConflicts` / `setPasteConflictAction` / `setAllPasteConflictActions`, and
  `pasteClipboard` now takes per-name resolutions. Overwrite deletes the existing entry first, which
  makes it behave identically for a same-endpoint rename and a cross-endpoint stream, and for every
  protocol behind `RemoteFsClient`.
- `sftp_tabs.dart` — `_PasteConflictDialog`, carrying Kotlin's per-verdict wording, the Apply-to-all
  row, and the amber "no checksum tool" warning.

Two deliberate departures from Kotlin, both widening coverage rather than narrowing it:

- **Collisions are detected from the listing already on screen**, so they are raised for *every*
  endpoint — SMB, FTP and WebDAV included, where Kotlin has no shell and therefore no scan at all.
  The content verdict is added only when the destination is an SSH host; elsewhere it stays
  `unknown`, which the dialog reports honestly rather than guessing a match.
- **Staleness is checked by clipboard identity** rather than Kotlin's generation counter, because
  Flutter's clipboard is a single immutable object — restaging replaces it, so `identical()` is a
  precise test.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,931 passed** (+22 over 1,909 across both iterations) |
| `test/transfer_conflict_scan_test.dart` | 10 passed — the generated script is executed in a real `/bin/sh` against temp-dir fixtures, covering identical/different/dir, same-size-different-bytes, and filenames containing a tab, a quote and spaces |
| `test/sftp_view_model_test.dart` | 67 passed, 11 of them new: verdict reporting, truncated-scan cancellation, shell-less unverified path, overwrite/skip/keep-both, apply-to-all, cancel, same-folder paste, and stale-restage |
| Negative control (scan) | re-introducing the over-escaped `$OT_V` made every verdict degrade to `unknown` |
| Negative control (resolutions) | forcing the old unconditional `uniqueName` failed the overwrite guard (`deleted` was empty) and the skip guard (`Copied 1 item` instead of `skipped 1`) |
| Surface sweep + walkthrough, one invocation, API 35 | 7 passed |

### 6 — Retained 7-day history card (closed)

Ported from the `7-DAY HISTORY` block in `ui/MonitorScreen.kt:768`.

The same shape as defect 5, and found by deliberately looking for it: a sweep for public
declarations in `lib/` that nothing outside their own file references. `buildHourlyMetricSeries` was
written, documented and unit-tested, and no caller existed. The rows it condenses were being written
by the telemetry poller and trimmed by the Metrics Data Pruning setting the whole time — the app has
been recording seven days of history and never showing it.

- `monitor_view_model.dart` — `hourlySeries` plus `loadHourlySeries()`, reading
  `getMetricsSince(server.id, now - 7d)`. Re-reads when the monitored host changes and drops the
  result if the host changed while the query was in flight, so one host's history can never be drawn
  under another's name.
- `monitor_tabs.dart` — `_RetainedHistoryCard` with the three hourly-average charts. Absent rather
  than empty below two points, and the temperature chart is omitted outright when no sensor reported
  rather than drawn flat at zero. Its axis ceiling is the larger of 100° and the hottest reading, so
  a thermally runaway host is not clipped to look merely warm.

### 7 — Overview temperature ignored the unit setting (closed)

`monitor_tabs.dart` printed `Temp: ${m.cpuTempC!.round()}°C`. Kotlin (`MonitorScreen.kt:626`) calls
`formatTemperature(it, measurementSystem)`. This is *why* `formatTemperature` and
`displayTemperatureToCelsius` showed up as unreferenced — the conversion existed and the one screen
that most needed it bypassed it. Servers and Alerts were already converting correctly, so the app
disagreed with itself about the same host's temperature.

Evidence for 6 and 7:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,937 passed** (+6 over 1,931) |
| `test/monitor_view_model_test.dart` | 32 passed, 6 new: hourly bucketing is an average not the last reading, no-sensor yields no temperature series, recorded temperatures do reach it, rows outside the window are excluded, and switching hosts re-reads |
| Negative control | swapping `getMetricsSince` for `getMetricsForServer` failed the window guard, so it does discriminate |
| Surface sweep + walkthrough, one invocation, API 35 | 7 passed |

**Not covered:** the card is proven at view-model level and renders in the surface sweep, but the
sweep runs against a fixture host with no stored telemetry, so the charts themselves have not been
seen drawing real data on a device. That needs the fleet.

### 8 — App lock background timer used the wall clock (closed)

**A security defect, found by the same unreachable-code sweep.** `AppLockTimeoutTracker` in
`domain/app_lock_timeout_policy.dart` was written, documented ("callers supply monotonic time so
wall-clock changes cannot shorten or extend the configured interval") and unit-tested — and
`AppLockController` never used it, implementing the arithmetic inline against
`DateTime.now().millisecondsSinceEpoch` instead.

Kotlin is unambiguous at `AppViewModel.kt:833`. It uses `SystemClock.elapsedRealtime()`
(CLOCK_BOOTTIME) and names both failure modes it is avoiding:

- `CLOCK_MONOTONIC` stops while the device is suspended, so the countdown freezes with the screen
  off and the app never re-locks — "the exact case users hit most".
- the wall clock can be wound backwards, so "a user-set timeout cannot be bypassed by moving the
  system clock backwards either".

Dart exposes neither `elapsedRealtime` nor a suspend-aware monotonic clock. `onForegrounded` now
takes the **larger** of the two elapsed times, which fails closed in both directions: the wall clock
covers deep sleep, and a `Stopwatch` covers the wall clock being tampered with. Moving the clock
*forward* can only lock sooner, which is the safe direction.

The PIN throttle deliberately still uses the wall clock, matching Kotlin: `_lockedUntilMs` is
persisted and has to survive a reboot, which `elapsedRealtime` does not.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,941 passed** (+4 over 1,937) |
| `test/app_lock_test.dart` | 48 passed, 4 new: clock wound back still locks, frozen monotonic still locks via wall clock, neither advancing stays unlocked, and a tampered clock does not make it fire *early* either |
| Negative control | with the pre-fix wall-clock-only line restored, "winding the wall clock back does not prevent the lock" failed with `Expected: true / Actual: <false>` — the bypass reproduced exactly |
| `integration_test/app_lock_test.dart` + surface sweep + walkthrough, API 35 | **9 passed** in one invocation |

### 9 — tmux control mode could not accept input (closed)

The fourth defect of this shape, and the most complete example: `data/term/tmux_control_commands.dart`
existed in full — 82 lines, pane-id validation described as "load-bearing, not defensive noise",
chunking so a long paste cannot exceed tmux's command-line limit — and **nothing in `lib/` referenced
the file at all**. Meanwhile the setting, the parser and the attach path were all wired, so the
feature looked shipped: output rendered correctly and typing silently went nowhere.

Kotlin does both halves at `AppViewModel.kt:6092` (`sendKeysHex`) and `:5970` (`refreshClientSize`).

- `shell_session.dart` learns the pane id from the `%output` events tmux is already streaming, so
  input works from the first byte rather than needing a `list-panes` round trip.
- `write` now routes through `_encodeForChannel`, which wraps input in `send-keys -t <pane> -H` only
  in control mode; an ordinary PTY attach still writes raw bytes.
- `resize` additionally sends `refresh-client -C <cols>x<rows>`.

Input arriving before any pane is known is **not** sent to a guessed pane — that would deliver
keystrokes somewhere the user is not looking.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,945 passed** (+4 over 1,941) |
| `test/shell_session_test.dart` | 27 passed, 4 new: keystrokes become `send-keys -t %7 -H 68 69`, no pane means no guess, an ordinary attach still sends raw bytes, and a resize emits `refresh-client -C 100x40` |
| Negative control | restoring the raw-byte write made the channel receive `hi` instead of a `send-keys` line — exactly the bytes tmux would have parsed as a command |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Not covered:** proven against a fake channel. A real `tmux -CC` attach needs the Docker fleet.

### 10 — pasting a folder into itself (closed)

**Not a Kotlin parity gap — a defect in Flutter's own implementation, and the guard for it was
already written.** Kotlin has no equivalent check either, but it also does not have this recursion:
`isWithin` was added during the port, documented as being to "stop a move that would drag a directory
into itself, which on a real filesystem either errors or destroys the subtree", and then never wired
in.

A same-endpoint **move** is safe: it goes through `source.rename()` and the server refuses. A
same-endpoint **copy** goes through `_copyRemoteEntry`, which is the app's own recursion — `mkdir`
the destination, `list` the source, recurse per child. With the destination inside the source, each
`list` returns a directory that now contains the copy just made, and the walk never terminates.

`beginPaste` and `pasteClipboard` both refuse it now. The check is on both because `pasteClipboard`
is the method that actually recurses and is reachable directly.

Segment-wise comparison matters: a string prefix test would refuse pasting `/srv/www` into
`/srv/www-old`, which is an ordinary sibling paste.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,950 passed** (+5 over 1,945) |
| `test/sftp_view_model_test.dart` | 72 passed, 5 new: direct child refused, deeper descendant refused, `pasteClipboard` refuses directly, a prefix-named sibling still allowed, and a *file* of the same name is not refused |
| Negative control | disabling the guard made both refusal tests report `Actual: <null>` — the unbounded path was reachable |
| Surface sweep + walkthrough, API 35 | 7 passed |

### 11 — binary files opened silently in the editor (closed)

Hardening rather than a Kotlin port: Kotlin guards only on *size* (`AppViewModel.kt:8068`, "guard
against opening a huge binary as text"), never on content. `looksBinary` was written during the port
for this, and never called.

The lossy-decode case is the one that actually destroys data. `dartssh_sftp.dart:147` reads with
`utf8.decode(capped, allowMalformed: true)`, so every byte that is not valid UTF-8 has already become
U+FFFD by the time the editor is handed a string. It renders as an ordinary glyph, so nothing on
screen suggests anything is wrong — and saving writes `EF BF BD` over whatever was there.

- `file_edit.dart` — `binaryEditWarning(String)`, reporting NUL bytes and U+FFFD separately, because
  "this is a binary" and "this was read lossily" call for different wording. NUL takes precedence.
- `sftp_view_model.dart` — `editorBinaryWarning`, set in `readForEditing` **after** the read so the
  sudo path is covered by the same check, and cleared per open so a stale warning cannot accuse an
  innocent file.
- `file_editor_sheet.dart` — an amber card above the editor.

A warning, not a refusal (§17), matching the original doc's intent: the file still opens, because an
operator who knows what they are looking at may well want to read it.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,960 passed** (+10 over 1,950) |
| `test/domain_test.dart` | 60 passed, 6 new: plain text and valid multi-byte UTF-8 stay silent, NUL reported as binary, U+FFFD reported as a lossy read, NUL takes precedence, empty file safe |
| `test/sftp_view_model_test.dart` | 76 passed, 4 new covering the **wiring**, which is what was actually missing |
| Negative control | stubbing the assignment back to `null` failed both warning tests with `Actual: <null>` |
| Surface sweep + walkthrough, API 35 | 7 passed |

### 12 — alert history retention was never applied (closed)

Found by a **new probe**, the orphan sweep having been exhausted: for each field of `AppPreferences`,
check whether anything outside the settings screen, the preference definition and the generated
database code ever reads it. A setting that is stored and shown but never consulted is the same
silent-failure shape as defect 7, and this is what the probe turned up.

`alertHistoryLimit` had **zero consumers**. A monitoring app archives an incident every time one
resolves, so the table grew without bound while the setting sat there claiming to cap it.

Wired at the three points Kotlin uses:

- `alerts_view_model.dart` — prunes that host after every archive, matching `AppViewModel.kt:10845`.
- `settings_view_model.dart` — prunes every host on save, so a cap the user has just *lowered* bites
  immediately rather than waiting for the next incident on a quiet fleet.
- `backup_view_model.dart` — prunes after a restore that brought alert history in, since a backup
  can carry far more than this device is configured to keep.

The cap is per host, not global: a noisy host must not evict a quiet host's archive.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,964 passed** (+4 over 1,960) |
| `test/alerts_view_model_test.dart` | 43 passed, 4 new: archiving trims to the limit, the *newest* rows survive, each host keeps its own allowance, and a history already under the limit is untouched |
| Negative control | removing the insert-time prune failed the first guard with `Expected: <= 10 / Actual: <40>` |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Not covered:** the settings-save and restore prune points are wired and analysed but exercised only
through `applyHistoryRetention`; no test drives them via the Settings screen or a real restore.

### 13 — SFTP sort order not persisted (closed)

Found by a **third probe**: diff the settings keys Kotlin reads (`it.key == "..."`, 44 of them)
against every key Flutter reads or writes. Fourteen Kotlin keys had no Flutter counterpart; eight had
no presence in `lib/` at all.

`sftp_sort` is the one with a feature already built behind it — Flutter has the whole sort menu, and
simply never saved the choice.

- `sftp_sort.dart` — `SftpSortOption.fromStored`, matching **case-insensitively**. An exact
  comparison would silently reset the sort order of every user upgrading from the Android app: their
  stored `SizeDesc` would not match `sizeDesc`, and the setting would still be theirs while no longer
  being the one in force. Same class of trap as the `app_lock_grace_ms` key comment already in
  `app_lock_controller.dart`.
- `sftp_view_model.dart` — writes on change (fire-and-forget, as Kotlin does), and restores in
  `start()` **before** the first listing so the initial view is already in the user's order rather
  than snapping to it a moment later.

New writes use Dart's `.name`, so the value is camelCase from here on. That is a one-way asymmetry
with the Android app, which is the right trade for a migration that only runs Kotlin → Flutter, but
it is an asymmetry and worth knowing.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,969 passed** (+5 over 1,964) |
| `test/sftp_view_model_test.dart` | 81 passed, 5 new: the choice is written under the Kotlin key, a stored order is in force before the first listing, an Android-written `SizeDesc` is honoured, an unrecognised value falls back instead of throwing, re-selecting the current order is a no-op |
| Negative control | removing the write and the restore failed both guards (`Actual: <null>`, and `nameAsc` instead of `sizeDesc`) |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Still unpersisted from the same sweep**, each a Kotlin key with no Flutter presence:
`backup_export_selection`, `backup_last_export_time`, `cross_paste_recurse`, `first_run_complete`,
`review_prompt_shown`, `share_scan_protocols`, `share_sort`, `ssh_success_count`. Some correspond to
features Flutter may not have at all (the review prompt, share-scan protocol selection) and each
needs checking against its Kotlin use before being called a defect.

### 14 — recursive copy asked every time (closed)

The second defect from the settings-key diff, and the only other key in that list whose feature
Flutter already has.

**A deliberate partial port, stated rather than hidden.** Kotlin puts this in a clipboard *bar* as a
checkbox; Flutter's clipboard is a single toolbar icon with no bar to host one. Inventing that
surface would be a larger UI change than the defect warrants, so the prompt stays for the first
paste — but the answer is now persisted, and once it is yes the user is not asked again. That
delivers Kotlin's stated intent ("persisted so the choice sticks across sessions") without a
speculative redesign.

Only a **yes** is stored. Remembering a "no" would be remembering a cancellation: the next paste
would silently refuse to carry folders with nothing on screen explaining why.

Anything that is not exactly `true` reads as off, so a malformed row cannot quietly enable a slower,
heavier transfer.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,975 passed** (+6 over 1,969) |
| `test/sftp_view_model_test.dart` | 87 passed, 6 new: defaults off, opting in writes the Kotlin key, the opt-in survives a restart, a malformed value reads as off, opting back out persists, and a folder paste with the opt-in stored is no longer refused |
| Negative control | removing the write and the restore failed both guards (`Actual: <null>`, then `false` instead of `true`) |
| Surface sweep + walkthrough, API 35 | 7 passed |

### Settings-key sweep: remaining keys adjudicated

The other six Kotlin keys with no Flutter presence correspond to **features Flutter does not have**,
not to settings it forgets — so they are missing-feature work, not key wiring, and are recorded here
rather than silently fixed:

| Key | Kotlin feature | Flutter |
|---|---|---|
| ~~`share_sort`~~ | ~~sort order for the Shares list~~ | **withdrawn — see the correction under defect 15; Flutter sorts shares through the same generalised browser** |
| `share_scan_protocols` | which protocols the LAN share scan probes | no such selection |
| `backup_last_export_time` | "last backup taken" shown to the user | never recorded |
| `backup_export_selection` | remembers which sections were last exported | not persisted |
| `first_run_complete` | first-run flag | no first-run path |
| `review_prompt_shown`, `ssh_success_count` | in-app review prompt after N successful connections | no review prompt |

### 15 — "Last backup" never recorded (closed)

First of the missing *features* from the settings-key sweep, rather than a wiring defect.

- `backup_view_model.dart` — `lastExportTime`, `loadLastExportTime()`, and a write in
  `reportSaved`. Recorded **on save success, not at export**: the file dialog can still be
  cancelled after the JSON is built, and a "last backup" that counts an abandoned export tells the
  user they are covered when they are not. Kotlin records on write success too
  (`AppViewModel.kt:11415`).
- `backup_screen.dart` — `Last backup: Never` in amber, or the formatted date in the muted colour.
  The amber is the point: "Never" is the state worth drawing attention to.

A stored `0` reads as *Never* rather than as 1 January 1970 — Kotlin writes 0 for "never", and a
1970 date would be a confident-looking lie.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,980 passed** (+5 over 1,975) |
| `test/backup_screen_test.dart` | 26 passed, 5 new: never-exported says so, a stored time is shown on open, a completed save stores exactly what it displays, and `0` / malformed both read as Never |
| Negative control | removing the write left the screen reading `Last backup: Never` after a successful save |
| Surface sweep + walkthrough, API 35 | 7 passed |

### Correction to the previous iteration's table

`share_sort` was listed as a missing feature. **That was wrong, and the row is withdrawn.** Flutter
*does* sort share listings: `openShare` puts the share into the same generalised browser, so
`visibleEntries` applies `sortEntries` to it. Kotlin keeps two independent sort options because it
has two separate browsers; Flutter deliberately has one (§11, "everything downstream is identical,
which is why the browser is generalised here rather than duplicated into a second screen"). One sort
preference is the consequence of that decision, not an omission.

### 16 — export selection not remembered (closed)

- `backup_selection.dart` — `encode()` / `decode()`, **byte-compatible with Kotlin's**
  (`AppViewModel.kt:636`-`676`): the `v2:` prefix followed by comma-separated section names. The
  Flutter enum's own names already match Kotlin's keys exactly, so a selection written by the Android
  app is read back unchanged.
- `backup_view_model.dart` — persists on every toggle / All / None, and restores once per screen
  open.

Two behaviours carried over deliberately, both tested:

- **The v1 migration.** A stored value with no `v2:` prefix predates tunnel backup, and Kotlin infers
  `portForwards` from `servers` for it. A v1 value *without* hosts must **not** gain them — otherwise
  a legacy settings-only selection would silently start exporting credentials on first launch after
  the upgrade.
- **Referential closure is applied before writing**, not assumed on read, so what is stored is what
  will actually be exported.

An unrecognised section name is ignored rather than failing the parse, so a selection written by a
newer build degrades to the sections this one understands instead of resetting the user's choice.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **1,992 passed** (+12 over 1,980) |
| `test/backup_selection_test.dart` | 8 new: round-trip, the exact Kotlin encoding (`v2:scripts`), closure applied on write, empty means everything, v1 inherits tunnels from hosts, v1 without hosts stays without them, v2 is literal, unknown names ignored |
| `test/backup_screen_test.dart` | 4 new: the choice is written under the Kotlin key, a stored selection wins over the default, an Android-written v1 value is honoured, nothing stored leaves the default alone |
| Negative control | removing the write and the restore failed both guards (`Actual: <null>`, then the default winning over the stored choice) |
| Surface sweep + walkthrough, API 35 | 7 passed |

### 17 — in-app review nudge (policy closed, store call seamed)

- `platform/review_prompt.dart` — `reviewPromptIsDue()` (pure) and `ReviewPromptController`, holding
  Kotlin's rule exactly: at least three successful sessions, once ever.
- `shell_view_model.dart` — counts a success at the point a session is added, which is the only
  definition of "it worked" worth counting: authenticated and channel open.

**The store call is injected and nullable, deliberately.** Kotlin reaches Play through
`flavorRequestInAppReview`, a no-op in its open-source flavor. Adding an equivalent Flutter package
is a *dependency* change, and AGENTS.md treats those as a security boundary: forced-fresh checksum
regeneration across every resolved graph plus both release SBOMs. Those gates are blocked (Docker,
hosted CI), so the dependency is not added blind. Everything that decides *whether* to ask is ported
and tested; supplying the launcher is a two-line change once the dependency process can run.

Two rules carried over because they are what stop the nudge becoming a nuisance:

- The count is persisted on **every** success, so two sessions, a restart, and a third is three.
- `review_prompt_shown` is written **before** the launcher runs and never retried. The store decides
  whether a sheet appears, so "we asked" has to count as spent — including when the launcher throws.
- A build with no launcher counts but records nothing: a build that cannot ask must not record that
  it did, or wiring the store up later would find the nudge already spent.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,001 passed** (+9 over 1,992) |
| `test/review_prompt_test.dart` | 9 passed, covering the threshold, one-shot behaviour, survival across restart, no-launcher builds, and a throwing store |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Not covered:** the platform review sheet itself. No store SDK is wired, by design.

### 18 — first-run flag (will not port)

`first_run_complete` looked like a missing Flutter setting. It is not: it is **dead code in Kotlin**.

- `completeFirstRun()` has exactly one reference in the entire Android source — its own declaration.
  It is never called, so `first_run_complete` can never be written, and `isFirstRun` is therefore
  always true.
- `isFirstRun` has four references, all inside `AppViewModel.kt`: the declaration, two loads, and the
  assignment in that uncalled function. Nothing reads it.
- `hasConnectedOnce` is the same shape — three references, all internal. Its comment describes
  gating "first-run notification/battery prompts", an intent that was never wired.

Porting it would mean adding dead state to Flutter to match dead state in Kotlin, which is the exact
failure mode this ledger has been documenting from the other direction. Recorded here so the next
sweep does not re-raise it as a gap.

**Do not confuse this with `FirstRunDialog`** (`AppUi.kt:1437`), which *is* live — but gated on
`needsPermissions`, not on `isFirstRun`. It is a permissions prompt with a misleading name, and
Flutter already has it in `app_scaffold.dart:713`-`813` (local network, notifications, battery).

### 19 — label casing, normalised in both (closed)

First finding from the inventory queue, working `ToolsScreen.kt` in order. The hub's eight entries,
icons and order match Kotlin exactly; the **casing** did not.

Kotlin's own casing was inconsistent — `Crash history` and `Device & diagnostics` in sentence case
sitting beside `Alerts & Rules`, `Network Tools`, `OmniTerm Utilities` and `Trusted Host Keys` in
Title Case. Copying that into Flutter would have imported the inconsistency, so **both sides were
normalised to sentence case instead**, per the standing instruction to fix an issue in both places
rather than mirror it.

- Flutter: five hub labels, the hub `SectionHeader`, and Auth Keys' `Trusted host keys`.
- Kotlin (parity branch): the same seven strings, plus the two additional `ToolScaffold` titles that
  carried the Title Case forms (`Network tools`, `App backup`) — ten occurrences in all.

**No test asserted any of them on either side**, which is how they drifted unnoticed. The Flutter
labels are now pinned verbatim.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,009 passed** |
| `test/tools_hub_screen_test.dart` | 9 passed, 1 new pinning all eight labels and the section header |
| Negative control | changing one label failed the guard (`Found 0 widgets with text …`) |
| Kotlin `compileOpenSourceDebugKotlin --rerun-tasks` | BUILD SUCCESSFUL (only pre-existing `OmniTermWidget` deprecation warnings) |

### 20 — dead Kotlin removed (closed in the parity branch)

Three pieces of Kotlin that no longer do anything, deleted rather than ported:

- **`CronJobsToolView`** (`ToolsScreen.kt:2602`) — declared, never called. The live cron UI is
  `CronMonitorTab` (`MonitorScreen.kt:298`, Monitor tab 5), which Flutter already has as
  `MonitorTab.cron`. 48 lines removed.
- **`completeFirstRun()`** — one reference in the whole Android source, its own declaration. Because
  it is never called, `first_run_complete` can never be written and `isFirstRun` is permanently true.
- **`isFirstRun`** and **`hasConnectedOnce`** — the fields it fed, plus the two settings loads that
  populated them. Nothing read either. `hasConnectedOnce` carried a comment describing gating for
  "first-run notification/battery prompts", an intent that was never wired.

Verified with `grep`: zero references to any of the four names remain anywhere under `app/src`.

**Not to be confused with `FirstRunDialog`** (`AppUi.kt:1437`), which is live — but gated on
`needsPermissions`, not `isFirstRun`. It is a permissions prompt with a misleading name, and Flutter
already has it in `app_scaffold.dart:713`-`813`.

### 21 — root back press exited without warning (closed)

Found by sweeping `ToolScaffold` and back behaviour, next in the `ToolsScreen.kt` queue.

Kotlin's `BackHandler` does three things once `navigateBack()` has nothing left to pop: warn on the
first press, and on a second press within two seconds either finish, or — if any session is still
connected — show "Exit OmniTerm? / Exiting will terminate all active background SSH sessions." with
**Terminate & Exit** in red. Flutter had none of it: `canPop: nav.screenHistory.length <= 1` handed
the press straight to Android, so one stray back gesture at the root dropped every live shell with
nothing to undo.

- `domain/back_exit_policy.dart` — `decideBackExit()`, pure, so the rules are testable without a
  platform back gesture. The session check deliberately sits on the **second** press: warning about
  live sessions before the user has shown any intent to leave would fire on every accidental swipe.
- `main.dart` — `canPop: false` unconditionally, so every root-level exit goes through the guards.
  The SnackBar's duration is exactly the double-press window, so the message cannot outlive the state
  it describes. The armed press is consumed on Cancel, or a bare back press afterwards would exit
  without asking again.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,009 passed** |
| `test/back_exit_policy_test.dart` | 7 passed: first press warns (with and without sessions), second exits or confirms, the window expires, and the boundary is exclusive at exactly 2000 ms as Kotlin's `< 2000` is |
| `integration_test/back_exit_test.dart`, API 35 | 2 passed — in-app back walks the history; a root press warns and the app is still running |

**A test bug worth recording:** the first version of the device test pressed back six times to drain
the history. The second press was inside the window with no sessions open, so it exited the app and
hung the run until the 1200 s timeout. The launch screen is already the root, so one press is both
sufficient and safe — the other two branches end in `SystemNavigator.pop()` and would take the test
host down with them. They are covered by the policy unit test instead.

### 22 — biometrics not re-offered on resume (closed)

From the `AppUi.kt` block of the inventory, starting with the security surfaces.

`_AppLockScreenState` triggered biometrics once, in `initState`, via a post-frame callback. The gate
keeps that screen mounted for as long as `isLocked` is true, so `initState` does not run again — and
the platform cancels a biometric prompt when the app is backgrounded underneath it. Net effect:
leave the app while the prompt is up, come back, and the only way in is to type the PIN.

`_AppLockScreenState` is now a `WidgetsBindingObserver` and re-offers biometrics on return.

**Gated on a real backgrounding, not on any resume.** The biometric sheet can itself drive an
`inactive → resumed` flicker, and re-prompting on that would let a cancelled prompt immediately raise
another. Only `paused`/`hidden`/`detached` arms the retry.

**This cannot bypass the app-lock timeout.** The prompt lives inside the lock screen, which only
exists when `isLocked` is already true — a state reached through `onForegrounded()`, which compares
elapsed time against the configured timeout (defect 8). Re-offering an unlock method on an
already-locked screen is not the same as re-authenticating.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,013 passed** (+4 over 2,009) |
| `test/app_lock_test.dart` | 52 passed, 4 new: a real backgrounding re-offers, an `inactive` flicker does not, a build without biometrics is untouched, and a successful read on resume unlocks |
| Negative control | removing the retry failed with `Expected: <2> / Actual: <1>` prompts, and the lock screen still present after a successful read |
| `integration_test/app_lock_test.dart` + surface sweep + walkthrough, API 35 | **9 passed** |

**A test bug worth recording:** the first version drove `paused → resumed` directly, and Flutter
asserts on shortcut transitions. The real sequences are `inactive → hidden → paused` out and
`hidden → inactive → resumed` back; every intermediate state has to be delivered or the framework
throws before the code under test runs.

### 23 — privileged actions were not re-authenticated (closed)

From the `AppUi.kt` inventory block, sweeping `SudoAuthDialog`.

A confirmation dialog asks about **intent**; this gate is about **identity**. Once a sudo password is
saved against a host, rebooting it or stopping a unit needs no credential from the user at all — so
the question "did you mean this?" is not the one that matters.

Kotlin's condition, reproduced exactly: a **stored** sudo password *and* something to check the user
against (`useBiometrics || savedPin != null`). With no stored password there is nothing extra to
protect — the user will be typing it. With no PIN or biometrics there is nothing to verify against,
so a prompt would be theatre. It deliberately does **not** consult whether the app lock is currently
*enabled*: the existence of a PIN is what makes the check possible, and Kotlin tests the same two
things.

- `app_lock_controller.dart` — `requiresSudoAuth()`, `verifyPinForSensitiveAction()` and
  `authenticateForSensitiveAction()`. Both verifiers run **without unlocking the app**, and the PIN
  path shares the lock screen's throttle: a separate allowance here would be a way to brute-force the
  same PIN at full speed from a different dialog.
- `widgets/sudo_auth_dialog.dart` — biometric auto-prompt with the PIN field underneath, matching
  Kotlin's layout. `barrierDismissible: false`, because an accidental dismissal that silently
  cancelled a reboot reads as the app ignoring the button.
- `monitor_screen.dart` and `monitor_tabs.dart` — the gate on reboot and on service actions, the two
  Kotlin gates.

**A deliberate fail-closed choice:** the screens `read<AppLockController>()` unconditionally rather
than tolerating a missing provider. A build that dropped the provider now crashes visibly instead of
silently skipping the gate. That surfaced immediately — an existing reboot test had no such provider
— and the fix was to give the *test* the controller, not to soften the lookup.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,029 passed** (+16 over 2,013) |
| `test/sudo_auth_test.dart` | 12 new: the gate condition in all four combinations, PIN verify without unlocking, shared throttle, hashed PINs, and biometric refusal/throw/disabled |
| `test/monitor_screen_test.dart` | 38 passed, 4 new driving the real screen: a stored password prompts and runs nothing until answered, no stored password is not gated, the right PIN lets the reboot through, a wrong PIN keeps the dialog open |
| Negative control | forcing `requiresSudoAuth` to false failed the gating guards (`Expected: true / Actual: <false>`) |
| Surface sweep + walkthrough, API 35 | 7 passed |

### 24 — silent loss of session persistence (closed)

From the `AppUi.kt` inventory block, sweeping `TmuxInstallDialog`.

The self-guarding bootstrap (`command -v tmux >/dev/null 2>&1 && …`) is what made this invisible:
nothing errored, nothing was logged, and the shell opened normally. A host explicitly configured for
persistent sessions simply stopped being persistent.

- `remote_commands.dart` — `tmuxCheckCommand` and `tmuxInstallCommand()`, ported verbatim from
  `data/RemoteParsers.kt:140` and `:303`.
- `shell_view_model.dart` — probes before connecting a persistent host, exposes
  `tmuxPromptServer` / `tmuxInstallOutput` / `tmuxInstalling`, and implements
  `installTmuxAndConnect()`, `connectWithoutPersistence()` and `dismissTmuxPrompt()`. `connect()`
  gained `forcePlainShell` so the non-resumable choice is honoured rather than re-probed.

Three deliberate behaviours, each tested:

- **The probe runs once per host per session.** A round trip before every connection would be felt.
- **A probe that cannot run assumes tmux is present.** Refusing to connect over a failed probe would
  be worse than the degradation being fixed, and the bootstrap guards itself regardless.
- **The installer's exit code is not trusted** — tmux is re-probed afterwards, because several
  package managers exit 0 for "nothing to do" against a broken mirror. Kotlin's script re-checks for
  the same reason.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,048 passed** (+19 over 2,029) |
| `test/tmux_install_command_test.dart` | 9 new. The installer is **never executed** — it would install a package on whoever runs the suite — but it is parsed with `sh -n`, which catches the unbalanced quote or `fi` that would otherwise only appear on a user's server mid-connection. The check command *is* run, including against an empty `PATH` to stage "not installed" without touching the machine. |
| `test/shell_view_model_test.dart` | 37 passed, 10 new: no-tmux prompts instead of connecting, tmux connects silently, the probe runs once, non-persistent hosts are never probed, a failed probe assumes present, non-resumable writes no bootstrap, a successful install connects with persistence, a failed install keeps the prompt, output streams, dismiss connects nothing |
| Negative control | disabling the gate failed with `Expected: not null / Actual: <null>` |
| Surface sweep + walkthrough, API 35 | 7 passed |

**The dialog landed in the following iteration**, closing the gap this entry opened.

`widgets/tmux_install_host.dart` — mounted above every screen next to the host-key prompt, because a
persistent host is connected from the host list, a shortcut and a quick action too, not only from the
terminal. It offers Kotlin's three choices: Install tmux, Connect non-resumable, Cancel. The
installer's output streams into the dialog while it runs, with every button disabled and the barrier
locked so it cannot be torn down mid-install.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,054 passed** (+6 over 2,048) |
| `test/tmux_install_host_test.dart` | 6 new: nothing shown when tmux is present, all three choices offered when it is not, non-resumable opens a plain shell, cancel connects nothing and clears the pending host, a failed install keeps the prompt and shows the output, a successful one closes and connects |
| Negative control | suppressing the prompt failed with `Found 0 widgets with key [<'tmux.install.dialog'>]` |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Two widget-test traps this cost two attempts each, recorded so the next one does not repeat them:**

- A dialog builder that schedules its own pop re-schedules it on every rebuild, and the frame loop
  never goes quiet — `pumpAndSettle` then hangs to its timeout. The host closes the route instead.
- `testWidgets` installs a fake clock, so a future resolving off a real timer — anything touching the
  drift database — never completes. `tester.runAsync` is required around `connect()` and around the
  taps that start view-model work. A live `ShellSession` also runs a ~16 ms publish timer, so
  `pumpAndSettle` can never be used once a connection succeeds; bounded `pump` calls are.

### 25 — offline warning fired before anything had checked (closed)

From the `AppUi.kt` block, sweeping `OfflineConnectDialog`.

The dialog itself **is** ported — on the Hosts tab rather than app-level, and a source comment in
`shell_view_model.dart` says so. Checking that claim against the code confirmed it, which is worth
noting because most entries in this ledger went the other way.

The **trigger** was wrong. `servers_screen.dart` warned whenever `status != 'online'`, and
`tables.dart:68` defaults a new host's status to `offline`. So the first connection to a
just-created host always warned that it appeared offline — a false alarm at precisely the moment the
user is least able to judge it, and the kind that teaches people to dismiss the warning that matters.

- `host_status_probe.dart` — `hasProbed()`, backed by an in-memory set filled only when a probe
  returns a real answer. A probe that **threw** does not count: a failed check says nothing about the
  host and must not arm a warning about it.
- `host_display.dart` — `shouldWarnHostOffline({probed, status})`, the rule on its own.
- `servers_screen.dart` — calls it instead of testing status directly.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,061 passed** (+7 over 2,054) |
| `test/host_status_probe_test.dart` | 16 passed, 7 new: unprobed / reachable / unreachable / threw, and the three rule cases |
| Negative control | reverting the rule to status alone failed with `Expected: false / Actual: <true>` for an unprobed host |
| Surface sweep + walkthrough, API 35 | 7 passed |

**A dead end worth recording.** I first wrote this as widget tests driving the Hosts tab. They fought
the provider tree — the connect path needs a `ShellViewModel` the harness does not have — and one
variant hung the runner for four minutes before timing out. Extracting the decision into
`shouldWarnHostOffline` and testing that directly guards the same regression without a brittle
widget tree. Reverting the abandoned tests also truncated `main()`'s closing brace; the file has
uncommitted migration work in it, so it was repaired in place rather than checked out.

**The coverage gap this entry opened was closed in the following iteration.** The confirmation now
lives in `ShellViewModel.connect` as it does in Kotlin's `connectTerminal`, so every route to a
terminal is covered — the host list, the Infra tab's container shell, the quick-connect sheet, a
shortcut and a quick action. The screen-local dialog in `servers_screen.dart` was removed rather than
left to double up.

- `shell_view_model.dart` — `offlineConnectPromptServer`, `connectConfirmedOffline()` and
  `dismissOfflineConnectPrompt()`, with a `hasProbed` predicate injected from `HostStatusProbe`. A
  null predicate reads as "not probed", which **suppresses** the warning: a build that cannot tell
  must not invent an alarm.
- The check runs **before** the tmux probe. There is no point spending a round trip asking a host
  whether it has tmux when the last check said it was not answering at all.
- `widgets/connection_prompt_host.dart` — `TmuxInstallHost` generalised into `ConnectionPromptHost`
  and made to carry both questions, rather than mounting a second near-identical widget. Both are
  asked by the same view model at the same moment.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,066 passed** (+5 over 2,061) |
| `test/connection_prompt_host_test.dart` | 11 passed, 5 new: a probed-offline host is asked before connecting, an unprobed one is not, connect-anyway proceeds, cancel connects nothing, and the offline question precedes the tmux round trip |
| Negative control | disabling the gate failed with `Found 0 widgets with key [<'offline.connect.dialog'>]` |
| Surface sweep + walkthrough, API 35 | 7 passed |

### 26 — remote command output on Monitor (closed)

Last of the `AppUi.kt` dialogs, sweeping `ActionStreamDialog`.

Kotlin has **one** presentation for remote output, used by all fifteen `runStreamingAction` callers.
Flutter had two-and-a-half: a good card on Infra, a bare `Text` on Monitor, and nothing shared
between them.

`widgets/command_output_card.dart` — extracted from Infra's existing `_ActionOutput` and now used by
both, rather than a third copy being written. The properties it guarantees are the ones that made
Monitor's version a defect:

- **Monospace**, because `systemctl` and `docker` output is column-aligned and a proportional font
  turns it into noise.
- **Selectable and copyable**, because this is the text an operator pastes into a search or a bug
  report — the whole reason for keeping it on screen instead of reporting "done".
- **Bounded and scrollable**, because a failed `apt-get` runs to hundreds of lines and an unbounded
  card pushes the list it belongs to off the screen.

`keyPrefix` is a parameter so each screen keeps its own stable widget keys and the existing Infra
tests still address the same identifiers.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,074 passed** (+8 over 2,066) |
| `test/command_output_card_test.dart` | 7 new: monospace, selectable, whole-output copy, height bounded under a 400-line output, title fallback, spinner only while running, dismiss reported |
| `test/monitor_screen_test.dart` | 39 passed, 1 new asserting Monitor's service output is copyable and monospace |
| `test/infra_screen_test.dart` | unchanged and green — the extraction kept its keys |
| Negative control | restoring Monitor's bare `Text` failed with `Found 0 widgets with key [<'monitor.services.feedback.copy'>]` |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Two test-harness traps, both mine.** A card dropped straight into a `Scaffold.body` stretches to
fill the screen, so the height bound cannot be observed — it needs a `Column(mainAxisSize: min)`, as
it has in the real screens. And a running `CircularProgressIndicator` animates forever, so
`pumpAndSettle` never returns; `pump` is required.

**Not ported, and deliberately:** Kotlin shows this output in a modal dialog, Flutter as an inline
card. The card is the better fit for Flutter's screens — it does not block the list underneath while
a long action runs — and Infra already established it. Recorded as a difference rather than left to
look like an oversight.

### 27 — host picker showed a nickname and nothing else (closed)

Last row of the `AppUi.kt` inventory block.

The drift between screens was the symptom; the omission was the defect. On a fleet holding `web-2`
and `web-2-old`, a picker showing only the nickname cannot tell them apart, and a host that has gone
quiet looks identical to one answering in 3 ms.

`widgets/host_selector_bar.dart` — one bar, used by Monitor and Infra, carrying what Kotlin's does:

- a **status dot** in the host's accent colour;
- the **name** in mono bold, with an optional prefix so Infra keeps its `Containers · ` label;
- **`user@host · latency`** beside it, routed through `HostDisplay` so it obeys Hide addresses —
  a picker is exactly the sort of chrome that ends up in a screenshot;
- an accent chevron.

The closed bar and the open list deliberately show different things, as Kotlin's do: the bar is about
the host you are on, the list is about telling candidates apart, so its rows read
`name — user@host`.

An offline host shows `offline` rather than its last latency. A number from before the host went
quiet reads as if it were still answering.

`keyPrefix` is a parameter, as with `CommandOutputCard`, so both screens keep the widget keys their
existing tests already address.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,081 passed** (+7 over 2,074) |
| `test/host_selector_bar_test.dart` | 7 new: the closed bar names the machine, shows latency, says `offline` instead of a stale number, keeps the detail line under a label prefix, distinguishes `web-2` from `web-2-old` in the open list, reports a choice, and obeys Hide addresses |
| `test/monitor_screen_test.dart` / `test/infra_screen_test.dart` | unchanged and green — the extraction kept their keys |
| Negative control | blanking the detail line failed with `Expected: contains 'deploy@10.0.0.7' / Actual: ''` |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Not ported:** Kotlin's bar also supports split-pane selection (`allowSplitSelection`, two-host
tick-list) and arbitrary leading/trailing/second-row content. Flutter's Shell builds its split
selection separately, so the shared bar covers the single-host case only. Recorded rather than
implied — extending it is only worth doing if the Shell's picker is folded in too.

### 28 — no aggregate transfer progress (closed)

First row of the `SftpScreen.kt` block.

- `domain/transfer_aggregate.dart` — `aggregateTransfers`, `formatEta`, `formatSpeed`, ported from
  `TransferAggregate` (`ui/AppViewModel.kt:498`).
- `sftp_view_model.dart` — `SftpTransfer` gained `startedAt` and a `speedKbps` derived from it;
  `transferAggregate()` combines the running rows. Both take an injectable clock, because a test
  cannot wait a real second to observe a rate.
- `widgets/transfer_aggregate_bar.dart` — the bar itself, above the per-file list.

Four rules carried across, each with a test:

- **Only sized rows contribute to the total.** A transfer whose size the server never declared still
  counts its bytes as progress but adds no denominator; otherwise a nearly finished batch renders as
  barely started.
- **No sizes at all means an indeterminate bar**, not 0%. A determinate bar pinned at zero reads as
  stalled, which is the opposite of the truth.
- **The ETA is -1, not 0, when it cannot be estimated.** Zero renders as "finishing now", and
  "unknown" must not look like "nearly done".
- **Speed is averaged since the transfer started**, not sampled between updates. A per-chunk rate on
  a mobile link swings enough to make the ETA unreadable; Kotlin averages the same way.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,097 passed** (+16 over 2,081) |
| `test/transfer_aggregate_test.dart` | 12 new covering the four rules above plus clamping and negative byte counts |
| `test/sftp_view_model_test.dart` | 91 passed, 4 new: nothing running means no bar, finished rows stop counting, speed derives from elapsed time, and a transfer that has moved nothing reports no speed rather than dividing by its start |
| Negative control | a plausible wrong implementation — counting an unsized row's transferred bytes as its total — failed with `Expected: <1000> / Actual: <1050>` |
| Surface sweep + walkthrough, API 35 | 7 passed |

**A negative control that proved nothing, and was replaced.** The first mutation removed the
`totalBytes > 0` guard, which is a no-op: unsized rows have a total of zero, so summing them
unconditionally is identical arithmetic. It passed, which said nothing about the test. Substituting a
mistake a real implementation might make — falling back to the transferred bytes as the denominator —
made the guard fail properly. A control that cannot fail is not evidence.

**Not ported:** Kotlin's bar also shows batch position ("Transferring file 3 of 12 · 2 done, 9
pending") from `transferBatchTotal`/`transferBatchDone`, which Flutter does not track — its paste
loop has the count but does not publish it. The bar reports the concurrent file count instead.
Recorded rather than implied.

### 29 — SFTP sudo mode: false warning, and no authentication (closed)

Found while sweeping the `SftpScreen.kt` dialogs.

**(a) The dialog was factually wrong about the most destructive case.** It told the user that
"browsing, renaming and deleting are unchanged and still run as you". The code disagrees:
`createDirectory`, `rename` and `deleteEntries` all route through `_sudoMutation` when sudo is on
(`sftp_view_model.dart:1406`, `:1430`, `:1447`), and the delete is `rm -rf -- <paths>`. Telling
someone their deletes are unprivileged and then deleting as root is the worst possible direction for
that sentence to be wrong in. The wording now states what actually happens, matching Kotlin's "all
file operations will run as root".

**(b) Confirmation is not authentication** — the same distinction as defect 23. Kotlin shows the
warning and then requires a biometric or PIN before switching sudo on. Flutter switched it on from
the confirmation alone, so anyone holding the unlocked phone could turn on root file operations
against a host with a saved sudo password.

Reuses `requiresSudoAuth` / `requestSudoAuth` from defect 23 rather than growing a second gate.
Turning sudo **off** still needs nothing, as in Kotlin: dropping a privilege is not a privileged act.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,103 passed** (+6 over 2,097) |
| `test/sftp_screen_test.dart` | 28 passed, 6 new: the warning names root and no longer claims deletes are unprivileged, cancel leaves it off, a stored sudo password prompts and holds it off until answered, the right PIN switches it on, no stored password is not gated, turning it off needs no auth |
| Negative control | restoring the old wording failed with `Expected: contains 'run as root'`, and removing the gate failed with `Found 0 widgets with key [<'sudoAuth.dialog'>]` |
| Surface sweep + walkthrough, API 35 | 7 passed |

### Long-press sweep — no defects

All five `combinedClickable` sites across `SftpScreen.kt`, `AppUi.kt` and `ToolsScreen.kt` were
checked against Flutter and are ported:

- SFTP file row: long-press toggles selection — present in `_EntryRow`.
- Share file row: Kotlin's second browser. Flutter has one generalised browser (§11), so the same
  row already covers it — consistent with the correction under defect 15.
- Host card: long-press enters multi-select and selects that host — matches exactly.
- Scripts card: Kotlin's `onClick` and `onLongClick` are the same action, so nothing to port.

### 30 — the editor hid that it was writing as root (closed)

The other half of defect 29. Sudo mode is a **screen-level** toggle, so it can be switched on at the
toolbar and then forgotten by the time a file is open — and the editor gave no sign. Someone editing
`/etc/ssh/sshd_config` saw the same "Save" they would see on a file in their home directory.

- `sftp_view_model.dart` — `sudoWritesApply`, the exact condition `saveText` applies, exposed so the
  editor can state it rather than infer it.
- `file_editor_sheet.dart` — the header now reads `Editing · 12 lines · sudo` in red when the write
  will be privileged, and the button reads **Save as root**.

The line count comes from Kotlin's subtitle too. It is incidental; the colour and the button label
are the point.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,105 passed** (+2 over 2,103) |
| `test/sftp_screen_test.dart` | 30 passed, 2 new: nothing about root when sudo is off, and with it on the header says `sudo` in red and the button says `Save as root` |
| Negative control | forcing the indicator off failed with `Expected: contains 'sudo' / Actual: 'Read-only — tap the pencil to edit · 2 lines'` |
| Surface sweep + walkthrough, API 35 | 7 passed |

**One existing test needed changing, not the code.** `expect(find.text('Editing'), findsOneWidget)`
became a `startsWith` on the mode widget, because the line now carries the count and sudo state. Worth
naming: an exact-match assertion on a composed status line is brittle by construction.

**A test-fixture trap.** With sudo on, opening a file reads over an exec channel rather than SFTP, so
a stub shell that throws leaves the editor unopened and the assertions running against nothing. The
stub has to emit `sudoOutputMarker` before the contents, because `parseSudoRead` returns null without
it and the view model reports that as "sudo refused".

### Destructive-confirmation sweep — no defects

Prompted by four security defects sharing one shape, every Kotlin confirmation carrying "cannot be
undone" or "permanently" was checked against Flutter:

| Action | Result |
|---|---|
| Docker image / volume / network prune | all three confirmed; the volume copy names permanent data loss, as Kotlin's does |
| Individual image / volume / network removal | confirmed |
| Compose `down`, service removal, scaling | confirmed |
| Host deletion | confirmed, with Kotlin's wording essentially verbatim |
| SFTP delete (file, directory, selection) | confirmed |
| Health-scoring reset, backup restore | confirmed |

The one difference found is not a defect: Kotlin **warns** that a rename will overwrite an existing
file and proceeds; Flutter **refuses** the rename with `"<name>" already exists here.` Refusing is the
safer of the two, and it is recorded here so a later sweep does not read it as a missing warning.

### 31 — no download or upload from the SFTP screen (closed)

The unreachable-code pattern at feature scale, and the largest instance so far: two complete view
model methods, a Transfers tab built to display their progress, and nothing anywhere that calls
either.

Download is now wired end to end:

- `platform/device_file_store.dart` — hands a file to the platform save dialog **by path**, not by
  content. `BackupFileStore` passes bytes because a backup is something the app built and already
  holds; a remote file can be gigabytes, and buffering it to hand over would fail on exactly the
  transfers most worth doing. Injectable, so the flow is testable without a system dialog.
- `sftp_view_model.dart` — `downloadToDevice` stages to a temp file, offers it, and **deletes the
  staging copy whether or not the save succeeded**. Leaving a copy of a remote file in the cache is
  a quiet way to widen access to it.
- `sftp_tabs.dart` — a `Download to device` item in the per-entry menu, on files only, behind the
  large-transfer warning Kotlin applies.

Evidence:

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,107 passed** (+2 over 2,105) |
| `test/sftp_screen_test.dart` | 32 passed, 2 new: a file offers the action, a directory does not |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Upload landed in the following iteration**, closing the gap this entry opened.

- `device_file_store.dart` — `pick()`, returning a path rather than bytes for the same reason `save`
  takes one. A picker that will not open is treated as a cancel: there is nothing to upload either
  way, and an error over a chooser the user never saw would only confuse.
- `sftp_view_model.dart` — `uploadFromDevice` streams the file from disk rather than reading it into
  memory, and `sizeOfLocalFile` returns 0 rather than throwing, because the size only decides
  whether to warn and a failed stat must not block the upload that would report the real problem.
- `sftp_tabs.dart` — an upload button in the toolbar behind the large-upload warning, so all three
  of Kotlin's warning points (download, upload, cross-paste) are now covered.

**A clashing name is suffixed, never overwritten** — `upload` already did this, and there is now a
test pinning it, because an upload that silently replaces a file the user did not mean to touch is
unrecoverable.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,112 passed** (+5 over 2,107) |
| `test/sftp_view_model_test.dart` | 96 passed, 5 new: the file lands under its own name, a clash is suffixed, a transfer row is recorded, an unreadable file reports why and uploads nothing, and `sizeOfLocalFile` degrades to 0 |
| Negative control | removing the `uniqueName` call failed with `Expected: ['/home/root/notes (2).txt'] / Actual: ['/home/root/notes.txt']` |
| Surface sweep + walkthrough, API 35 | 7 passed |

**Coverage limits on what did land.** The two tests assert the action is offered and correctly scoped;
they do not drive a real download, because that needs a platform save dialog. The staging, cleanup
and warning paths are reasoned about and typed but not exercised — worth a device test against the
fleet when it is available.

### 32 — the Bookmarks tab was host-scoped, read-only and empty when it mattered (closed)

Three separate gaps behind one tab, and the third is the one that made the feature useless: **the tab
was gated on a host being online**, so on a fresh launch — before anything has been probed — the jump
list showed a sentence explaining why it was empty.

Kotlin's model is endpoint-scoped. A bookmark carries the host or share it belongs to, the list spans
all of them, and the endpoint is named on every row. Flutter stored the same rows, in the same format,
under the same keys, and then only ever read one of them.

What landed:

- `domain/endpoint_bookmark.dart` — the model and the stored format, pulled out as pure functions so
  the `|||` encoding, the key families and the availability rule are testable without a database.
  Identity is *endpoint + path*, deliberately excluding the display name: otherwise renaming a host
  would leave its old bookmarks in the list beside the new ones.
- `sftp_view_model.dart` — `loadAllBookmarks`, `saveEndpointBookmark`, `removeEndpointBookmark` and
  `openEndpointBookmark`. The host-only `_bookmarkKey` became `_currentBookmarkKey`, which resolves
  to the share's row when a share is open — one list keyed by the browse target rather than Kotlin's
  two parallel lists.
- `sftp_tabs.dart` — the rewritten tab with add, edit, clone and a confirmed delete, unavailable rows
  dimmed rather than hidden.

**Shares are now bookmarkable**, closing the smaller gap underneath: `canBookmark` returned false for
shares because bookmarks were "stored per serverId". They were not — `share_bookmarks_{id}` is a key
the Kotlin app writes and this app's own restore path already knew how to remap.

Three decisions worth recording, because each one is a way this could have been got wrong:

- **The editor's endpoint starts unselected.** Defaulting to the browsed host would file bookmarks
  against the wrong machine without the user seeing the choice, and a bookmark on the wrong host is
  silently useless rather than visibly wrong.
- **The five default paths stay in memory and are never written.** They exist so the star column is
  useful on a new host; persisting them would put `/root` and `/etc` in the cross-endpoint list for
  every host the user has never opened. This matches `loadSftpBookmarks` (`:9006`).
- **An untested share stays available; an offline host does not.** Opening a host bookmark dials SFTP
  over an existing session, so it needs one. A share is dialled from scratch, so "never probed" is no
  reason to grey it out — and a freshly restored backup has probed nothing at all.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,154 passed** (+42 over 2,112) |
| `test/endpoint_bookmark_test.dart` | 17 passed, all new — keys, encoding, normalisation, identity, availability |
| `test/sftp_view_model_test.dart` | 112 passed, 16 new: the list spans hosts and shares, a host that saved none contributes nothing, offline is listed but not openable, add files against the chosen endpoint, edit moves in one operation, clone leaves the original, removal is scoped to its own row and its own host, the star and the list stay in step, opening switches host/tab/directory, a stale tap on an offline host does nothing |
| `test/sftp_screen_test.dart` | 39 passed, 7 new: the tab works with no host online, an offline row does not open, the empty state says so, add files against the chosen endpoint, removal asks and names the endpoint, cancelling keeps it, cloning prefills the path |
| `test/network_shares_test.dart` | 42 passed, 3 rewritten: a share writes its own key and not the host's, does not inherit the host defaults, and reloads its own bookmarks on open |
| Surface sweep + walkthrough, API 35 | **7 passed** — the surface sweep paints the rewritten tab in every theme and both orientations, which is the layout risk a `Column`/`Expanded` rewrite carries |

**Three negative controls**, each a plausible wrong implementation rather than a no-op:

| Control | Failure it produced |
|---|---|
| `saveEndpointBookmark` ignores `replacing` (an edit that adds but forgets to remove) | `Expected: '/opt' / Actual: '/etc\|\|\|/opt'` |
| `openEndpointBookmark` trusts the UI's greying and skips the re-check | `Expected: not SftpTab:<SftpTab.files> / Actual: SftpTab:<SftpTab.files>` |
| removal rewrites the row from the in-memory list instead of the endpoint's own row | the sibling bookmarks on that host were lost |

**Kotlin side.** Four Title Case strings normalised to sentence case in the parity worktree —
`Add Bookmark`, `Edit Bookmark`, `Clone Bookmark`, `Remove Bookmark?` (`ui/SftpScreen.kt:3259`,
`:3299`–`:3301`). `compileOpenSourceDebugKotlin` BUILD SUCCESSFUL. No dead code here: every bookmark
method in `AppViewModel.kt` has a live caller, checked rather than assumed.

**Coverage limit.** The editor's endpoint picker is driven in the widget tests, but no test opens a
bookmark on a *share*, because that needs a share client the host suite has no way to stand up. The
view model path is tested; the end-to-end share jump is not.


### 33 — no way to type a path, and no way home (closed)

Kotlin's breadcrumb row is not breadcrumbs at all: it is a full-width **address box** that shows the
current path, scrolls to its deepest segment, and becomes an editable field when tapped. Flutter
replaced it with a crumb strip — a fair design choice for going *up*, and a strictly worse one for
going *anywhere else*, because it removed the only way to name a destination.

The home button is the same unreachable-code pattern as defects 27 and 31: `openPath('')` resolves
the remote home, is tested, and had no caller.

What landed:

- `domain/remote_path.dart` — `resolveTypedPath`, the destination rule as a pure function.
- `sftp_tabs.dart` — `_Breadcrumbs` became stateful; the crumb strip swaps for a mono field with Go
  and Cancel, and gains an edit pencil and a home button. The in-progress text is **local state**, so
  it cannot survive a host switch or reappear on returning to the tab.

Two decisions, each a way this could have been got wrong:

- **An emptied box is a change of mind, not a jump to the root.** Returning `/` from a folder deep in
  a tree is a surprising way to lose your place.
- **A relative entry resolves against the current directory.** The box is prefilled with where you
  are, so `docs` means what it would in a shell. Kotlin passed relative input to `loadSftp`
  unresolved, which lists whatever the SFTP session's working directory happens to be — not
  something the user can see, and not what the prefill implies. **That is a defect in Kotlin**, fixed
  there too rather than copied across.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,166 passed** (+12 over 2,154) |
| `test/remote_path_test.dart` | 7 new: absolute, normalised, trimmed, relative against current, relative with no current, emptied, and the root itself |
| `test/sftp_screen_test.dart` | 44 passed, 5 new: a typed path opens, the box is prefilled, cancelling navigates nowhere, a bad path reports the failure, home returns to the remote home |
| Surface sweep + walkthrough, API 35 | **7 passed** — the sweep paints the Files tab in every theme and both orientations, which is where two added buttons could have overflowed the 32px bar |

**Three negative controls**, each a plausible wrong implementation:

| Control | Failure it produced |
|---|---|
| an emptied box returns `/` instead of null | `Expected: <null> / Actual: '/'` |
| a relative entry passed through unresolved (what Kotlin did) | `Expected: '/srv/www/docs' / Actual: '/docs'` |
| Cancel wired to `_go` — closes the box but still navigates | the cancel test failed on the listing that should never have been issued |

**Kotlin side.** `RemoteCommands.resolveTypedPath` added with the same rule, and both call sites — the
keyboard's Go action and the check button — now use it instead of inlining the same three lines
twice, where the rule could drift between them. `TypedPathTest`: **7 tests, 0 failures**;
`testOpenSourceDebugUnitTest` BUILD SUCCESSFUL.

**Coverage limit.** The tests drive the field through the widget tree against a fake filesystem. The
keyboard's Go action (`textInputAction: TextInputAction.go`) is wired but not exercised — a soft
keyboard is not something the host suite can press.

**Verified present, not a defect: archive extraction.** The inventory flagged `Extract here` as
unswept. Read against both: `SftpViewModel.extractArchive` and `isArchiveFile` cover the same ten
formats as `ui/AppViewModel.kt:9251`, `:9269`, behind the same confirmation. No gap.


### 34 — the host search neither elevated nor admitted it had been refused (closed)

Two failures compounding, and the compound is worse than either half: the search ran unprivileged
even with sudo on, and `find` was already told to discard its permission errors. The user turns sudo
on precisely *because* the tree is protected, and gets back "Nothing matched" — a wrong answer
wearing the clothes of a right one, with nothing on screen suggesting otherwise.

- `sftp_view_model.dart` — `searchHost` now wraps in `sudoShWrap` and pairs it with `sudoStdin`, the
  same shape as every other exec on this screen. The password goes over the channel, never into the
  command line, which is visible in `ps`, auditd execve records and sshd debug logs.
- `remote_commands.dart` — `searchSudoFailure`, so a refused search says so.

**The marker list is now one list.** `_runSudoScript` carried its own inline copy; both call sites
read `sudoFailureMarkers` now, because a marker added to one and not the other is a failure that
quietly stops being reported on exactly one screen.

**A type-tagged line is a result, never a complaint.** My first attempt checked the first non-blank
line, which is what Kotlin does — and the test caught it immediately, because for a search the first
non-blank line *is the first hit*. A file legitimately named `no such file.txt` reported itself as a
permission error and blanked the entire result set it appeared in. The wire format already
distinguishes the two: `d\t`/`f\t` is data, anything else is the shell talking.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,182 passed** (+16 over 2,166) |
| `test/sftp_view_model_test.dart` | 117 passed, 5 new: sudo off leaves it an ordinary command, sudo on elevates, the password goes over stdin, a refusal is reported, an error-shaped filename is still a hit |
| `test/remote_commands_folder_size_test.dart` | 6 new for `searchSudoFailure` and the shared marker list |
| Surface sweep + walkthrough, API 35 | **7 passed**, re-run after the toolbar change rather than reusing the earlier green |

**Three negative controls:**

| Control | Failure it produced |
|---|---|
| the original defect restored — search runs unelevated with sudo on | `Expected: a string starting with 'sudo -S' / Actual: 'find ...'` |
| the refusal check dropped, trusting `find`'s exit | the refused search reported `searchHits: []` and no error |
| `searchSudoFailure` ignores the type tag | `f\t/srv/no such thing.txt` suppressed its own result set |

**Kotlin side — a real defect found and fixed there.** `runSftpSearch` passed its output to
`sftpReadError`, which inspects the first non-blank line; for a search that is the first hit, so
Kotlin has exactly the bug my first attempt had. It now calls `RemoteCommands.searchSudoFailure`.
The marker list moved to `RemoteCommands.sudoFailureMarkers` — Kotlin's ten markers unchanged, so
`sftpReadError`'s other three callers behave as before, **plus `read-only file system`**, which
Kotlin was missing: an extract or compress into a read-only mount matched nothing and was reported
as a success.

`SearchSudoFailureTest`: **6 tests, 0 failures**. Whole Kotlin unit suite: **512 tests, 0 failures**.

**Coverage limit.** The sudo search is driven against a fake shell, so the elevation is asserted on
the command and stdin this app *sends*, not on a host actually honouring it. Whether the wrapped
`find` returns protected hits needs a real machine, which is still blocked on the fleet.

**Also in this pass — the selection toolbar, where I was wrong before reading it.** I first recorded
select-all as "verified present". It was not: reading Kotlin's toolbar against Flutter's showed
`selectAllVisible` **existed in the view model, was covered by two tests, and had no caller in the
UI** — the same unreachable-code pattern as defects 27, 31 and 33. There was no clear-selection
button either. Both are now in the toolbar.

- **Select all takes the *visible* rows, not the whole listing.** With a search typed or dotfiles
  hidden, selecting rows the user cannot see would put files they never chose into the next delete.
- The button **disables when everything visible is already selected**, so it never looks like it did
  nothing.

| Check | Result |
|---|---|
| `test/sftp_screen_test.dart` | 49 passed, 5 new: select-all takes every visible row, a filtered listing selects only what is on screen, dotfiles are not selected while hidden, an already-selected folder disables the button, clearing is offered once there is a selection |
| Negative control | selecting `_entries` instead of `visibleEntries` failed the filtered-listing test — the filtered-out file was selected |

**Still open here: batch download of selected files.** Kotlin's selection toolbar has
`Download selected files` (`ui/SftpScreen.kt:1747`); Flutter downloads one entry at a time from the
row menu. It needs a folder picker rather than a per-file save dialog, so it is its own slice rather
than a bolt-on — recorded rather than quietly skipped.


### 35 — twelve files meant twelve save dialogs (closed)

Opened by defect 34's sweep of the selection toolbar and left explicitly open there rather than
bolted on; this closes it.

- `device_file_store.dart` — `pickFolder` and `saveInto`, so the destination is chosen **once**. A
  save dialog per file is not a batch.
- `sftp_view_model.dart` — `downloadSelectedToFolder`, plus `selectedFilesForDownload`,
  `selectedDownloadBytes` and `batchDownloadNeedsWarning`.
- `sftp_tabs.dart` — the toolbar action behind the large-batch warning.

Decisions, each a way this could have gone wrong:

- **Files only.** A directory has no bytes to hand a save dialog, and walking into one would fetch a
  whole tree the user selected a single row for. Matches `selectedRemoteFileNames` (`:1556`).
- **One failure does not end the batch.** The first error is kept and reported next to how many did
  land — after a partial download the useful thing is knowing which file to go back for, not losing
  the eleven that worked. Same shape as Kotlin's `firstErr` / "Downloaded N of M".
- **Only the attempted files leave the selection**, so a folder the user also had selected is still
  selected afterwards rather than silently dropped.
- **Staging copies are deleted whether or not the save worked**, as the single-file path does: a
  remote file left in the cache quietly widens access to it.

**A real constraint, handled rather than hidden.** The platform's save-into-a-folder API takes
`Uint8List`, not a path — unlike the single-file `save`, which streams. Each file is therefore
briefly held in memory. Rather than let a large file take the app down mid-batch,
`batchDownloadByteCeiling` (256 MB) skips it and says to use the row's own `Download to device`,
which streams and has no such limit. 256 MB sits comfortably above the configuration files and logs
people actually multi-select, and well below what a phone will refuse to allocate.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,192 passed** (+10 over 2,182) |
| `test/sftp_view_model_test.dart` | 126 passed, 9 new — driven through a `FakeDeviceFileStore` that writes into a **real temp directory**, so the assertions are on the files that landed rather than on calls a mock was asked to make |
| `test/sftp_screen_test.dart` | 50 passed, 1 new: the action appears only once a *file* is in the selection, not for a directory |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Three negative controls:**

| Control | Failure it produced |
|---|---|
| the batch stops at the first failure | only `b.conf` was expected to land; nothing after the failure was written |
| the whole selection is taken, directories included | `docs` was downloaded as if it were a file |
| the size ceiling removed | the oversized file was attempted rather than skipped with advice |

**Coverage limit.** `pickFolder` and `saveInto` are exercised through a fake; the real Android tree
grant (`OpenDocumentTree`) and its iOS equivalent are not. The per-file byte ceiling is a guard
against an allocation this test suite never makes, so it is asserted as a decision, not as observed
memory behaviour.


### 36 — the Shares tab could save a share but never find one (closed)

The discovery half of the feature was absent. Not unreachable code this time — genuinely never
written.

**Built on `sweepSubnet` rather than porting Kotlin's loop.** Kotlin hand-rolls a semaphore, a
connect timeout and a `ConcurrentHashMap` dedupe; Flutter already had all three in `sweepSubnet`,
used by the LAN scanner in Tools. A second implementation would be a second place for the
concurrency cap and timeout to drift.

- `domain/share_scan.dart` — the protocol/port table, the stored selection, subnet parsing and
  sweep→hit mapping, all pure.
- `shares_view_model.dart` — `scanForShares`, protocol toggles, progress, and `startAddFromScan`.
- `shares_tab.dart` — a collapsed panel; the tab's job is the saved shares, and a scanner
  permanently occupying the top would push them off a phone screen.

Decisions worth recording:

- **An empty stored selection falls back to everything.** Honouring it would give a scanner that
  probes no ports and reports "none found" — indistinguishable from a quiet network, and wrong. The
  last enabled protocol likewise cannot be switched off, matching `:1181`.
- **The prefill stops at the endpoint.** Address, port and protocol come from the probe; share path,
  username and password are left blank. An open port says something is listening, not what it
  exports or who may read it — guessing either would save a share that fails on first use with no
  clue why. The panel says this in as many words.
- **WebDAV is two rows when both 80 and 443 answer**, because they are different endpoints and
  saving the wrong one gives a share that will not open. Port 443 sets `useHttps`.
- **A /24 only.** 254 addresses times the chosen ports is already a lot of sockets for a phone;
  accepting /16 would promise a 65k-host sweep that should not be attempted.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,223 passed** (+31 over 2,192) |
| `test/share_scan_test.dart` | 19 passed, all new — ports, stored selection, subnet parsing, sweep→hit mapping |
| `test/network_shares_test.dart` | 54 passed, 12 new: a hit is offered, a quiet subnet says so, only selected protocols are probed, the last cannot be turned off, the choice persists under the Kotlin key and is restored, bad input sweeps nothing, a concurrent scan is ignored, the prefill stops at the endpoint, HTTPS follows the port, progress is reported |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Three negative controls:**

| Control | Failure it produced |
|---|---|
| an empty stored selection honoured as "scan nothing" | `Expected: ['SMB','FTP','SFTP','NFS','WEBDAV'] / Actual: []` |
| the last protocol switchable off like any other | the selection emptied, leaving a scanner that probes nothing |
| the draft guesses a share path from the address | the prefill test failed on a path the probe cannot know |

**Not ported: SMB share-name enumeration.** Kotlin calls `enumerateSmbShares` and lists each export
as its own hit. That needs an SMB client Flutter does not have; a port probe is where this stops. The
consequence is one row per host rather than one per export, and the share path is typed rather than
chosen — stated in the panel rather than hidden.

**Coverage limit.** The sweep runs against a fake probe. Concurrency, socket timeouts and real
network behaviour are `sweepSubnet`'s, already covered by its own tests, but no test here dials a
real host.


### 37 — a session that could not say how old it was (closed)

Small, and worth recording for what it nearly became.

- `shell_session.dart` — `startedAt`, defaulting to now and **injectable**, because an age derived
  from `DateTime.now()` at construction is otherwise untestable without waiting real minutes.
- `domain/session_age.dart` — `formatSessionAge`.
- `shell_screen.dart` — the session chip gains a tooltip. The chip is too narrow for the age, and
  Kotlin shows it in a dropdown; a tooltip is the equivalent surface — secondary detail on demand,
  without spending width the session name needs.

**I nearly wrote a duplicate.** My first pass put `formatSessionAge` in `omni_components.dart`
beside the other formatters. An auto-import then revealed `lib/domain/session_age.dart`, which
already existed and which my earlier grep had missed. Reading it: `describeSessionAge` is about a
**detached** persistent session ("left running 4h ago"), and this one is about a **live attached**
session ("Started 2h 05m ago") — different input, different phrasing, genuinely not a duplicate. But
they are the same subject, so it was moved there rather than left among the metric formatters.

Two behaviours worth pinning:

- **A start in the future renders as `—`, not a negative age.** A clock adjustment during a
  long-lived session produces exactly that, and `Duration.inMinutes` would happily report it.
- **The second field is zero-padded** (`1h 09m`, `1d 09h`), matching the Kotlin, so the label does
  not change width every minute and drag the controls beside it around.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,229 passed** (+6 over 2,223) |
| `test/session_age_test.dart` | 9 passed, 6 new: "just now" under a minute, minutes/hours/days, zero padding, an exact hour keeps its minutes, no recorded start, a future start |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Two negative controls:**

| Control | Failure it produced |
|---|---|
| the clock-skew guard removed, as a plain difference would give | the future start rendered rather than `—` |
| unpadded interpolation, as `'${hours}h ${minutes}m'` would give | `Expected: '1h 09m' / Actual: '1h 9m'` |

**Coverage limit.** The tooltip is asserted only through the widget tree building without error; no
test opens it, because a tooltip needs a hover or long-press the surface sweep does not perform.


### 38 — a key bar full of keys that did nothing (closed)

Not missing code: `terminalKeyAllowedInReadOnly` existed, was correct, and was honoured. The gap was
that **the UI never reflected it**. Every cap rendered normally, and pressing one produced silence.

On a terminal that is worse than it sounds. A key that does nothing is indistinguishable from a
remote that has stopped responding, so the user's next move is to go looking for a network problem
that is not there.

`terminal_key_bar.dart` now swaps the whole bar for a label and PGUP/PGDN while read-only, matching
Kotlin's shape. The status row already said "READ ONLY"; what was missing was the controls agreeing
with it.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,231 passed** (+2 over 2,229) |
| `test/shell_screen_test.dart` | 34 passed; the old single read-only test became three: the bar collapses to the keys that work, page up still writes nothing to the remote, and leaving read-only restores the full bar |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**A test that could not fail, caught before it counted.** The loop asserting the inert keys are gone
was first written with a mangled interpolation — the key became the literal `shell.key.$gone`, which
never exists, so `findsNothing` passed unconditionally. `flutter analyze` flagged the unused
variable, which is the only reason it surfaced. Recorded here because this is the second time in
this migration that a green assertion turned out to be vacuous, and the lesson is the same one:
**a control that cannot fail is not evidence.**

**Two negative controls**, the second added specifically because the first did not exercise the loop:

| Control | Failure it produced |
|---|---|
| the original defect restored — read-only keeps the full bar | `Found 0 widgets with key 'shell.keyBar.readOnly'` |
| the bar present and correctly keyed, but with one ESC cap left on it | `Expected: no matching candidates / Actual: Found 1 widget with key 'shell.key.ESC'` — "ESC does nothing in read-only and must not look live" |


### 39 — a cron edit that changed the command you did not edit (closed)

Found by sweeping `MonitorScreen.kt`, where Flutter's parser is otherwise **ahead** of Kotlin's — it
understands `@daily` shorthands and carries a label in a trailing comment, neither of which Kotlin
has. The gap was one line inside it.

```dart
final rest = parts.sublist(5).join(' ');   // before
final rest = _remainderAfter(trimmed, 5);  // after
```

Splitting and rejoining looks equivalent to taking the remainder and is not: it normalises the
command's own spacing. Tabs become spaces, runs of spaces collapse, and anything inside quotes is
rewritten along with everything else.

**The blast radius is bounded, and that is worth stating precisely.** `renderCrontab` emits each
line's `raw`, so a crontab the user never edits is written back byte for byte — lines they did not
touch were never at risk. The damage was confined to a line passing through the editor, which is
also the line the user is least expecting to be altered behind their back.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,237 passed** (+6 over 2,231) |
| `test/cron_schedule_test.dart` | 38 passed, 6 new: quoted runs of spaces survive, a tab is not turned into a space, column-aligned schedule fields do not shift the command, an ordinary command is unchanged, the label still separates from an oddly spaced command, and an untouched line round-trips byte for byte |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Negative control** — the original `join(' ')` restored, reproducing the corruption exactly:

```
Expected: '/usr/bin/backup --name "My  Backup"'
  Actual: '/usr/bin/backup --name "My Backup"'
Expected: '/usr/bin/run\t--flag'
  Actual: '/usr/bin/run --flag'
```

**Rest of `MonitorScreen.kt`: verified present.** All six tabs (Overview, Logs, Processes, Services,
Cron, Quick Scripts), the schedule dialog, `cronPresetFor`, `cronSummary` and `isCronPartValid` are
all ported, the last three into `domain/cron_schedule.dart`.


### 40 — tapping an image opened it in the text editor (closed)

The missing feature is the smaller half. The *harmful* half is where the tap went instead: straight
into `openFileEditor`, which reads the file as UTF-8 and offers a Save. The binary warning from
defect 26 fires, so the user is warned — but being warned about a corruption you did not ask for is
not the same as the app doing the right thing.

- `domain/image_preview.dart` — the nine extensions, the 64 MB ceiling, and the preview state.
- `sftp_view_model.dart` — `openImagePreview` / `closeImagePreview`.
- `widgets/image_preview_overlay.dart` — full-screen, `InteractiveViewer` for Kotlin's
  `ZoomableImage` pinch-zoom.

Decisions worth recording:

- **Held in memory, never staged to disk.** Unlike `downloadToDevice`, a preview is a look rather
  than a copy — writing a remote image into the cache to display it would leave it there.
- **Not recorded as a transfer.** It calls the client directly rather than going through `download`,
  because a Transfers row per image glanced at would bury the transfers the user actually started.
  Kotlin does the same.
- **The ceiling is checked before the download, not after.** The point of a limit is to not spend
  the transfer.
- **A fetch that lands after the overlay closes is dropped**, so a slow image cannot reappear over
  whatever the user moved on to — and the bytes are released with it.
- **An unreported size (0) is not treated as huge.** The ceiling exists to stop a known-large
  download; refusing a file whose size the server merely did not report would block the common case
  on such a server.
- **A file whose bytes are not a decodable image says so**, rather than showing Flutter's default
  broken-image glyph, which gives the user nothing to act on.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,256 passed** (+19 over 2,237) |
| `test/image_preview_test.dart` | 12 passed, all new — the nine extensions, case, last-extension-wins, dotfiles, trailing dot, the ceiling, unreported sizes, the loading/failed/loaded states |
| `test/sftp_view_model_test.dart` | 133 passed, 7 new: fetched into memory, no transfer row, a non-image is not fetched, past the ceiling is refused before downloading, a failure is reported rather than left loading, closing drops the bytes, a late fetch does not reopen the overlay |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Two negative controls:**

| Control | Failure it produced |
|---|---|
| the token check removed, so a late fetch wins | the dismissed overlay reopened with the image |
| the size check moved after the download | the oversized file was fetched instead of refused |

**Coverage limit.** No test decodes a real image: the fake filesystem returns synthetic bytes, so
`Image.memory` and the pinch-zoom are exercised only by the surface sweep building the widget tree.
The `errorBuilder` path is reasoned about, not observed.

**Rest of the small blocks: verified present.** `FleetScreen.kt` (chart included — Flutter's even
pluralises "sample", which Kotlin does not), `CodeEditor.kt` (find/replace is in
`widgets/code_editor.dart`), `ScriptEditorDialog.kt`, `ComposeBuilder.kt` and `InfraScreen.kt` are
all ported.


### 41 — a lockout a force-stop could clear (closed)

Found by starting the **settings-effects** sweep: diffing every settings key each side writes, then
checking each is actually *consulted*. `pin_locked_until` appeared in Flutter's
`_deviceLocalSettingKeys` — the backup exclusion list — and **nowhere else**. Same shape as
`share_bookmarks_` before defect 32: the backup code knew a key nothing wrote.

The comment sitting directly above the write said it outright:

> *Persisted so force-stopping the app does not reset the throttle — otherwise the throttle is worth
> nothing against anyone willing to swipe it away.*

Only `pin_failed_attempts` was persisted. The deadline stayed in memory, so the comment described
behaviour the code did not have. Force-stopping is the easiest thing in the world to do to a phone
you have picked up, and it bought one PIN attempt per restart — which is not a throttle.

- `domain/app_pin.dart` — `restoredPinLockout`, clamping the restored deadline.
- `app_lock_controller.dart` — `_persistThrottle` writes **both halves**, because they are one fact
  between them; `load` restores the deadline rather than recomputing it.

**The deadline is wall-clock, and the wall clock moves.** A device whose clock jumps forward would
otherwise come back locked for what looks like years — bricked by a timezone change. A stored
deadline further out than one full lockout cannot have been written by this app against the current
clock, so it is treated as one full lockout from now. Moving the clock *backwards* shortens the wait,
and that is accepted: the alternative is monotonic time, which does not survive the reboot this
exists to cover.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,261 passed** (+5 over 2,256) |
| `test/app_lock_test.dart` | 57 passed, 5 new: the lockout survives a restart, a restart hands back no free attempt, an expired deadline does not lock a fresh start, a far-future deadline is clamped, unlocking clears the stored deadline |
| App-lock + surface sweep, API 35 | **3 passed** |

**A second test that never tested what it claimed.** The existing case was named *"repeated failures
throttle, and the throttle survives a restart"* and **never built a second controller** — there was
no restart in it. Renamed to what it does test, with real restart cases added beside it. That is the
third such find; the pattern is a test whose *name* asserts more than its body.

**Two negative controls:**

| Control | Failure it produced |
|---|---|
| the defect restored — `load` sets the deadline to 0 | the restarted controller was not throttled and accepted a PIN |
| the clamp removed, trusting the stored deadline | the year-long lockout was still in force after one full lockout had passed |

### 42 — `saveThemeOption` (removed from Kotlin)

`theme_dark` is written by one function that nothing calls, and read by nothing. The live preference
is `dark_mode` (`:10705`, `:11178`). Both the function and the key are dead — the same shape as
`CronJobsToolView` and the `first_run_complete` cluster in defect 20.

Removed from the parity worktree; `compileOpenSourceDebugKotlin` BUILD SUCCESSFUL. Correctly absent
from Flutter, which is why the key diff surfaced it.


### 43 — a memory setting that could not reclaim memory (closed)

The settings-effects sweep, continued: for each preference, is it *consulted*, not merely stored.
Six looked unconsumed; five were false positives (read directly from the repository by
`AppLockController`, or nested fields). The sixth was real.

`terminal_scrollback_limit` **is** honoured — at session construction. So it worked for new sessions
and did nothing for open ones, and `setScrollbackLimit` sat there with no caller: the unreachable-code
pattern again, this time on the setter rather than the feature.

That inversion is what makes it worth fixing. Someone lowering this setting is almost always doing it
**because the app is using too much memory right now** — and the one thing the change could not do
was release any. The only way to get the effect was to reconnect, which is the opposite of what they
were reaching for.

`shell_view_model.dart` now applies it in `_onAppChanged`, guarded by the last-applied value so the
emulators are walked only when the setting actually changed rather than on every unrelated
notification from `AppState`.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,263 passed** (+2 over 2,261) |
| `test/shell_view_model_test.dart` | 39 passed, 2 new: lowering the limit trims a running session's buffer, raising it discards nothing already held |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Negative control** — the call removed, reproducing the defect:

```
Expected: <500>
  Actual: <2477>
the buffer was trimmed to the new limit, not left as it was
```

**The other five candidates, checked rather than assumed:** `appLockEnabled`, `appLockTimeoutMs` and
`useBiometrics` are read by `AppLockController` straight from the repository rather than through
`AppPreferences`; `fallback` is a nested field name the grep matched on its own.

**Amended:** `accessibility` was *not* a false positive — it is genuinely unconsulted, and that is
defect 44. Four of the five candidates were correctly dismissed; this one was generalised from
`fallback` without being read.


### 44 — an accessibility setting that changed nothing (closed)

**A correction first.** Defect 43's sweep flagged `accessibility` as having no consumer, and I
dismissed it as "a nested field name the grep matched on its own". That was wrong — I checked
`fallback` and generalised to both without reading the second. It is a real, unconsulted preference,
and the ledger entry for 43 has been amended.

Two complete high-contrast colour schemes sit in `theme.dart` and nothing could reach them. The
setting persisted, round-tripped through backup, and did nothing — which for an accessibility
control is worse than not offering it: the user believes they have addressed a legibility problem.

- `theme.dart` — `themeModeFor`, pure, so the precedence is testable without pumping a tree.
- `main.dart` — the chain now consults `prefs.accessibility`.

**High contrast outranks AMOLED**, matching Kotlin. They both change dark mode and only one can win.
AMOLED is a preference about battery and taste; high contrast is an accessibility need, and it must
not be overridden by a black-background option the user set months earlier and forgot.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,268 passed** (+5 over 2,263) |
| `test/theme_mode_test.dart` | 5 passed, all new — the ordinary pair, AMOLED in dark only, high contrast in both brightnesses, high contrast over AMOLED, and high contrast in light ignoring AMOLED |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Negative control** — AMOLED checked first, which is how the original chain read:

```
Expected: OmniThemeMode:<OmniThemeMode.highContrastDark>
  Actual: OmniThemeMode:<OmniThemeMode.amoled>
```

**Settings verified at parity this pass**, read against both rather than assumed: `flag_secure`
(wired on Android, and honestly documented as unavailable on iOS rather than faked),
`hide_sensitive_info` (all five Kotlin masking sites, including the WOL target IP, plus a
`userAtHost` Kotlin lacks), `editor_highlight_limit`, `battery_saver_*` (same three effects — screen
wake off, polling stopped, tmux parked — and Flutter adds 5-point recovery hysteresis Kotlin lacks),
and the review prompt.

**The review prompt is a deliberate no-op, not a gap.** `ReviewPromptController` is fully ported and
tested, and is never constructed: the launcher would need a store SDK, and adding a dependency here
means new checksums across every resolved graph and both release SBOMs. A build without one never
prompts rather than pretending to. Recorded so a future sweep does not "fix" it.


### 45 — a themes axis the sweep did not actually cover (closed)

Defect 44 raised an obvious question: the sweep claims "every app theme", so why did it not catch an
entire theme being unreachable? Because it drove two booleans and never the third — five schemes
exist, three were painted.

`app_surface_stress_test.dart` now iterates all five, with AMOLED deliberately left **on** for the
high-contrast rows so precedence is proved end to end on a device rather than only in
`themeModeFor`'s unit tests.

**The interesting part is the guard, and it took three attempts to make honest.**

A loop that sets a theme and paints screens will pass whether or not the theme ever changed, so I
added an assertion that each variant reaches the tree. Getting it right meant being wrong twice:

1. **Uniqueness of the scaffold background.** Wrong on its own terms — `amoled` and
   `highContrastDark` are both pure black quite legitimately, so this would fail on a correct app.
2. **Waiting for a *new* background.** This recorded the theme that happened to be in force before
   the loop started, so variant one banked the wrong value and variant two "collided". The failure
   looked like a product bug and was not.
3. **Comparing against the expected scheme** — `omniTheme(themeModeFor(...))`'s background *and*
   primary, since background alone cannot separate amoled from high-contrast dark. This one is exact
   and cannot go vacuous.

**A correction.** Between attempts two and three I concluded the sweep's theme variation "had never
worked" and that every previous theme result was vacuous. **That was wrong.** The app was switching
themes correctly all along; my probe read `Theme.of` on *MaterialApp's own element*, which resolves
the ancestor fallback rather than the theme MaterialApp installs beneath itself — a constant, no
matter what the app rendered. Sampling from a descendant made it pass immediately. The real defect is
only the narrower one in the row above: two schemes never painted.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,268 passed**, unchanged — this defect is in the device suite |
| Surface sweep, API 35 | **1 passed**, five variants × two orientations × every screen and subtab; runtime 1:38, up from ~1:01 for three |
| Walkthrough, API 35 | **6 passed** |

**Negative control**: the probe's own first two versions were the control — version 2 failed on
`dark painted the same background as an earlier variant`, and version 3 initially failed on `light
never reached the widget tree` while the app was in fact correct. A guard that failed for two
distinct wrong reasons before passing is a guard that discriminates.


### 46 — a chart that clipped its own axis at large text (closed)

Adding a 200%-text pass to the surface sweep (the axis defect 45 opened) turned up **21 overflow
reports across 7 surfaces** on the first run. The largest, and the only one appearing on two
unrelated screens, was one shared widget.

`MetricLineChart` sized its axis labels with two constants: a 56px row height and a 28px gutter. The
**gutter** was the actual fault — at 200% text `100` no longer fits 28px, `Text` soft-wrapped it onto
three lines, and *that* overflowed the column vertically by 118px. The height looked like the
problem and was a symptom.

**Three attempts, and the first two were the wrong shape.** Scaling the height, then scaling height
and gutter together, each moved the size at which it broke rather than fixing it — 118px → 62px →
4px. Chasing a constant with a bigger constant is not a fix. The row is now an `IntrinsicHeight`:
the plot keeps its own height and grows with the text, the labels size themselves, and the row takes
whichever is taller, so **overflow is not expressible** at any scale.

I also had to fix my own test twice: it measured a `CustomPaint` that was not the plot, and gave the
chart the whole viewport so every size assertion read 600.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,263 passed** |
| `test/metric_line_chart_test.dart` | 4 passed, all new: default size unchanged, 200% does not overflow, the chart grows with the text, and at the largest *supported* size it stays a chart |
| Surface sweep, API 35 | overflow reports **21 → 14**, distinct surfaces **7 → 4**; both 118px sites gone |

**Negative control** — the fixed height and gutter restored:

```
Expected: null
  Actual: FlutterError:<A RenderFlex overflowed by 118 pixels on the bottom.>
```

That is the same figure the device sweep produced, which is what ties the unit test to the real
defect rather than to a plausible-looking reconstruction of it.

### 47 — large-text layouts, partly closed

Two of the seven surfaces defect 46 uncovered are now fixed, and getting there was messier than the
diff suggests.

- **Fleet summary bar, 188px.** A `Row` of stats that simply does not fit at 200%. My first fix
  wrapped it in a horizontal `SingleChildScrollView` — which **broke the screen entirely**: the row
  contains a `Spacer`, a `Spacer` needs a bounded width, and a scroll view gives it infinity. The
  host suite caught it immediately (20 fleet tests red, `RenderBox was not laid out`). It is now a
  `Wrap`: the stats reflow onto a second line and nothing is lost, which matters because the stat
  that would have been pushed off is the online count.
- **Tools hub grid, 17px.** `childAspectRatio: 1.6` is a fixed tile height, so at 200% the tool name
  no longer fitted beside its icon. The ratio now divides by the text scale, so tiles grow instead.
- **Fleet tab chips** are horizontally scrollable, matching the SFTP and Infra tab bars.

**A test I had to withdraw.** I wrote a widget test asserting the hub does not overflow at 200%. The
negative control passed — `flutter test`'s 800x600 default is wider than a phone, so the grid fits at
any scale and the assertion could not fail. Constraining the view to a phone made it fail *with the
fix applied*, on a different overflow the device never reported: an invented viewport reproduces
constraints the real screen does not have. So the file now pins only the property the fix relies on —
tiles that grow with the text — and **the device sweep is the authority on overflow**. That is stated
in the test's own header so the next person does not re-add it.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,265 passed** |
| `test/large_text_layout_test.dart` | 2 passed, new |
| Surface sweep, API 35 | overflow reports **14 → 10**; the 188px and 17px sites gone |

**A shared helper, and a change I had to take back.**

Eight screens lay their tab strips and chip rows out at a constant height so they do not jitter as
contents change. That constant clips at large text: a chip whose label doubles needs roughly double
the height. `scaledBarHeight` (in `omni_components.dart`) grows a bar with the text, capped at 2x,
and is applied to the SFTP and Infra strips.

**It made Monitor worse, and I reverted it there.** Monitor's body is
`Column(selector, tabs, Expanded)`; in landscape at 200% the chrome already exceeds the viewport, so
a *taller* bar took the overflow from **44px to 84px**. The device sweep is what caught it — the
change looked obviously right and was not. Monitor's strip is back to a fixed 40 with a comment
saying why, and the real fix (chrome that tolerates a short viewport) is defect 48.

| Check | Result |
|---|---|
| `flutter test` (whole host suite) | **2,269 passed** |
| `test/large_text_layout_test.dart` | 6 passed, 4 new for `scaledBarHeight`: default untouched, grows with text, capped at 2x, and never *shrinks* below the base — 80% is offered in Settings, and a chip row shorter than its touch target is its own defect |
| Surface sweep, API 35 | 5 surfaces still over; Monitor confirmed back at 44px after the revert, not 84px |

**Quick Scripts, 37px, closed.** Its tab strip was a plain `Row` of two chips — "Quick scripts" and
"Fleet commands" do not fit a phone at 200%, and a tab the user cannot reach is a screen they cannot
open. Now horizontally scrollable, as the SFTP and Infra strips are. Safe as a scroll view here,
unlike Fleet's summary bar: this row has no `Spacer` needing a bounded width, which is the
distinction that broke the earlier attempt.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,269 passed** |
| Surface sweep, API 35 | 5 surfaces → **4**; Quick Scripts clear |

**Still open — three sites:**

| Overflow | Where |
|---|---|
| 44px bottom | Monitor, and Monitor → Cron (landscape) — defect 48 |
| 25px bottom | Fleet → Broadcast (landscape) |
| 0.8px right | Hosts (portrait) |

**A diagnostic attempt that did not work, recorded so it is not repeated.** The sweep reports
"overflowed by 44 pixels" with no file or line, which is why two rounds of this work went on guessing
which `Column` was meant. I added a `FlutterError.onError` probe to capture the error-causing
widget's location — it captured nothing. `flutter_test`'s binding installs its own handler and the
framework's "relevant error-causing widget" block is only printed when an error goes *uncaught*,
which is exactly what `takeException` prevents. The probe is left in place (it is harmless and costs
nothing) but it is **not** a working diagnostic, and the remaining three sites still have to be found
by reading the code.

### 48 — Monitor's unreadable-crontab notice could not be read (closed)

The last of the seven, and the one that took six hypotheses. Worth reading as a record of how the
search narrowed, because five of them were wrong and each wrong turn cut the space.

| # | Hypothesis | Result |
|---|---|---|
| 1 | The tab strip's fixed 40px height | **Wrong, and harmful** — 44px became 84px. Reverted. |
| 2 | The unbounded error banner | No change. The `maxLines: 3` cap was kept anyway: a banner that can take half a landscape screen to report a connection failure is its own defect. |
| 3 | Chrome that does not yield on a short screen | **Partial** — 44px → 34px. Kept. |
| 4 | Chrome not *capped*, only compacted | No change **to the pixel**, which proved the fault was not in Monitor's `Column` at all. Reverted: complexity that buys nothing is worse than none. |
| 5 | The app scaffold | Wrong. Written into the ledger as the next lead, then withdrawn the following turn. |
| 6 | A bounded-height child shared by the two failing tabs | **Right.** |

**What hid it.** `_expectSurface` calls `takeException`, which takes **one** error per surface — so
the root `monitor` label consumed the report and the subtab that raised it never showed. Skipping
that one label for a single diagnostic run made the real labels appear: `monitor/overview` and
`monitor/cron`. That also explained the identical 34px on two unrelated tab bodies — it was never two
faults, it was one Cron overflow being reported twice under different labels.

**The fault.** The sweep's fixture host refuses on port 1, so Cron renders its *unreadable crontab*
state: `Center(Padding(Column(mainAxisSize: min)))` inside an `Expanded`. The height is bounded, and
the content is not the app's to choose — the host's refusal is quoted verbatim. At 200% text in
landscape the notice plus the quoted error exceeded the pane by 34px. **An explanation the user
cannot finish reading is not an explanation**, which is what made this worth chasing rather than
suppressing.

Now a `SingleChildScrollView`: the notice sizes naturally and scrolls when it must, so no host
message can overflow it however long.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,269 passed** |
| `test/monitor_screen_test.dart` | 39 passed, unchanged |
| Surface sweep, API 35 | **green — 0 overflow reports**, first time since the 200% pass was added |
| Walkthrough, API 35 | 6 passed |

**The axis, end to end: 21 overflow reports across 7 surfaces → 0.** Closed by defects 46 (metric
chart, 118px on two screens), 47 (Fleet summary 188px, Tools grid 17px, Quick Scripts 37px), 49
(Hosts status line 0.8px), 50 (Fleet Broadcast 25px) and this one.

### 49 — the Hosts card's status line could not give way (closed)

The 0.8px overflow, and the sub-pixel figure is the clue: something was *fractionally* too wide
rather than badly laid out.

The host card's footer is already a `Wrap`, which was the right structure. Inside it, the status line
is a `Row(mainAxisSize: MainAxisSize.min)` around an icon and a `Text` — and `min` asks for the
text's full width. At 200% "online · ssh not verified yet" is a hair wider than the line the `Wrap`
can offer, and nothing inside the row was allowed to shrink.

The `Text` is now `Flexible` with an ellipsis, so the row gives way. The status still reads: the part
that is elided is the tail of an explanatory clause, not the state itself.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,269 passed** |
| `test/servers_screen_test.dart` | 12 passed, unchanged |
| Surface sweep, API 35 | Hosts clear; 4 surfaces → **3** |

### 50 — Fleet → Broadcast could not fit its own form (closed)

Same shape as Monitor and a cleaner fix, because the content below the form is a list rather than a
whole tab: `Column([...form..., Expanded(results)])`, where the form alone is taller than a landscape
phone at 200% text. `Expanded` was handed nothing and the column overflowed by 25px.

The tab is now a `SingleChildScrollView` inside a `LayoutBuilder`, and the results pane is a
`SizedBox` sized to **35% of the available height with a 120px floor** rather than `Expanded`. The
floor matters: the list scrolls internally, and a pane too short to show one result is worse than a
form the user has to scroll to.

Structural rather than a bigger constant, for the reason the chart taught in defect 46 — the form's
height depends on the text size, the number of target chips and whether a preset row is showing, so
any fixed allowance is a guess that breaks at some combination.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,269 passed** |
| `test/fleet_screen_test.dart` | 23 passed, unchanged — the results list keeps its key and its behaviour |
| Surface sweep, API 35 | Broadcast clear; 3 surfaces → **1** |

**One site remains** — Monitor and its Cron tab, 34px, landscape only (defect 48).


### 51 — a backup that lifted the host limit (closed)

Found by sweeping the **unlicensed** state, the next axis after large text. Kotlin gates four things
on the "Unlock OmniTerm" entitlement; Flutter had three of them.

The same shape as the SFTP upload defect and the sudo-search one: **a guard present at one entry
point and absent at another.** `hostLimitReached` is checked when adding a host by hand, and the
restore path writes host rows without consulting it. Kotlin's own comment on ad-hoc connections says
exactly why this matters — a route that writes no saved row, or writes many at once, is an unmetered
way around a limit that counts saved rows.

- `domain/backup_selection.dart` — `restoreHostCap` and `defaultRestoreHostIds`, pure.
- `backup_screen.dart` — the dialog takes the cap, starts within it, says so **before** the boxes go
  grey rather than after a tap does nothing, and disables only the boxes that would go over so a
  chosen host can still be swapped for another.

**The default selection is the file's first hosts**, not an arbitrary subset: a backup lists hosts in
the order they were saved, so the oldest survive a capped restore. Choosing by anything else would be
choosing *for* the user, who can change the selection anyway.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,276 passed** (+7 over 2,269) |
| `test/backup_selection_test.dart` | 33 passed, 7 new: no cap when unlocked, capped when limited, everything selected with no cap, a small backup unaffected, a large one takes the file's first, a zero/negative cap selects nothing rather than throwing, an empty backup stays empty |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Negative control** — the cap ignored, as before:

```
Expected: Set:[5]
  Actual: Set:[5, 6, 7]
```

**Also found, not yet ported: `reconcileHostLimit`.** Kotlin handles a *standing* violation — an
install that already holds more hosts than its entitlement allows, after a restore on an older build
or after an entitlement lapses (`ui/AppViewModel.kt:967`). It sets a reconciliation flag and a reason
so the UI can require the user to choose which hosts to keep. Flutter has no equivalent. This fix
closes the route that creates the condition; it does not clean up an install already in it.

### 52 — the other half of the host limit (closed in the view model)

Defect 51 closed the route that *creates* an over-limit install. This is the standing violation:
hosts already saved when the entitlement does not allow them. Blocking additions does nothing about
those, and Kotlin treats it as important enough to warrant a **non-dismissible** dialog.

- `domain/host_limit.dart` — `hostLimitExceeded`, `isValidHostKeepSelection`, and the two reason
  strings.
- `servers_view_model.dart` — `hostLimitExceededNow` and `reconcileHostLimit`.

**Two reasons, not one.** A user whose unlock has lapsed is being told something changed; a user who
has always been on the free tier is being told what it allows. Kotlin distinguishes them and so does
this, because the same sentence would be wrong for one of them.

**A selection that is not exactly the limit is refused, not approximated.** This deletes hosts. A
flow that keeps fewer than asked would delete hosts nobody chose to delete; one that keeps more would
leave the install still over its limit, having destroyed data for nothing. Declining is the only
answer that is not silently wrong.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,291 passed** (+15 over 2,276) |
| `test/host_limit_test.dart` | 10 passed, all new — unlimited never reconciles, at-the-limit is not over, an empty install is not asked an unanswerable question, exactly-the-limit is the only legal selection, and the noun agrees with the number |
| `test/servers_view_model_test.dart` | 30 passed, 5 new: an over-limit install is flagged, an unlocked one never is, keeping one deletes the rest, and both an over-limit and an empty selection delete nothing |

**Negative control** — the selection check removed, so any selection proceeds:

```
Expected: <0>
  Actual: <2>
```

An empty "keep" set wiped both hosts, which is exactly the failure the guard exists to prevent.

**The dialog landed in the following turn.** `widgets/host_limit_gate.dart`, mounted in the app
scaffold's existing overlay `Stack` so it covers every screen — the install is in a state no screen
should be usable from until it is resolved. It renders nothing at all when there is no violation,
which is every unlocked install and the whole source-available build.

**Three tests I wrote first were vacuous, and the negative control is what showed it.** The gate's
branches cannot be reached from the host suite: `isPlayStoreDistribution` is a compile-time constant
and the tests build source-available, so the widget returns on its early exit no matter what the
entitlement says. Three green tests, none able to fail.

The fix was to move the decision out of the widget: `shouldReconcileHostLimit` takes the build flag,
the license state and the host count as plain arguments, so every branch is reachable. Each guard was
then removed in turn to prove it discriminates — dropping the loading check failed 3 tests, the
unlocked check 5, the build check 6. The widget keeps one honest assertion: that it stays out of the
source-available build even with the entitlement claiming otherwise and hosts over the limit.

**"Your unlock ended" versus "this build is free" is detected in memory**, by remembering whether an
unlocked state has been seen while the gate is alive. Kotlin does the same
(`updateLicenseEntitlement`'s `wasUnlimited`), so an install that starts already lapsed gets the
plainer wording in both — a limitation the two share rather than one introduced here.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,298 passed** (+7 over 2,291) |
| `test/host_limit_test.dart` | 16 passed, 6 new for `shouldReconcileHostLimit` |
| `test/host_limit_gate_test.dart` | 1 passed, new |
| Surface sweep + walkthrough, API 35 | **7 passed** — the gate adds a child to the scaffold's overlay stack on every screen, so the sweep is the check that it costs nothing when absent |

### 53 — an empty pane that would not say why (closed)

The empty/loading axis, opened after the entitlement one. Same family as the Cron defect that ended
the large-text work: **a pane that is blank for two different reasons and looks identical in both.**

Three states now, where there was one:

- **First load** — a centred spinner and "Reading the process list…". A 2px bar above an empty list
  is indistinguishable from a host with nothing running, which is the wrong thing to tell someone
  who is waiting.
- **Refresh** — the thin bar, unchanged, over rows already on screen.
- **Loaded and empty** — says the read came back empty and may not be understood. Every host runs
  *something*, so an empty list after a successful read is the parse failing, not the machine being
  idle. "No processes" would be a confident false statement about someone's server.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,300 passed** (+2 over 2,298) |
| `test/monitor_screen_test.dart` | 41 passed, 2 new: a first load does not claim there are none, and an empty list blames the read rather than the host |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Negative control** — the empty branch removed:

```
Expected: exactly one matching candidate
  Actual: Found 0 widgets with key 'monitor.processes.empty'
```

**An existing test had to be re-pointed, and that is worth noting.** "Every tab is reachable and
renders" probed for `monitor.processes.list`, which is now legitimately absent when the fixture host
returns nothing. It probes the sort chip instead — present in every state — because the test is about
the tab rendering, not about which of its three states it happens to be in. Changing the assertion to
match new behaviour is right here; changing it to keep a test green would not have been.

**Checked and already correct:** Logs and Services both carry `unsupported` flags that distinguish
"this host has no such source" from "nothing came back", which is the same distinction under a
different name.

### 54 — the same empty-versus-loading defect, one screen over (closed)

Defect 53 on Monitor, found again on Infra by carrying the same question to the next screen. That is
the value of naming a defect *class* rather than a bug: `if (loading) LinearProgressIndicator` above
a pane whose empty state makes a claim about the host.

Infra was otherwise ahead — it already distinguished "no container runtime installed" from "none
found", and already had a `_RuntimeError` branch showing the failure verbatim. What it lacked was the
first-load case, so "No compose stacks on this host" appeared while the probe was still in flight.

- `infra_view_model.dart` — `hasAnyRuntimeData`, true once any probe result is in hand.
- `infra_screen.dart` — a centred spinner for a first load, the thin bar only over results already
  on screen, and the spinner placed **ahead of the error branch** as Kotlin orders it: a refresh in
  flight must not keep showing the previous attempt's failure as though it were current.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,302 passed** (+2 over 2,300) |
| `test/infra_screen_test.dart` / `infra_view_model_test.dart` | 44 passed, 2 new |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**A widget test I wrote and withdrew.** I tried to assert the spinner by gating the fake transport
mid-probe. The harness settles before the gate takes effect, so the assertion found nothing — and
making it pass would have meant inventing a pump sequence the real screen never performs. The
property the branch depends on (`hasAnyRuntimeData`) is asserted on the view model instead, the
settled case is asserted through the widget, and the rendering is covered by the surface sweep. Same
conclusion as the tools-hub test in defect 47: **a widget test that has to invent its own timing is
testing the harness.**

### The empty/loading axis, swept (no further defects)

Defects 53 and 54 fixed the two screens that had the problem. This pass carried the same question to
every other surface that can render an empty pane, and found none — recorded so the axis is not
re-walked.

The question: **does an empty pane make a claim about the remote host that has not been checked
yet?** Three shapes turn out to be safe, and knowing which is why the sweep terminates rather than
going on forever:

| Surface | Why it is not at risk |
|---|---|
| Fleet → Dashboard | "No hosts yet" comes from the saved-host table, not a probe. A local database is authoritative — the statement is true the moment it can be made. |
| Alerts — active, rules, history | All three are drift streams over local tables. Same reasoning. |
| Quick Scripts | Saved rows, local. |
| SFTP browser | Already branches on the in-flight listing; pinned by "a listing still in flight is not called an empty directory". |
| Network → scan | Already branches on `vm.scanning`. |
| Shell → resumable sessions | Renders **nothing** when the list is empty rather than an empty state. Absence is not a claim, so there is nothing to get wrong. |

The two that failed — Monitor → Processes and Infra — were both **remote probes rendered through a
shared `if (loading) LinearProgressIndicator`**, which is the shape to look for if this recurs on a
new screen.

No code changed in this pass. `flutter analyze --fatal-infos` clean and **2,302 passed**, confirming
the tree is as defects 53 and 54 left it.


### 55 — toggles that did nothing on iOS (closed)

The Android-vs-iOS axis. **No Kotlin counterpart** — that app is Android-only, so this is not a
porting gap but the class of defect this migration keeps turning up: a control that looks live and
is not. Same as the read-only key bar (38) and the inert high-contrast theme (44), except the app is
telling the user something untrue about their own device.

Both are shown **disabled with a reason**, not hidden. A row that vanishes reads as the app having
forgotten the setting, and the value is still carried in backups taken on Android where it does work.

`domain/platform_settings.dart` holds the rule so it is testable: `Platform.isIOS` cannot be varied
in a host test, and a widget test would assert whatever the test host happens to be.

**The default matters more than the entries.** An unrecognised key is *available*, so a setting added
later is not silently dead on iOS because nobody thought to list it here. The negative control was a
catch-all `_ => 'Not available on iOS.'`, which is the obvious way to write this and the wrong one:

```
Expected: true
  Actual: <false>
```

**What was checked and found already correct**, since the point of an axis sweep is knowing where it
stops:

| Platform branch | State |
|---|---|
| `ping` / `traceroute` binaries | iOS returns an empty list with a comment on why raw ICMP needs an entitlement |
| SMB client | Android uses the native bridge, everything else a real 221-line Dart client — iOS browses shares |
| `SessionService` | Documents that iOS has no foreground-service equivalent rather than failing quietly |
| `PlatformPermissions` | The Android-only bridge is absent on iOS, and every fallback is chosen so the background-permission prompt never appears there |
| `HomeWidgetSync` | Takes an iOS app-group id alongside the Android provider |
| `ScreenSecurityBridge` | Android applies `FLAG_SECURE`; the Swift side says plainly there is no iOS API rather than pretending |

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,307 passed** (+5 over 2,302) |
| `test/platform_settings_test.dart` | 5 passed, all new |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Coverage limit, and it is a real one.** These gates run on Android, where both settings are
available — so the device evidence confirms nothing regressed there, and confirms nothing about the
iOS path. The rule is unit-tested with `isIOS` as an argument, which is as close as this repository
can get without an iOS runner.

### 56 — a version stamp nobody checked (closed)

The restore axis. `BackupPayload.version` is stamped into every document as `'v'`, and nothing on the
import path ever looked at it: `inspectBackup` decoded the JSON, confirmed it was a map, and started
pulling sections out.

**Not a hypothetical.** `decode` already carries a v1→v2 migration for the selection format, which is
precisely the kind of change that misreads silently when the version is ignored. A v3 file would have
been offered for restore, accepted, and written — with any section whose shape had moved read as
though it had not.

- `backup_payload.dart` — `incompatibleVersionMessage`.
- `backup_view_model.dart` — checked **before anything is parsed out of the document**, because
  refusing a file whole is honest and reading half an unfamiliar shape is not.

Three decisions:

- **Older is fine, newer is refused.** Migrating forward is the reason the migration code exists;
  guessing at a shape that did not exist yet is how a restore quietly loses data it appeared to
  accept.
- **A missing version is v1**, not an error. It predates the field, and that shape is one this build
  already reads.
- **A non-numeric version is refused rather than coerced.** `int.tryParse` returning null means the
  file is not what it claims to be, and defaulting it to "probably fine" is the same mistake in a
  smaller place. A *numeric string* is accepted, though — quoting is a formatting difference, not a
  shape one.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,314 passed** (+7 over 2,307) |
| `test/backup_payload_test.dart` | 40 passed, 7 new: current and older read, absent treated as v1, newer refused with what to do, non-numeric refused, numeric string accepted, and one end-to-end through `inspectBackup` |
| Surface sweep + walkthrough, API 35 | **7 passed** |

**Negative control** — the check removed, which is the defect verbatim:

```
Expected: null
  Actual: <Instance of 'BackupInspection'>
nothing may be offered for restore
```

A v3 document was accepted and offered for restore, which is exactly what shipped before this.

### 57 — no test ever saw a fresh install (closed)

The last axis on the handoff list, and it turned out to be a **coverage** gap rather than a product
one. The surface sweep inserts a fixture host before it starts; the walkthrough inherits it, because
integration tests in one `flutter test` invocation share a single app install. So the app had never
been walked end to end with an empty database — precisely the state a new user is in, and precisely
where defects 53 and 54 lived.

`app_walkthrough_test.dart` now opens with a fresh-install case: it **clears the host table itself**,
asserts the table is empty, then visits every primary destination.

**The precondition is created, not assumed.** Asserting emptiness alone would make this test pass or
fail on the order the files happen to run in, which is not something a suite should depend on.

**Four mistakes of mine, all caught by the device:**

1. Iterated `Screen.values`, which includes Tools sub-screens that have no nav-bar entry — `goTo`
   failed on the first one.
2. Put the fixture cleanup in the sweep's `addTearDown`, where drift's isolate channel has already
   closed. Every query from there throws.
3. Moved it to the end of the sweep's body — same failure, the channel closes earlier than that.
4. Removed the wrong copy when reverting, leaving the broken teardown in place for another run.

The sweep now documents in a comment that it deliberately does **not** clean up, and why, so the next
attempt does not repeat (2) and (3).

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,314 passed**, unchanged — this defect lives in the device suites |
| Surface sweep + walkthrough, API 35 | **8 passed**, up from 7 |

**Also verified on this axis, no defect found:** preset flags (`homelab_presets`, `alert_presets`,
`fleet_presets`) default to off in both apps — absent means false either side. And the local-network
permission prompt is deferred until a host exists or a network screen is opened, matching Kotlin's
rule at `ui/AppUi.kt:1174` exactly, so a fresh install is not met with a permission dialog at launch.

### 58 — no way out of a crash loop (closed)

Found by working the untriaged `strings.xml` queue — the last enumerated backlog. The `crash_*`
cluster turned out to name a whole feature: Kotlin's startup recovery screen.

Flutter already **recorded** crashes and listed them under About, which is the easy half. The half it
lacked was the one that matters when it matters: `main()` ran `runApp` unguarded, so an exception
opening the database or restoring settings killed the app before any UI existed. Every relaunch did
the same. On a device the only escape is clearing app data — which throws away every saved host, key
and setting to get past a problem the user cannot see.

- `domain/startup_recovery.dart` — the gate: none, offer recovery, or stale.
- `crash_log.dart` — `CrashEntry.startup`, so a crash *during use* is still recorded and reported
  without blocking the next launch. The app plainly does start in that case, and refusing to would
  strand the user over something they had already carried on past.
- `widgets/startup_recovery_app.dart` — its own `MaterialApp`, because it runs when the real one
  could not be built and must not depend on providers, a database or a theme controller.

Decisions worth recording:

- **Seven days, matching Kotlin.** A report from months ago is not evidence about this launch, and a
  recovery screen that will not go away is its own broken app.
- **A future timestamp offers recovery rather than being discarded.** A device whose clock moved
  backwards makes a real crash look like it has not happened yet; erring toward offering a way out
  is the safe direction when the alternative is relaunching into the crash.
- **The screen says the data is untouched before the button is pressed.** "Clear" next to a crash
  report could as easily mean wiping the app's data, which is exactly what the user is afraid of at
  that moment.
- **It says "Clear and close" rather than pretending to restart.** A Flutter app cannot restart its
  own process, so claiming otherwise would be a button that does not do what it says.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,324 passed** (+10 over 2,314) |
| `test/startup_recovery_test.dart` | 7 passed, all new |
| `test/startup_recovery_app_test.dart` | 3 passed, all new — including that it builds with no providers at all |
| Surface sweep + walkthrough, API 35 | **8 passed** |

**Two negative controls:**

| Control | Failure it produced |
|---|---|
| the TTL removed, so any recorded crash blocks launch forever | 6 of 7 gate tests failed |
| a future timestamp treated as stale | `Expected: offerRecovery / Actual: stale` |

**Coverage limit.** No test forces a real startup crash on a device — doing so means shipping a
build that deliberately throws. The gate and the screen are covered separately; the wiring between
them in `main()` is reasoned about, not observed.

### 59 — a shortcut that worked, except from cold (closed)

The `shortcut_*` cluster, following the lesson defect 58 left: read a group of related strings as a
*feature*. Two defects, one shape.

**The lookup.** `open_share` already queried the repository; `connect_server` and `open_split` read
`_app.servers`. That list is populated by a drift stream, and a launcher shortcut is precisely the
case where the app is starting from nothing — so on a cold start the list is empty, every host looks
deleted, and the shortcut lands the user on the host list instead of connecting. Tapping it again
from a warm app works, which is the worst kind of bug: intermittent by a mechanism the user cannot
see. Kotlin's own comment says it outright — *"on a cold start the flow may not have emitted yet, and
a stale shortcut must produce feedback instead of a silent no-op."*

**The silence.** When a target really is gone, all three cases navigated to the list and said
nothing. Landing somewhere unexpected with no explanation reads as the shortcut having done nothing,
which invites the user to try it again. There is now a message, matching Kotlin's toast.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,325 passed** (+1 over 2,324) |
| `test/external_action_guard_test.dart` | 4 passed, 1 new |
| Surface sweep + walkthrough, API 35 | **8 passed** |

**What the new test actually pins, and what it does not.** The dispatch lives in `main.dart`'s State
and is not reachable from a unit test without a refactor that would be larger than the fix. What is
testable is the fix's *premise*: a host inserted into the repository is findable there while
`AppState.servers` is still empty. The test asserts exactly that and nothing more — it does not prove
the shortcut path now works, and saying otherwise would be claiming coverage this does not have.

### 60 — "add a host" on a home screen showing twelve of them (closed)

The `widget_*` cluster. Defects 53 and 54 again — an error rendered as "you have nothing" — but on
the worst possible surface: a home-screen widget has no retry button, no error banner and nowhere to
look. The user is simply told something false about their own fleet.

Three states now, where there were two:

- **rows** — a payload that read cleanly and has hosts.
- **empty** — read cleanly, genuinely no hosts.
- **unavailable** — could not be parsed, the last publish failed, or nothing has ever been
  published.

**"Never published" counts as unavailable, not empty.** A widget added before the app has run once
has no idea whether the user has hosts, and guessing "none" puts a false statement somewhere they
cannot correct it.

**The status is written `failed` first and flipped to `ok` last**, so a sync that dies part-way
leaves the widget saying it could not load rather than presenting half a fleet as current.

**The decision lives in Dart, and that was the point.** The receiver is Android-native Kotlin inside
the Flutter app, and that project has **no test source set and no JUnit dependency** — adding one is
a Gradle dependency change, which this repository treats as a security boundary (new checksums across
every resolved graph and both release SBOMs). So `domain/widget_payload.dart` holds the rule where it
can be tested, and `OmniTermWidgetReceiver.kt` only renders it.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,333 passed** (+8 over 2,325) |
| `test/widget_payload_test.dart` | 8 passed, all new |
| Surface sweep + walkthrough, API 35 | **8 passed** — which also compiles the changed receiver, since the device build includes the native sources |

**Negative control** — the guard removed, so an unreadable payload falls through to empty again:
**9 of 9 assertions failed.**

**Coverage limit, and it is the honest one.** No test renders the widget. The rule is unit-tested,
the receiver is compiled by the device build, and the wiring between them — that `payload_status`
is read under the key Dart writes — is checked by eye. A widget test would need the native test
infrastructure this project deliberately does not have.

### 61 — a consent prompt that only argued one side (closed)

The `local_network_*` cluster, and the last of the string queue. Everything else in it matched — the
title, both button labels, and the deferral rule that holds the prompt back until a host exists or a
network screen is opened (checked in defect 55). One sentence was missing, and it was the one that
tells the user what saying no costs.

That matters more here than the length of the diff suggests. The prompt appears once, it is
dismissed with "Not now", and getting back to it means finding Android's own settings — so a user
who declines without understanding the trade-off has made a decision they will not revisit and may
not connect to the symptoms later.

**The copy moved into `domain/permission_copy.dart`**, because the dialog cannot be reached from the
host suite: the permission probes fall back to "not required" without a platform channel, so nothing
renders and a widget test would pass while asserting nothing.

**Properties, not a transcript.** The tests assert that the copy says why the permission is wanted,
says what declining costs, *and does not overstate it* — a prompt implying the app stops working
would be pressuring the user into a permission they may not want to give. Asserting the exact
wording would break on every edit while catching nothing that matters.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,336 passed** (+3 over 2,333) |
| `test/permission_copy_test.dart` | 3 passed, all new |
| Surface sweep + walkthrough, API 35 | **8 passed** |

**Negative control** — the sentence removed again: **4 of 4 assertions failed.**

**The string queue is now worked through.** All four clusters from `missing_xml.json` have been
adjudicated: `crash_*` (58), `shortcut_*` (59), `widget_*` (60) and `local_network_*` (61). Three of
the four named a missing *feature* rather than missing copy, which is the pattern worth carrying
into any future string diff — a cluster of related strings is a feature the port did not finish.

### 66 — Back skipped the file editor's discard prompt (closed)

This is the item defect 65 left recorded as **unverified**: I had inferred that Flutter's editor was
"a sheet the platform already pops, so it is likely parity by construction". The inference was right
about the mechanism and wrong about the consequence — the platform popping it *is* the bug, because
popping is exactly what bypasses the guard.

`openFileEditor` presents `_FileEditorSheet` via `showModalBottomSheet`. Its ✕ calls `_close`, which
asks before discarding unsaved edits. The system Back button pops the modal route directly and never
reaches `_close`. So the only path that could lose work was the only path that did not ask.

Kotlin has no such split: `CodeEditor` installs `BackHandler(enabled = true) { onClose() }`
(`ui/CodeEditor.kt:398`), and the SFTP host passes `attemptDismiss`, which runs the same dirty check
as the toolbar's close. One guard, both entrances.

**The fix.** A `PopScope(canPop: false)` inside the sheet routes Back through `_close`. `_close`
ends in `Navigator.pop()`, which is unconditional and so still closes once the user confirms.

**A second defect found in the same guard.** The condition was `_dirty && _editing`. The pencil can
be switched back off with unsaved edits still in the buffer, and in that state the editor closed
without asking. Kotlin gates on the buffer alone — `dirty = buffer != file.content`
(`ui/SftpScreen.kt:3095`) — so this is now `_dirty`.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,364 passed** (+3) |
| `sftp_screen_test.dart` | 56 (+3) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

The tests deliver a real Back through `tester.binding.handlePopRoute()` rather than calling `_close`
directly, since the whole defect was that the two entrances differed.

**Negative controls.** Each mutation fails exactly the tests that name its behaviour:

| Mutation | Result |
|---|---|
| `canPop: true` — sheet pops on Back unguarded | the Back-asks test and the pencil test fail |
| `_dirty && _editing` — guard requires edit mode again | the pencil test alone fails |

**Back axis complete.** All six Kotlin `BackHandler`s now have a Flutter counterpart: SFTP browser,
share browser and image preview (63), compose builder (65), file editor (66), and the app-level
handler that was ported originally. The lesson worth carrying is the one this entry opens with —
"likely parity by construction" was a guess dressed as a conclusion, and writing it down as
unverified is what made it get checked instead of quietly inherited.

### 65 — Back on the Builder tab neither asked nor escaped (closed)

The last item left open by defects 63 and 64. With the draft now preserved (64), Back no longer
destroyed work by navigating away — but it still did the wrong thing in two ways, both of which
Kotlin had already found and commented.

**The confirmation.** `attemptClearOrExit` asks "Discard changes?" whenever the draft is dirty and
only clears on confirmation. Flutter had no such prompt.

**The escape.** Kotlin's comment at `ui/ComposeBuilder.kt:1248` is worth quoting, because it records
a bug rather than a design:

> Back must end in a VISIBLE navigation, never in state mutation alone. Clearing the draft leaves
> the user on the Builder tab, and this composable recreates an empty draft the moment it sees
> `activeComposeDraft == null` … A handler that only cleared therefore made the tab inescapable.

Flutter reaches the identical trap from the other direction: after defect 64 the tab restores from
the memento on mount, so a handler that only cleared would also rebuild and appear to do nothing.
`_exitToStacks` clears *and* switches to Stacks, which unmounts the handler, so a second Back
reaches app navigation and leaves the screen.

**What "dirty" means, and what it deliberately does not.** `composeDraftIsDirty` compares the
rendered YAML against the imported stack's original text, or against an empty draft's rendering when
nothing was imported — Kotlin's `isDirty` (`ui/ComposeBuilder.kt:1222`), including its exact-string
comparison. Two consequences, both inherited rather than chosen:

* **The project and top-level name fields do not make a draft dirty.** They are deploy parameters
  (`-p`), not document content, so they never reach the YAML. My first test edited the project name
  and saw no prompt; the code was right and the test was wrong.
* **A trailing-whitespace difference counts as dirty.** That errs towards asking before discarding,
  which is the safe direction for a prompt whose other branch destroys work.

Kotlin also disables its handler while a full-screen code editor is open, to stop two handlers
racing. Flutter's raw editor is inline on the tab rather than an overlay, so there is no second
handler and no condition to port; this is noted at the call site so a future reader does not think
it was missed.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,361 passed** (+4) |
| `infra_screen_test.dart` | 30 (+4) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**Negative control.** Replacing `_handleBack` with an unconditional `_exitToStacks()` fails both the
Cancel test and the Discard test, and leaves the untouched-draft test passing — the right shape,
since that one asserts no prompt appears.

**Back axis status.** SFTP browser, share browser and image preview (63); compose builder (65). The
remaining Kotlin handler is `ui/CodeEditor.kt:398`, which closes the full-screen editor. Flutter
presents that editor as a sheet the platform already pops, so it is likely parity by construction —
but that is an inference from the widget type, not an observation, and it is recorded here as
unverified rather than closed.

### 64 — an unsaved compose draft was destroyed by a tab switch (closed)

Found while investigating the leftover from defect 63, and it corrected that entry: see the
withdrawal note there.

`InfraScreen` builds the Builder tab from a `switch` on the active sub-tab:

```dart
InfraTab.builder => const BuilderTab(),
```

so the tab's `State` — which held `_draft`, `_baseline`, `_rawMode` and both editor controllers —
was discarded the moment the user looked at Stacks. There is no `AutomaticKeepAlive` above it.
Kotlin holds the same data on the view model and says why in a comment: *"so edits survive a tab
switch"*.

**What the user lost.** A compose stack is not a quick form. Building one means a project name, a
working directory, services, images, ports, volumes and Podman modifiers — minutes of typing that
vanished on a glance at another tab, with no confirmation and nothing to undo. Leaving the Infra
screen did the same.

**The fix.** `ComposeDraftMemento` (in `compose_builder_logic.dart`, alongside the draft types) is
parked on `InfraViewModel.composeDraft` in `dispose` and read back on first attach. Three details
are deliberate:

* **Only what was typed is captured.** Validation issues and the editor rebuild counter are
  recomputed on restore, so a restored draft cannot disagree with a fresh one about whether it is
  valid.
* **The memento is captured before the controllers are disposed**, since their text is part of what
  has to survive.
* **`New` clears the memento as well as the draft.** Otherwise the draft the user explicitly threw
  away returns on the next visit — the same class of bug, pointing the other way.

`InfraViewModel` now imports `compose_builder_logic.dart`. That file is widget-free — pure data and
logic that happens to sit under `ui/screens` — so this is a directory-layout wrinkle rather than a
layering inversion, and it is commented as such at the import.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,357 passed** (+3) |
| `infra_screen_test.dart` | 26 (+3) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**Negative control.** Disabling the restore call (`_restore(vm.composeDraft)`) fails both
persistence tests and leaves the `New` test passing — which is the right shape, since that one
asserts the *absence* of a restored draft.

**A test that lied, and how it was caught.** The first version of "leaving the screen entirely"
failed. The cause was the test, not the code: the file's `pump` helper constructs a *new*
`InfraViewModel`, so the second pump threw away the very object the draft was parked on. In the app
the provider lives above the route and the view model outlives the screen. Rewritten to re-mount
`InfraScreen` against the same view model. Worth recording because the failure looked exactly like
a real defect and would have been "fixed" wrongly by making the memento static.

**Still open from the back-handling axis (63):** Kotlin also *confirms* before discarding the draft
on Back (`ui/ComposeBuilder.kt:1236`), and returns to the Stacks tab rather than mutating state
invisibly — its comment explains that a handler which only cleared made the tab inescapable. With
the draft now preserved, Back loses nothing, so what remains is the confirmation and the
intermediate navigation step, not a safeguard.

### 63 — Back had no meaning inside a screen (closed for SFTP and the image preview)

Found by sweeping an axis rather than a string list. The handoff still lists "back behaviour" as
unswept, so I diffed the handlers directly:

```
$ grep -rn "BackHandler" --include=*.kt app/src/main   →  6 real handlers
$ grep -rn "PopScope"    --include=*.dart lib          →  1
```

Kotlin layers Back across five screen-level handlers and one app-level handler, and the app-level
one is *disabled* whenever an overlay is up (`ui/AppUi.kt:482` gates on `imagePreview == null`,
`edittingSftpFile == null`, `edittingShareFile == null` and the editor host). Flutter ported only
the root `PopScope` in `main.dart` and the two *navigation* transactions in
`navigation_guard_host.dart` (unsaved Settings, live SSH sessions). Everything screen-local was
missing.

The architecture for it was already there and unused: `NavigationController.guards` is consulted by
`navigateBack()` before it touches history, and the root `PopScope` routes through `navigateBack()`.
So this is another instance of the session's dominant defect class — **code that exists and is
tested but is unconsulted** (27, 31, 33, 38, 43, 44, 52) — rather than code that had to be written.

**What the user saw.** Three directories deep in the file browser, Back left the SFTP screen
instead of going up one folder. That is the single most-used gesture in a file manager. With an
image preview open, Back navigated to another screen and left `_imagePreview` set, so returning to
SFTP found the preview still covering the listing with no obvious cause.

**The fix.** `lib/domain/sftp_back_action.dart` resolves one ordered decision; the three Kotlin
handlers become one table whose non-overlap is a property of the code rather than a coincidence of
where each handler was installed:

| State | Back does |
|---|---|
| Image preview open | Close the preview — *checked before the tab*, since Kotlin draws it above the whole app |
| Not on the Files tab | Nothing; the press falls through to app navigation |
| Rows selected | Clear the selection, listing unchanged |
| Search results shown | Dismiss the results |
| Path is not `/` or empty | Go up one directory |
| A share, at its root | Close the share and return to the share list |
| A host, at its root | Nothing; the press falls through |

Two asymmetries are inherited rather than invented, and both are documented at the call site:

* **A share at its root closes; a host at its root does not.** Kotlin's host handler is explicitly
  `enabled = selectionMode || searchActive || (path != "" && path != "/")`, while the share handler
  always claims and falls through to `closeShareBrowser()`. A share has somewhere to go back *to*;
  a host does not.
* **The floor is `/`, not the login directory.** Back keeps climbing past `/home/root`. A home
  directory is somewhere you were put, not a floor. I had this wrong in a first draft of the test
  and corrected the *test*, not the code, after re-reading `ui/SftpScreen.kt:1691`.

`lib/ui/widgets/back_interceptor.dart` is the screen-side half: it registers a guard on mount and
removes it on dispose. It ignores forward navigation (`to != null`) so a bottom-nav tap cannot
silently unwind another screen's state.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,354 passed** (+17) |
| `sftp_back_action_test.dart` | 14 new |
| `sftp_screen_test.dart` | 53 (+3, end-to-end through the real screen) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |
| `git diff --check`, both worktrees | clean |

**Negative controls.** Both halves were mutated to confirm the tests can fail:

| Mutation | Result |
|---|---|
| Move the preview check below the tab gate | 2 failures |
| Never register the guard (`nav.guards.add` removed) | 2 failures |

**Coverage note, and a contrast with 62.** Defect 62 closed with the wiring between gate and input
*uncovered*, because a live `AppLockController` keeps a timer that stops `pumpAndSettle` quieting.
No such obstacle here, so the three new `sftp_screen_test.dart` cases drive the real screen through
the real `NavigationController` — tapping into a folder, pressing Back, and asserting both that the
listing moved and that the screen did not. That is the layer 62 is missing.

The SFTP screen now genuinely requires a `NavigationController` in scope; its test harness supplies
one, as the app does. That is a real new dependency and is deliberately not made optional — a
silent no-op when the controller is absent would hide exactly the kind of wiring mistake this
defect was.

**Still open, and deliberately not fixed in this slice:**

* ~~`ui/ComposeBuilder.kt:1260` — Back offers to discard the compose draft. Flutter navigates away
  and *keeps* the draft in the view model, so it loses no data; this is a missing confirmation, not
  a missing safeguard, and is lower severity than it first looks.~~
  **Withdrawn — this was wrong, and wrong in the direction that matters.** I inferred "keeps the
  draft in the view model" from Kotlin's design instead of reading `compose_builder.dart`. Flutter
  kept the draft in the *widget's* `State`, so leaving the screen destroyed it. That is data loss,
  not a missing confirmation, and it is **defect 64**. The rule this breaks is the one at the top of
  this ledger: a claim about the port is only worth what the code says, and I asserted a
  reassuring one without opening the file.
* `ui/CodeEditor.kt:398` — Back closes the full-screen editor. Flutter's editor is a sheet, which
  the platform already pops; needs checking on device before assuming parity either way.

### 62 — the app lock could be switched off without passing it (closed)

Found in the `.kt`-side string queue (`missing2.json`), from the entry *"Authenticate to save
settings"*. Most of that file is extractor noise — code fragments rather than copy — but filtering
for plausible sentences left 298, and this one named a security rule.

The consequence is worse than "settings changed without a prompt". `_save` already clears the stored
PIN when the lock is switched off, so the unguarded path meant **anyone holding the phone during an
unlocked moment could remove the lock entirely**, then take their time. Screenshot blocking and
sensitive-info masking sit on the same screen.

Now gated exactly as Kotlin gates it: a stored PIN means the save asks for it first.

**The existing sudo dialog was parameterised rather than copied.** The prompt, the biometric path and
the throttle are identical whatever is being confirmed, and a second copy of a security dialog is a
second place for one of those to drift.

| Check | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `flutter test` (whole host suite) | **2,337 passed** (+1 over 2,336) |
| `test/settings_screen_test.dart` | 20 passed, 1 new: with no PIN configured, Save still applies straight away |
| Surface sweep + walkthrough, API 35 | **8 passed** |

**Coverage limit, and it cost most of the turn to establish.** I wrote two tests for the *gated* path
and both hung. Providing a live `AppLockController` stops the harness settling at all — it keeps a
timer for the background lock — so `pumpAndSettle` never quiets, in the harness's own setup before
the test body runs. Bounded pumps in the test body did not help for that reason. Rather than leave a
hanging suite or rewrite the harness for one assertion, the tests were removed and the limit written
into the test file: the gate's input (`hasStoredPin`) is covered in `app_lock_test.dart`, the
ungated path is covered here, and **the wiring between them is not covered**.

## Exhaustive audit inventory

Built 2026-08-09 from `app/src/main/java/**/ui/*.kt`. This is the queue for the screen-by-screen,
option-by-option pass — it exists to make the remaining work **finite and ordered** rather than
probe-driven, since the probes above are now exhausted.

| Surface | Count |
|---|---|
| Composables | 77 |
| `AlertDialog` sites | 69 |
| Long-press / `combinedClickable` handlers | 11 |
| Horizontal-swipe gesture handlers | 3 |
| **Total inventory rows** | **160** |

Distribution — this is also the priority order, since it is where the surface area actually is:

| File | Rows |
|---|---|
| `ToolsScreen.kt` | 38 |
<!-- swept: hub, section headers, cron -->
<!-- hub + section headers swept — defects 19, 20)* |
| `AppUi.kt` | 36 |
<!-- swept: PinLockGateway, BiometricUnlockButton, SudoAuthDialog, TmuxInstallDialog, OfflineConnectDialog, ActionStreamDialog, ServerSelectorBar, FirstRunDialog -->
<!-- dialogs + selector swept — defects 21-27)* |
| `SftpScreen.kt` | 28 |
<!-- swept: destructive dialogs, file editor, sudo mode, download/upload to device, SftpBookmarksTab + BookmarkEditDialog, path box + home/up, archive extraction, host search, selection toolbar -->
<!-- bookmarks swept — defect 32; path navigation — defect 33; search — defect 34 -->
| `OmniComponents.kt` | 18 |
<!-- swept: formatBytes, formatUptime, formatSessionAge, GaugeBar, OmniCard, OmniStatBox, OmniTag, SectionHeader, StatusDot, ScoreRing, MiniMetric, RefreshCountdown, OmniAppBar, OmniBottomNav, HostPicker* -->
<!-- session age — defect 37; the rest verified present under Flutter names -->
| `FleetScreen.kt` / `MonitorScreen.kt` / `ShellScreen.kt` | 9 each |
<!-- FleetScreen swept: dashboard, broadcast, logs, summary bar, MetricLineChart — no gaps -->
<!-- ShellScreen swept: host key approval, session picker, split panes, quick connect, key bar, read-only bar -->
<!-- read-only key bar — defect 38; session age — defect 37 -->
<!-- MonitorScreen swept: six tabs, schedule dialog, cron helpers — defect 39 -->
| `ComposeBuilder.kt` / `InfraScreen.kt` | 4 each |
<!-- swept — no gaps -->
| `CodeEditor.kt` / `ScriptEditorDialog.kt` | 2 each |
<!-- swept: find/replace present in widgets/code_editor.dart — no gaps -->
| `ImagePreview.kt` | 1 |
<!-- swept — defect 40 -->

A name-match heuristic marks 30 of the 77 composables as having no obvious Flutter counterpart.
**That number is a starting point, not a finding.** Two checks already came back false:
`FirstRunDialog` is a permissions prompt Flutter has under a different structure, and
`OmniPasswordField` exists as ordinary obscured fields. Every row needs reading against both
implementations, exactly as the earlier probes did — the heuristic only orders the queue.

Generated by `scratchpad/inventory.py`; raw rows in `scratchpad/inventory.json`.

### Still to sweep, beyond the inventory

The inventory covers structure. These axes cut across it and are **not** enumerated yet:

- every settings option's *effect* (not just its presence), and permutations between them
  <!-- key-by-key diff done — defects 41, 42; unconsumed-preference sweep — defect 43; per-setting effect still open -->
- the three themes plus AMOLED and both high-contrast modes, against every screen
  <!-- all five now swept on device — defect 45 -->
- empty / loading / error / offline / unlicensed states per screen
  <!-- unlicensed swept — defects 51, 52; empty/loading fully swept — defects 53, 54, rest verified safe -->
- first-install behaviour and the restore path end to end
  <!-- restore: version gate — defect 56; host cap — defect 51; first-install — defect 57. Axis complete. -->
- text scaling and accessibility labels
  <!-- 200% now swept on device — defects 46, 47; accessibility labels still open -->
- platform-specific branches (Android vs iOS) per feature
  <!-- swept — defect 55; every branch enumerated, six verified correct -->

## Redundant, not defective

Found by the orphan sweep and verified to be duplication rather than missing behaviour:

- `shareIsBrowsable` is never called; the shares tab gates on `shareBrowseUnavailableReason`, and the
  two agree (SMB/FTP/SFTP/WebDAV browsable, NFS and custom not). Its doc comment is **stale** — it
  says the port "has clients for SMB and SFTP only", but `ftp_remote_fs_client.dart` and
  `webdav_remote_fs_client.dart` now exist and are wired into `_shareClientFor`.
- `macAddressError` is never called; `saveWolTarget` validates through `parseMacAddress` instead.
  Behaviour is present, though the generic "That is not a MAC address." is less helpful than the
  unused validator's "Use the form AA:BB:CC:DD:EE:FF".
- `AppLockTimeoutTracker` is superseded by the inline logic in `AppLockController` (see defect 8).
- `parseSmart` is used inside `remote_parsers.dart`; the sweep flags same-file use as unreferenced.
- `isOverThreshold` duplicates the comparison `alerts_view_model.dart:360` makes inline, and both
  match Kotlin's `currentValue > r.thresholdValue` at `AppViewModel.kt:2592`.
- `magicPacketFor` is documented as a convenience for tests; `wake()` sends through
  `probe.sendMagicPacket`.

Two stale doc comments worth correcting when documentation is reconciled: the above, and
`remote_commands.dart`'s header claiming "Only `normaliseOs` is here so far" in a file now carrying
most of the command set.

## Ruled out (verified present, wording differs only)

Podman runtime/pod support, DNS lookup, WHOIS, Wake-on-LAN targets, traceroute, SOCKS dynamic
tunnels (Flutter's copy says SOCKS4/4a/5, which is *more* accurate than Kotlin's "SOCKS5"),
high-contrast themes, `Acknowledge all`, health scoring, crash history, device diagnostics,
tar.gz compression, terminal scrollback, agent forwarding.

## Not yet swept

Kotlin's `stringResource` indirection means `strings.xml` carries copy the `.kt` sweep cannot see and
vice versa; both were compared, but **neither sweep covers behaviour** — only text. Still outstanding
from the handoff: action-by-action semantics, dialog/confirmation wiring, empty/loading/error/offline
states, back behaviour, long-press menus, accessibility labels, and spacing/colour.

**Updated.** Empty/loading/error states and platform-specific branches are now swept (defects 53,
54, 55 and the axis note above them). Of the ~325 candidate strings in `missing_xml.json`, the
`crash_*` cluster has been adjudicated and turned out to name a real missing feature — defect 58.
`shortcut_*` followed as defect 59, `widget_*` as 60 and `local_network_*` as 61 — the queue is worked through, and the
lesson from `crash_*` is that a cluster of related strings is worth reading as a *feature* rather
than as copy.
