# Kotlin → Flutter parity ledger

Started 2026-08-09. Companion to `HANDOVER.md` (priority 1: "build a screen/subtab/
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
| 102 | tmux control mode (**input**) | **Keystrokes keep going to the first pane ever seen.** The pane id is learned once from the first `%output` and never revised (`shell_session.dart:141`), so switching window or pane inside tmux leaves input addressed to the old one. Kotlin re-resolves it on `%session-changed` and the pane/window notifications (`ui/AppViewModel.kt:5139`), which Flutter discards. | **Open** — evidenced, see below |
| 101 | Backup (**data loss**) | **The passphrase dialog promised eight characters and the export demanded twelve**, after the document picker had already created the file — so a rejected export left a 0-byte file that looks like a backup. Kotlin held the number in two disagreeing places (`ui/ToolsScreen.kt:2808` vs `ui/AppViewModel.kt:11360`); Flutter enforced no minimum at all. One constant per app, checked in the dialog and at the export. | **Closed** — see below |
| 100 | Links (**chrome**) | **A link opened from the terminal used the browser's default chrome.** Kotlin builds its Custom Tab with `setShowTitle(true)` and the app's surface colour (`ui/LinkOpener.kt`), and falls through to the user's real browser when no Custom Tabs provider exists; url_launcher exposes only `showTitle` (defaulting false) and falls back to its own WebView. Ported as `CustomTabsBridge`. | **Closed** — see below |\n| 99 | Persistent tmux (**missing feature**) | **A reattached session lost its history.** Kotlin captures the pane's scrollback over a side exec channel, guarded on `#{alternate_on}` so a TUI's frames are not mistaken for history (`data/RemoteParsers.kt:280`, `ui/AppViewModel.kt:4884`). None of it exists here, so scrolling up after a reattach shows only what tmux replayed. | **Closed** — see below |\n| 98 | Terminal input (**hardware keyboard**) | **Ctrl and Alt on an attached keyboard did nothing.** The encoder was a faithful port but nothing told it which modifiers were held: `_onKey` never consulted `HardwareKeyboard`, so Ctrl+C typed `c`, Ctrl+Left sent a bare Left and Alt+b typed `b`. Kotlin assigns the event's modifiers before every key (`ui/ShellScreen.kt:2322`, `:2363`) and reserves Ctrl+Alt for AltGr. | **Closed** — see below |\n| 97 | Terminal input (**safety**) | **Pastes were never bracketed.** The emulator tracked DECSET 2004 and nothing read it, so a multi-line paste reached a shell that had asked for literal text as plain typing — executed line by line on arrival. Kotlin wraps the body and sends trailing CRs after the closing marker (`ui/AppViewModel.kt:696`). Found by checking `TERMINAL_COMPATIBILITY.md` against the Dart emulator for the first time. | **Closed** — see below |\n| 96 | Auth keys (**security**) | **A copied private key was shown by the system clipboard preview and left there indefinitely.** Kotlin marks that one copy `EXTRA_IS_SENSITIVE` and clears it after 60s if unchanged (`ui/ToolsScreen.kt:115`); Flutter used a plain `Clipboard.setData`, which cannot express the marker. Now a platform bridge plus a Dart timed, conditional clear. | **Closed** — see below |\n| 95 | Host form (**honesty**) | **The SSH compression switch claimed a behaviour the app cannot perform.** dartssh2 proposes `['none']` and ships no zlib, so the control could be set and never compressed anything, while Kotlin negotiates zlib. Shown disabled with the reason, stored value untouched so backup and restore still round-trip. | **Closed** — see below |\n| 94 | SSH transport (**dead settings**) | **Two host-form switches changed nothing.** `compression` and `agentForwarding` travelled from the form through `SshCredentials` and were never read; Kotlin implements both (`JschSshTransport.kt:351`, `JschSession.kt:85`). Agent forwarding is now served by `SSHKeyPairAgent` on the shell channel only, with a reconnect-without-it fallback matching Kotlin's `runCatching`. Compression cannot be honoured — dartssh2 hard-codes `['none']` — and is **left open with evidence**. | **Agent forwarding closed; compression open** |
| 93 | Credential storage (**data safety**) | **A single failed keystore read could blank every stored credential.** `flutter_secure_storage`'s `AndroidOptions` defaults `resetOnError: true`, which deletes the key on a failed read (`deleteAll()` on a failed readAll). The one key kept there encrypts every password and private key in the database, and `_key()` mints a replacement silently, so the app would carry on with everything unreadable and report nothing. Kotlin logs the failure class and returns null (`data/SecretStore.kt:35`), deleting nothing. | **Closed** — see below |
| 92 | App lock / sudo re-auth (**security**) | **The biometric gate accepted the phone's own PIN.** Kotlin allows one authenticator — `setAllowedAuthenticators(BIOMETRIC_STRONG)`, no `DEVICE_CREDENTIAL` (`data/BiometricCryptoGate.kt:91`) — because the lock defends against someone holding the *unlocked* phone. Flutter passed `biometricOnly: false`, so the device credential satisfied it, and gated availability on `canCheckBiometrics` (hardware) rather than enrolment. The correct port existed, unreferenced, in `biometric_gate.dart`. | **Closed** — see below |
| 91 | Terminal (**input**) | **A freshly connected session had no keyboard until the grid was tapped.** Kotlin focuses the hidden input as soon as a pane becomes the focused, writable one (`ShellScreen.kt:1889`, "so the keyboard is available"); Flutter took focus only in the tap handler. Ported with the effect's *keys* as well as its body — the triple is compared, so a keyboard dismissed with Back is not re-raised by the next line of output. | **Closed** — see below |
| 90 | Terminal / accessibility (**input**) | **A read-only terminal summoned a soft keyboard that could not type.** Kotlin ties the hidden input's focus to read-only in four places (`ShellScreen.kt:1889`, `:2077`, `:1905`, `:2555`) — "read-only taps may focus a split pane for scrolling but never summon its keyboard". Flutter requested IME focus on any tap and released it on none, so the keyboard covered the output the user turned read-only to read, for keystrokes dropped at `shell_view_model.dart:899`. | **Closed** — see below |
| 89 | Code editor | **Go-to-line disposed its text controller while the dialog was still painting it.** The `TextEditingController` was disposed the moment `showDialog` returned, but the dialog's exit transition still renders the `TextField` bound to it. The dialog now records typed text through `onChanged` and owns no controller. | **Closed** — see below |
| 88 | Shares — WebDAV | **PROPFIND rejected the redirect it had provoked.** Collections were addressed as `/fixture`; Apache answers `301` to `/fixture/`, and the client treated that as a failure, so a WebDAV share could not be listed at all. Collection paths are now canonically encoded with a trailing slash. | **Closed** — see below |
| 87 | Shares — FTP | **FTP could not list a current vsftpd.** `ftpconnect` defaults to MLSD without capability discovery and vsftpd 3.0.5 answers `500 Unknown command`, making a healthy share impossible to open. FTP now probes `FEAT` and uses MLSD only when MLST/MLSD is advertised, falling back to LIST — including when FEAT itself is refused. | **Closed** — see below |
| 86 | Shares — SMB (native) | **A finished read could terminate the next one.** The bridge sent both a transfer-scoped `done` and a global `endOfStream` on an EventChannel name shared by sequential downloads, so a delayed end could land after the next read had subscribed. The redundant end was removed. | **Closed** — see below |
| 85 | Shares (**resource leak**) | **Every list, read and write built a new share client.** Each may own a native session and event channel, so an editor read-save-reread raced the previous stream's cancellation and left authenticated sessions open. One client is now held for the browse/editor session and closed once. | **Closed** — see below |
| 84 | Shares — FTP/WebDAV/SMB | **A completed transfer could be missed.** All three registered the stream-completion future *after* closing the producer; a completion arriving in between was never observed and the transfer hung. Registration now precedes the transfer. | **Closed** — see below |
| 83 | Shares — SMB (**capability**) | **Text files on an SMB share could not be edited on Android.** Kotlin's `openShareFileForEdit` (`AppViewModel.kt:8070`) edits a file on any protocol through `downloadTo`/`uploadStream`, gated only by size. Flutter's Android SMB client reported `supportsTextEditing == false` and had neither `readText` nor `writeText`. | **Closed** — see below |
| 82 | Build (**crash**) | **The native SMB client crashed on first use.** smbj needs Bouncy Castle at runtime and the Flutter Android build excluded it as a transitive. Kotlin pins `bcprov-jdk18on` explicitly (`libs.versions.toml:52`, `app/build.gradle.kts:202`); Flutter now pins the same 1.85. Invisible to every gate except running on a device. | **Closed** — see below |
| 81 | Shares (**start path**) | **A share's configured start path was discarded.** Kotlin resolves it through `ShareClients.startPath` (`RemoteFsClient.kt:74`, used at `AppViewModel.kt:7662`), which keeps SMB's share-name segment apart from FTP/SFTP/WebDAV's initial directory. Flutter called `openPath('')` unconditionally, so every non-SMB share opened at the protocol root while the Shares card still displayed the path being ignored. | **Closed** — see below |
| 80 | Large text (**layout**) | **The file browser's controls pushed the listing off the screen at 200% text.** In landscape the compact side-by-side header was still taller than the body, and a `Column` child with no ceiling overflows rather than yielding — 25px on the physical phone. The header block is now capped at 55% of the body and scrolls within it. | **Closed** — see below |
| 79 | Accessibility (**operability**) | **Split terminal focus was sight-only, and live status figures were announced as unexplained numbers.** Kotlin gives each pane a named, selected `OnClick` semantics action and describes health scores/countdowns in full. Flutter only drew the active pane's cyan border and announced `82` / `15s`, so TalkBack could neither focus a pane nor identify what the figures meant. | **Closed** — see below |
| 78 | Sort migration (**upgrade fidelity**) | **An upgrading user's saved share sort was discarded.** Kotlin keeps two sorts — `sftp_sort` for the Files tab and `share_sort` for the share browser (`AppViewModel.kt:7860`). This port has one, since a share takes over the Files tab, and read only the first — so someone who only ever changed the sort while browsing a share was put back on Name A-Z. | **Closed** — see below |
| 77 | Biometrics (**unreachable**) | **Biometric unlock was offered on devices that have none.** `BiometricAuth.isAvailable` carried a doc comment reading "Checked before offering the option" — and had **no caller**, so the switch was enabled on hardware where it could never succeed. Kotlin gates its prompt on `BiometricCryptoGate.canAuthenticate` and reports unavailability distinctly (`BiometricCryptoGate.kt:67`). | **Closed** — see below |
| 76 | Split shortcut (**unreachable**) | **The split launcher shortcut could never appear.** `ShortcutHelper.pushSplit` and its entire native implementation (`ShortcutBridge.kt`, `pushSplit` → `splitShortcut`) existed and had **no caller anywhere in Dart**. Kotlin pushes one whenever two hosts are loaded into panes (`AppViewModel.kt:1712`). | **Closed** — multi-SSH gap now closed |
| 75 | Split terminal (**capability**) | **A second host could not be opened into a pane.** Kotlin loads two *hosts* into panes in one action; the port could only split sessions that were already connected, so adding a host meant connecting it, watching it take over the screen, then splitting back. With one session open the split control was hidden entirely — "Open a second session first". | **Closed** — first slice of the multi-SSH gap |
| 74 | Crash reporting (**error handling**) | **Reporting or sharing a crash could fail silently, taking its own fallback with it.** `launchUrl` throws when no browser exists rather than returning false, and `_reportCrash` did not catch — so the fallback that copies the report never ran and the button did nothing at all. `_shareCrash` had no guard either, where Kotlin reports the failure (`MainActivity.kt:337`). | **Closed** — guarded by a source scan |
| 73 | Terminal accessibility (**regression**) | **The terminal output was invisible to a screen reader.** The surface is a `CustomPaint`, so it contributed nothing to the semantics tree at all — on an SSH client, the app's primary content. Kotlin puts a `contentDescription` on the same surface (`ui/ShellScreen.kt:2047`). | **Closed** — see below |
| 71 | Accessibility (**regression**) | **Thirty icon-only controls had no accessible name.** Every dismiss and close, the find-bar arrows and the numeric steppers announced to TalkBack as "button" and nothing else. Kotlin labels them — 179 `contentDescription`s, with its 59 nulls being decorative icons, which is correct usage. | **Closed** — guarded by a source scan |
| 72 | Formatting (**self-inflicted**) | **The branch would have failed CI's format gate.** `flutter-pr-check.yml` formats with `--line-length 100`; I had been running `dart format` at the default 80 all session, including on files that were then committed. | **Closed** — 163 files corrected |
| 70 | App Lock off (**security**) | **Turning App Lock off never said what it destroys.** Doing so deletes the stored PIN and the biometric enrolment with it; Kotlin confirms first and names both (`ui/ToolsScreen.kt:3905`). The port went straight to the save, so the destructive half of the switch was the silent one. | **Closed** — dialog axis complete |
| 69 | Clear scrollback (**capability**) | **Buffered terminal output could never be dropped.** `TerminalEmulator.clearScrollback()` existed, but its only caller was the DECSTR escape handler — no user action reached it. Kotlin offers it beside the copy ranges (`ui/ShellScreen.kt:2508`). With a persistent tmux session, ending the session does not drop the buffer either, so there was no way at all. | **Closed** — see below |
| 68 | Process kill (**capability**) | **A wedged process could not be killed.** `killProcess` has always taken a `signal`, but the only caller used the default 15, so the app could send SIGTERM and nothing else — precisely the signal a stuck process ignores. Kotlin offers graceful and force kill as separate actions with separate prompts (`ui/MonitorScreen.kt:920` and `:934`). | **Closed** — see below |
| 67 | Terminal transcript (**capability**) | **The terminal could only be copied in full, never just what was on screen.** Kotlin's long press opens the *visible screen* and offers the full buffer as a second choice (`ui/ShellScreen.kt:2086`, chooser at `:2491`). The port built only the full buffer, so the common case — copy the error currently on screen — was impossible, and every long press rendered the whole scrollback into selectable text. | **Closed** — see below |
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

### 100 — a link opened from the terminal arrived in nobody's chrome (closed)

The last item on the platform-argument seam, carried since 96 as "cosmetic, not recorded as a
defect". It is a defect: Kotlin's `ui/LinkOpener.kt` builds its Custom Tab with `setShowTitle(true)`
**and** `setToolbarColor(MaterialTheme.colorScheme.surface)` (`ui/ShellScreen.kt:1846`), and neither
reached this port.

`url_launcher` cannot express it. `InAppBrowserConfiguration` has exactly one field, `showTitle` —
which was defaulting to false, so even the free half was missing — and no colour at any version.
There is a second difference that matters more than the tint: where no Custom Tabs provider exists,
Kotlin falls through to `ACTION_VIEW` and the user's **real browser**, while url_launcher falls back
to its own bundled WebView. Those are different products, and on a terminal app the link came out of
the user's own shell output.

**Fix.** `CustomTabsBridge.kt`, a direct port of `LinkOpener.kt` — title, tint, and the
`ActivityNotFoundException` fall-through to `ACTION_VIEW`. `androidx.browser:browser:1.9.0` is
declared explicitly rather than leaned on transitively through url_launcher, for the reason the
bcprov pin three lines above it already states: a transitive is not a contract. `openLink` gained
`toolbarColor`, the terminal passes the same `colorScheme.surface` role Kotlin does, and everything
without the bridge — iOS, desktop, tests — still goes through url_launcher, now with `showTitle`
set. A missing bridge degrades to opening the link, never to refusing it.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/link_opener_test.dart` | 5 passed, all new |
| Full host suite | **2,455 passed** (+5) |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` | **29 passed, no warnings** (24 Dart + 3 backup picker + 2 notification) — `20260811T170146Z_android_emulator-5554_core` |

**Negative control.** Dropping the `toolbarColor` entry from the channel arguments fails `an in-app
open carries the toolbar colour to the platform` with `Expected: <4279246896>, Actual: <null>`.

The tests assert the *arguments* reaching the platform, because that is where the whole defect lived
— a wrapper returning the right boolean while asking for the wrong chrome passes anything that only
checks its return value. The scheme guard is covered too: a `file:` URL is refused **before** the
channel is touched, which matters because terminal output is untrusted text.

**Not covered, and stated rather than implied.** The url_launcher fallback taken when the bridge is
absent has no test. Proving it means mocking url_launcher's own platform interface, and a test that
merely showed "we did not call our channel" would assert the absence of one thing while claiming the
presence of another — the sixth vacuous control in this ledger was exactly that shape, so this one
was deleted rather than kept. The comment where it stood says so.

### The Galaxy S23 clears the instrumentation blocker (closed)

The Moto G6 could not run instrumentation at all — `JNI_CreateJavaVM failed`, reproducible across a
reboot, while plain `flutter test` on the same handset passed 24 tests. A Galaxy S23 Ultra
(`RZCW418XP4P`, Android 16 / API 36, 11GB) was attached and **runs it fine**, which settles the
question the previous entry left open: the fault was that device, not the project, and not the
`adb reverse` port collision that looked so much like the culprit.

`--profile core` there: **23 of 24 Dart tests, and Patrol 2 of 3** — the first execution of the
backup document-picker flow on real hardware rather than an emulator
(`20260811T162650Z_android_RZCW418XP4P_core`). Two failures, neither in the app:

- `app_actions`: the alert-rules flow died in `dragUntilVisible` with a bare `Bad state: No element`.
  Its helpers reached controls with `scrollUntilVisible(..., scrollable: Scrollable.first)`, which is
  two guesses — that the first scrollable holds the target, and that it survives the drag. On the
  S23's 411x882 logical screen the second one failed. Switched to the tall-surface idiom
  `app_lock_test.dart` and `crash_log_test.dart` already use; verified in the 29-test emulator run
  above, **not yet re-verified on the S23**, which is now unplugged.
- Patrol's `the picker is offered the file name` threw `StaleObjectException` from UiAutomator —
  the native view went stale between being matched and being read. That is Patrol's native
  inspection, not the app, and it wants a re-query rather than a fix here. **Open.**

### Crash-log collection now has a device flow (closed)

The last of the three gaps named when the device coverage was challenged — backup/restore had Patrol
tests that had never run, and crash logs had nothing at all. `test/crash_log_test.dart` covers the
pruning and the redactor as pure functions; **nothing exercised the feature on a device**, and the
two halves that only exist there are the ones a user leans on:

- The history lives in `SharedPreferences`, a platform channel. On a host that is an in-memory stub,
  so writing a report, reading it back after the app rebuilds, and the 20-entry/30-day pruning were
  all unproven against a real store.
- **Copy** reaches the platform clipboard, which is how a crash actually gets to a bug report.

`integration_test/crash_log_test.dart` plants a report through `CrashLog`, relaunches the app, finds
the entry in About's crash history, expands it, copies it, and reads the **real clipboard** back;
then clears the history and checks the empty state. The report is planted rather than caused,
because a genuine startup crash diverts the app into `startup.recovery` and refuses to launch —
that is its own flow and cannot be this one's setup.

The copy assertion is the part worth having. The planted report contains `password:
hunter2-should-never-be-copied`, so "the clipboard got the report" and "the clipboard got the
secret" cannot be mistaken for each other: it requires the marker present, the secret absent, and
`<redacted>` in its place.

**A defect that wasn't.** The reason for that assertion was a suspected leak — `_shareCrash` builds
its text with `redactCrashReport(entry.report)` while `onCopy` passes `entry.report` straight
through, which reads exactly like one path redacting and the other not. It is not: `CrashLog.record`
redacts **when the crash is written** (`crash_log.dart:119`), so what is stored is already safe and
every export path inherits it — the same place and the same reasoning as Kotlin
(`data/CrashLog.kt:46`). The share path's second call is redundant rather than load-bearing. Checked
before changing anything, and the test now pins the property at the end of the path a user takes
rather than at the line that happens to implement it.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | 2,450 passed |
| `dart format --line-length 100` | `0 changed` |
| `crash_log_test.dart`, `emulator-5554` | 2 passed |
| `crash_log_test.dart`, `ZF62224F8K` | 2 passed |
| `--profile core`, `ZF62224F8K` | **24 Dart tests passed** |

It failed twice before passing, both times on the same thing and neither on the product:
`scrollUntilVisible`'s `scrollable:` wants a `Scrollable` finder rather than the `ListView`'s key,
and About is a lazy list whose lower rows do not exist until scrolled to. Both are solved the way
`app_lock_test.dart` already solves them — lay the whole screen out at once — which is now the third
device flow to need that and probably ought to be shared.

**The phone still cannot run Patrol.** Rebooting it, as the handover asked, did **not** clear
`JNI_CreateJavaVM failed`: it reproduces on a freshly booted device with 1.4GB available, a single
user, and the runner correctly registered. Plain `flutter test -d ZF62224F8K` is unaffected — 24
tests pass on that phone in the same run — so this is specific to the Gradle instrumentation path.
Backup/restore through the real document picker therefore still has **emulator evidence only**.

### Why Patrol reports zero tests on the phone: the device, not the project (open)

The phone runs the same Patrol tests that pass on the emulator and reports `Total: 0` with
"Test run failed to complete. No test results". Two hypotheses were tested and one is settled.

**Wrong hypothesis, kept anyway.** Patrol defaults its test and app servers to **8081 and 8082** —
and `test-hosts.sh android` reverses both to this workstation for the fixture fleet (8082 is the
WebDAV share, 8081 a scan target). A reverse claims the port *on the device*, which is exactly where
Patrol's servers listen, and the emulator never gets those reversals, which would explain a
phone-only failure precisely. It is a real collision. **It is not this failure**: moving Patrol to
8181/8182 changed nothing. The move is kept because the conflict is genuine and would bite the
moment the real fault is cleared — but it is **reasoned, not demonstrated**, and wants confirming
once the phone can run instrumentation at all.

**The actual fault, from the device's own log.** Running the instrumentation directly:

```
adb shell am instrument -w -r com.jetsetslow.omniterm.app.flutter.test/pl.leancode.patrol.PatrolJUnitRunner
E/AndroidRuntime: JNI_CreateJavaVM failed
```

No output, reproducible on every attempt. The instrumentation process cannot start a Java VM. That
is below anything this repository controls: the app APK and the test APK both install cleanly by
hand, `pm list instrumentation` shows the runner registered against the right target, and the same
APKs execute on the emulator. Memory is not obviously the cause — 596MB free, 1.3GB available, of
2.8GB.

**What it blocks.** Backup save/restore through the real document picker, and the notification
permission dialog, have emulator evidence only. Both pass there (5 tests). Nothing in the app is
implicated: this is the harness failing to launch on one handset.

**Next step is physical:** reboot the phone and re-run. If it recurs, the remaining suspects are
LineageOS/Magisk interference with the instrumentation process and a per-uid process ceiling — 530
processes were running. Neither is diagnosable from the host alone.

### The backup picker tests run, and pass — first execution ever (closed)

`core` now finds and launches the Patrol tests, so the question became why they reported `Total: 0`.
The handover blamed missing androidTest wiring. **That was wrong**: `testInstrumentationRunner`,
`clearPackageData`, `ANDROIDX_TEST_ORCHESTRATOR`, the orchestrator dependency and the parameterized
`MainActivityTest.java` are all present and correct. On the emulator they execute fine — the
`Total: 0` was specific to the phone run and is a separate, still-open question.

Executed for the first time, they failed **2 of 3**, both on the same thing:

```
TimeoutException: Finder "Found 0 widgets with key [<'backup.export'>]" did not find any visible…
```

Not a renamed key — `backup.export` is right there at `backup_screen.dart:114`. **Zero widgets**, not
an invisible one: the Backup screen is a `ListView`, so a control past the fold has never been
built. The same file already scrolls to `backup.import` for exactly this reason; the two `export`
taps did not, and nobody found out because the file had never run.

**Fixed** by scrolling to it, the idiom the file already used.

**Evidence.**

| Gate | Result |
|---|---|
| `patrol test backup_file_picker_test.dart` | **3 passed** (was 1 passed / 2 failed) |
| `patrol test notification_permission_test.dart` | **2 passed** |
| `--profile core`, `emulator-5554` | **22 + 3 + 2 = 27 passed, no warnings** — `20260811T150010Z_android_emulator-5554_core` |
| `flutter analyze --fatal-infos` | clean |
| Full host suite | 2,450 passed |

**What this buys.** Backup save and restore now have device evidence through the **real system
document picker** — `ACTION_CREATE_DOCUMENT` in another process, which no widget test can reach.
Specifically covered: cancelling the save leaves no "Backup ready." claim standing over a file that
was never written; the picker is offered the filename the backup should have; cancelling the restore
picker changes nothing. The notification-permission dialog is covered too, granted and denied.

**Still not covered.** Crash-log collection has unit tests and no device flow. And the phone's
`Total: 0` is unexplained — the same tests execute on the emulator, so it is environmental rather
than a wiring gap, and it needs the phone in hand to diagnose.

### The device suite was running a third of itself (closed)

Prompted by a direct question — had the app been driven screen by screen on the attached phone, at
every combination of settings? It had not, and asking the question found more than a gap in effort.

**What was actually running.** `--profile core`, used by nearly every slice, ran a hand-written list
of three integration files out of eight. `--profile all` used `find -maxdepth 1`, so
`integration_test/native/` was invisible to every profile — five Patrol tests, 253 lines, driving
the real system document picker for **backup save and restore** and the notification permission
dialog, none of which had ever executed. And most slices ran `core` on the *emulator*, not the phone.

**What that hid.** Running `--profile all` on the phone for the first time: **19 passed, 4 failed.**

| Failure | Cause |
|---|---|
| `app_lock`: an absence locks the app | The test's `disableLock` tapped Save and settled. Ledger 62 and 70 had since put a confirmation dialog and a re-authentication gate in front of that save, and the helper answered neither — so the lock was never switched off and the next background locked it again. |
| `app_lock`: a configuration change is not an absence | Same helper. |
| `app_actions`: a host can be added and removed | Not reproducible; passed on the next run. Recorded as a flake, not fixed. |
| `key_import`: rubbish is rejected with a reason | Below. |

The two App Lock failures were **not** caused by any change in this session: they reproduce with
ledger 92's biometric change reverted. They had been failing since 62 and 70 landed, and nothing
noticed because the profile everyone reached for did not include the file.

### The key-import failure, and four wrong hypotheses

Worth recording in full, because every early answer was plausible and wrong.

`rubbish is rejected with a reason, not silently stored` failed on the phone and passed on the
emulator. The error text was absent, so the import had apparently *succeeded* on rubbish input.

1. **"Slow hardware, the fixed settle is too short."** Replaced with a ten-second bounded wait. Still
   failed.
2. **"The validation has a platform-dependent hole."** `privateKeyParseError` short-circuits when
   `privateKeyNeedsPassphrase` says yes, which would skip the parse entirely — a real-looking
   suspect. Probed directly: rubbish gives `needsPassphrase=false` and a correct rejection message.
3. **"`importKey` swallows the exception."** Read every catch clause; all three return a message.
4. **"The button is off-screen; `ensureVisible` will fix it."** It did not.

The probe that settled it printed the button's own state: **enabled, still labelled `Import`**, ten
seconds after the tap, with nothing stored and no error. So `_import()` had never run — the tap was
not reaching the button at all.

**The cause.** The previous test's typing leaves the soft keyboard up, and it covers the bottom of
the sheet where Import sits. `ensureVisible` cannot help: it scrolls within the sheet, and the IME is
an overlay outside it. Run in isolation the app has just started, no field has been focused, and the
button is in the clear — which is why *reproducing a suite failure by running one test disproved the
wrong thing*, twice. The fix dismisses focus before reaching for the button.

**Evidence.** All three key-import tests pass on `ZF62224F8K`; the full non-host profile is **22
passing** on the phone (`20260811T142523Z_android_ZF62224F8K_core`) and 22 on the emulator
(`20260811T132424Z_android_emulator-5554_core`), up from 13 emulator-only.

### What the profiles do now

- `core` discovers **every** integration test that does not need the lab, recursively. A new file
  joins by existing; there is no list to forget to update.
- Patrol files are split out by content — a file is Patrol's because it calls `patrolTest` — and run
  through the Patrol CLI, because `flutter test` cannot drive another process's UI. Missing CLI is a
  loud failure, not a silent skip.
- The warning gate reads both logs.

**The surface matrix is now a matrix.** It was five schemes plus a single 200%-text row; ledger 80
came out of that one row, in landscape dark specifically. It is now 5 schemes × 4 text sizes (the
full `PreferenceRange(80, 200)`) × 2 orientations = **40 passes** over every route and subtab, green
on both devices.

**Still not running: the Patrol tests.** They now build and launch, and execute **zero** tests —
`Total: 0` with a Gradle exit of 1. `testInstrumentationRunner` and `MainActivityTest.java` are in
place, so the remaining piece is the Patrol androidTest dependency wiring. **Backup save/restore
through the real document picker therefore still has no device evidence**, and neither does the
notification permission dialog. Crash-log collection has unit coverage only and no device test at
all.

### 102 — in tmux control mode, keystrokes kept going to the first pane ever seen (closed)

Deferred twice as "needs the whole vertical". That was right about the shape and **wrong about the
size**, and the correction is the useful part of this entry.

**What the earlier entry got wrong.** It said the fix needed the `%begin`…`%end` reply plumbing,
"because the active-pane query returns through the third event Flutter discards". It does not.
Kotlin resolves the pane over a **side channel** — a separate `exec`, not the control conversation —
and says so at the definition (`data/RemoteParsers.kt:202`):

```kotlin
/** Active pane id ... (side channel; control mode needs it to route %output). */
fun tmuxActivePaneQuery(name: String) =
    "tmux display-message -p -t ${tmuxSafeName(name)} '#{pane_id}' 2>/dev/null || true"
```

I had inferred the dependency from the event list rather than reading the caller. Reply plumbing is
still absent on the Flutter side and is still worth having one day; it was never on the path to this
fix, and believing it was is what kept the defect open for two extra slices.

**The defect.** Control mode addresses input explicitly (`send-keys -t <pane>`), and Flutter learned
the pane once, from the first `%output` it ever received:

```dart
_controlPaneId ??= paneId;   // the only assignment
```

Switch window or pane inside tmux and that id goes stale: tmux streams the new pane's output while
OmniTerm keeps typing into the old one. Ledger 9 states the principle it broke, in the same file —
input "is **not** sent to a guessed pane — that would deliver keystrokes somewhere the user is not
looking." A stale id is a guess that used to be right.

**The fix, and why not the one-liner.** Tracking the *latest* `%output` pane is the obvious shortcut
and it is the same defect pointed the other way: a background pane producing output would steal the
keyboard. So the pane is re-resolved by asking, not by guessing:

- `ShellSession` recognises the notifications that mean the active pane may have moved
  (`%window-pane-changed`, `%session-window-changed`, `%client-session-changed`, `%window-close`,
  `%window-add`, `%unlinked-window-close`), and a `%session-changed` that is **not** the attach.
- Each bumps `paneChangeRevision` and sets `paneChangePending`.
- `ShellViewModel.refreshControlActivePane` runs `tmuxActivePaneQuery` over the exec side channel,
  validates the answer against `^%\d+$` (the command ends in `|| true`, so a departed tmux answers
  with an empty string, and adopting that would address input to nothing), and re-checks the revision
  before committing. A switch that lands mid-query restarts the loop rather than being answered with
  the pane the user just left.
- Adoption marks the scrollback dirty, so the new pane's history is fetched by the existing resync.

Left deliberately: until the query returns, the old pane id keeps working. That is the pre-existing
behaviour rather than a regression, and it beats dropping keystrokes on the floor.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/shell_session_test.dart` | 31 passed (+4) |
| `test/shell_view_model_test.dart` | 48 passed (+2) |
| Full host suite | **2,475 passed** |
| `dart format --line-length 100` | 1 file reformatted, then clean |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, Patrol included — `20260811T201233Z_android_emulator-5554_core`. Script exit 3 is the warning gate on the upstream KGP warning alone; no warning from this app. |

**Negative controls, three, each matched exactly once and each failing the right test:**

| Mutation | Failing test |
|---|---|
| stop noticing pane-change notifications | *a window switch … marks the pane unresolved*, and the stale-revision test |
| drop the revision check in `adoptControlPane` | *a pane resolved against a stale revision is refused* |
| `_controlPaneId = paneId` — the tempting shortcut | *output from a background pane does not steal the keyboard* |

The third is the one worth keeping. It is not a control on the code I wrote; it is a control on the
**wrong fix**, and it fails, which is the only reason to believe the suite would have caught the
shortcut had I taken it.

A fourth, on the view model: replacing the `^%\d+$` check with a condition that never fires makes
*an answer that is not a pane id is refused* fail.

**The session tests alone were not enough, and nearly shipped that way.** They cover the revision
bookkeeping thoroughly and exercise **none** of `refreshControlActivePane` — the query, the
validation, the retry. Writing the view-model tests afterwards was not a formality: the first one
**failed on the first run**, returning `false`, because the session under test was not in control
mode and the guard rejected it immediately. Four tests passing against the half of the change that
was easy to test is exactly what an unexercised code path looks like from the inside.

### 101 — the backup passphrase dialog promised eight and the export demanded twelve (closed, **both apps**)

Reported from use, not found by a sweep: a backup was created as a **0-byte file** and then refused
with "Passphrase must be at least 12 characters", while the field it had just been typed into was
labelled "min 8 chars".

**Kotlin held the number in two places and they disagreed.**

| Where | Said |
|---|---|
| `ui/ToolsScreen.kt:2808` — the field's label | `min 8 chars` |
| `ui/ToolsScreen.kt:2814` — the confirm button | `enabled = exportPassword.length >= 8` |
| `ui/AppViewModel.kt:11360` — the export | refuses `< 12` |

The order is what turned a wording mismatch into a lost file. The dialog accepted eight, closed, and
launched `ACTION_CREATE_DOCUMENT`; **the picker creates the file when the user chooses the
location**; only then did the export run its own check and refuse. The user was left holding an empty
file that looks exactly like a backup — and it is the kind of file people discover is empty at the
moment they need it.

**Flutter had no minimum at all.** No copy, no gate, no check: any passphrase encrypted a file full
of credentials. It ordered its own steps correctly — ask, build, then save — so it never produced the
0-byte artefact, which is precisely why the weaker defect went unnoticed.

**Fixed on both sides, as one number.**

- Kotlin: `BACKUP_PASSPHRASE_MIN_LENGTH = 12` in `ui/AppViewModel.kt`, used by the label, the button
  gate and the export check. Landed in the `fix/kotlin-parity-defects` worktree.
- Flutter: `BackupViewModel.passphraseMinLength = 12`, enforced in `exportBackup` **and** advertised
  on the field, with the confirm button disabled until it is met.

The dialog gate and the export check are deliberately both present. The dialog is one caller; the
export is the boundary that decides whether credentials get weakly encrypted, and it has to hold for
the next screen that calls it. That separation is the actual lesson from the Kotlin version, where
the two disagreed and the weaker one owned the button.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Kotlin `:app:compileOpenSourceDebugKotlin` | BUILD SUCCESSFUL |
| Kotlin `:app:testOpenSourceDebugUnitTest` | BUILD SUCCESSFUL |
| `test/backup_screen_test.dart` | 32 passed (+2) |
| Full host suite | **2,464 passed** |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` | **29 passed, no warnings** — `20260811T182422Z_android_emulator-5554_core` |

**Negative control.** Removing the dialog's gate fails `a passphrase the export would refuse cannot
leave the dialog` with `Expected: null, Actual: <Closure: () => void>`.

Disabling the export-side check does **not** produce a clean assertion failure: the export proceeds
to encrypt, and the test stops returning promptly rather than reporting a diff. Worth stating plainly
rather than dressing up — the control shows the guard is load-bearing, because without it the weak
passphrase reaches the cipher, but it does so by changing the test's runtime, not its verdict.

**No Kotlin test was added, deliberately.** The behavioural guard lives on the Flutter side, where
the dialog and the export can both be driven. On the Kotlin side the invariant is now *structural* —
one constant, three uses — so the only test expressible against it ("the number the dialog enforces
equals the number the export enforces") reduces to comparing the constant with itself. That is the
vacuous-control shape this ledger has caught six times, and writing it here would have made the
seventh. A source scan for a re-inlined `>= 8` would be non-vacuous —
and **does** have precedent, which this entry originally denied: `test/accessibility_labels_test.dart`
is exactly that, a scan rather than a widget test, written because "nothing stopped the next screen
being wrong". The same argument applies to a number that must not be inlined twice, so this is left
as an available guard rather than a dismissed one.

**Twenty-four existing tests failed on the new rule**, all in `backup_payload_test.dart`, all because
they exported with the four-character `'pass'`. They encoded the absence of a minimum. Updated rather
than exempted: a suite that keeps a rule from applying to itself is how the rule stops being true.

### Sweeping for the same shape

The report asked whether there were more like it — copy stating one rule while the code enforces
another. Checked:

- **The app-lock PIN.** Flutter is consistent: `_PinDialog.minLength = 4` supplies both the rule and
  the message that quotes it, and the lock screen accepts up to twelve, the length a user can
  actually set. No defect.
- **"up to 24"** appears in both apps' settings copy and matches the enforced value on both sides.
- **One cross-app difference, recorded not fixed:** Kotlin's lock screen stops accepting digits at
  eight (`ui/AppViewModel.kt:3081`) while Flutter lets a PIN of up to twelve be set. A twelve-digit
  PIN set in Flutter could not be typed into Kotlin. It bites only a Flutter→Kotlin downgrade, and
  Kotlin is the app being retired, so it is listed rather than changed.

The general lesson is narrow and worth keeping: **a number that appears in both a sentence and a
condition should exist once.** Every instance found here was a constant that had been inlined twice.

### 105 — the replica count had no upper bound, and the validator that would have given it one was already ported (closed)

Found by widening the control audit rather than by a new idea: the extractor had left **301 Compose
controls with no extractable label**, and unlabelled means never compared. Compose usually writes
`Row { Text("AMOLED black"); Switch(...) }` — the label *precedes* the control — while the extractor
only searched forward from the constructor. Searching backward for the nearest preceding label
dropped the unlabelled count to 167 and put 134 more controls into the comparison. This defect came
straight out of the newly-visible set.

**The divergence.** Compose bounds the Scale dialog's replica count twice:

| Where | Rule |
|---|---|
| `ui/InfraScreen.kt:562` | `it.filter(Char::isDigit).take(3)` — digits only, three of them |
| `ui/InfraScreen.kt:555` | `countError(replicas, min = 0, max = 999)` |
| `ui/InfraScreen.kt:573` | `enabled = replicasError == null`, with the message in `supportingText` |

Flutter gated on negatives (`(value ?? -1) < 0`) and nothing else: no digit filter, no length limit,
**no upper bound**, and no message. `999999` was an accepted replica count, and the action behind it
is `compose up --scale` — not a slow operation but an attempt to start that many containers on the
host.

**The part worth keeping: the bound already existed.** `countError` had been ported into
`domain/input_validation.dart`, byte-for-byte the same rule as Kotlin's, and this dialog simply never
called it. That is the dominant defect class in this migration — code that exists, is tested, and is
never reached — and it is why the fix is `countError(_replicas.text, min: 0, max: infraMaxReplicas)`
rather than a new validator. A second private copy would have been the actual mistake.

**A behaviour change that is a fix, not a regression.** With `FilteringTextInputFormatter.digitsOnly`
a minus sign never reaches the field, so `-2` arrives as `2`. An existing test asserted that `-2`
*disabled* the button; it encoded behaviour Compose has never had, since `filter(Char::isDigit)`
strips the minus there too. Updated rather than exempted, and the `value < 0` branch is kept as the
boundary behind the field.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/infra_screen_test.dart` | 36 passed (+3) |
| Full host suite | **2,478 passed** |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, Patrol included — `20260811T203759Z_android_emulator-5554_core`. Script exit 3 is the warning gate on the upstream KGP warning alone; no warning from this app. |

**Negative controls — and the third one was vacuous on the first attempt.**

| Mutation | Failing test |
|---|---|
| drop `LengthLimitingTextInputFormatter(3)` | *a replica count above the cap is refused and says so* |
| drop the `error != null` gate on confirm | *an empty count is refused rather than sent as nothing* |
| widen the cap to `999999` | **nothing failed** |

The third is the interesting one. Behind a three-digit input formatter, no widget test can distinguish
a bound of 999 from 999999 — nothing larger can ever be typed, so `countError`'s `max` is never
reached and the number itself is uncovered. The fix was to hoist the bound to a top-level
`infraMaxReplicas` and assert it directly; the mutation then fails *the replica bound is the one
Compose enforces*.

Worth stating plainly because the shape recurs: **a guard behind another guard is invisible to tests
that can only drive the outer one.** That is the same trap as defect 103, where two tests passed with
the inner check deleted, and defect 102, where four tests covered the half of the change that was
easy to reach. Seven vacuous controls caught this session, every one of them an inner guard.

### 106 — an SFTP share could be saved as anonymous, and SSH has no anonymous mode (closed)

The second defect out of the unlabelled set, and the answer to a thread left open several slices ago:
`grep -rn "saveShare\|normalizeShare\|validateShare"` over `flutter_app/lib` returned nothing, and
that was recorded as "Flutter's equivalent must be located". It is `NetworkShareDraft.errors` in
`domain/network_share_form.dart` — named after the *state* rather than the verb, which is why three
verb-shaped greps missed it. The control audit found it by its gate instead: Compose's Save carries
`enabled = validateDraft() == null` (`ui/SftpScreen.kt:1496`), and following that led to both sides
of the comparison at once.

**Four of Compose's five rules were present.** Address, port range, SMB share path and
"some way to authenticate" all had Flutter equivalents, worded differently. The fifth did not:

```kotlin
normalizedProtocol == "SFTP" && anonymous -> "SFTP needs a username or credential profile."
```

**Why it matters more than a missing message.** SFTP is SSH, and SSH has no anonymous mode, so the
share cannot connect — but the form *hides the username fields the moment anonymous goes on*. A user
who ticked it on an SFTP share saved a share that could never work, and the fields that would have
fixed it were no longer on screen. Compose does not merely refuse this on save; it **disables the
toggle** for SFTP (`ui/SftpScreen.kt:1437`, `:1450`), so the choice is never offered.

**Three guards, because two of them leave a trap.**

| Guard | Why |
|---|---|
| `errors['anonymous']` when SFTP + anonymous | the boundary — holds for any caller, not just this form |
| `onChanged: null` on the toggle for SFTP | the affordance — refusing on save would point at a hidden field |
| `withProtocol` clears `anonymous` on the switch to SFTP | without it, a draft that arrives with anonymous already on meets a **disabled** toggle it cannot untick, and is unfixable without switching protocol back |

The third is the one that would have been missed by porting the rule alone. Compose has it too
(`if (option == "SFTP") anonymous = false`, `ui/SftpScreen.kt:1389`) and it is easy to read as
housekeeping rather than as the thing that stops the other two guards deadlocking the form.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/network_shares_test.dart` | 57 passed (+3) |
| Full host suite | **2,481 passed** |
| `dart format --line-length 100` | 1 file reformatted, then clean |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, Patrol included — `20260811T220624Z_android_emulator-5554_core`. Script exit 3 is the warning gate on the upstream KGP warning alone; no warning from this app. |

**Negative controls, one per guard, each matched exactly once and each failing only its own test:**

| Mutation | Failing test |
|---|---|
| drop the validation rule | *SFTP cannot be anonymous, because SSH has no anonymous mode* |
| stop clearing `anonymous` on the switch | *switching to SFTP clears anonymous rather than trapping the draft* |
| re-enable the toggle for SFTP | *the anonymous toggle is not offered for SFTP* |

Three guards, three tests, three distinct failures — which is the shape the last four defects did
*not* have, and the reason seven controls came back vacuous before this one.

### The secret gate did not cover the branch the work is on (closed, infrastructure)

Not a parity defect, and worth an entry because it was a real hole in the gate protecting all of
them.

`secret-scan.yml` triggered on `push`/`pull_request` to **`main` only**. `migration-to-flutter` is
neither `main` nor a PR *to* `main`, so **33 commits of migration work were never scanned**. The job
would first see them at the merge — the most expensive moment to find a secret, because the history
is already written and clearing it means a rewrite rather than a fix. `flutter-pr-check.yml` had
already listed both branches; this one simply never followed.

**Found by checking a claim rather than trusting it.** The handover's gates table asserted
`gitleaks: no leaks` as though current. Reading the workflow showed the last real run was
2026-08-11 against `de0d1397` on `main`, before any of this work existed.

**Two fixes, because the immediate one does not prevent the next gap:**

1. **Run it.** Dispatched against the branch: run `31590121095`, 2026-08-12, over every ref —
   `Check out complete history`, `Reject tracked credential containers`, `Scan for committed
   secrets`, all green. **No leaks.** The hand-checks done before committing (private-key headers
   grepped across every changed file, `.env` and `keys/` confirmed gitignored) were right, but they
   are not the tool and were never a substitute for it.
2. **Widen the triggers**, so it is not a thing someone has to remember: `push` and `pull_request`
   now list `[main, migration-to-flutter]`. The job takes ~16 seconds, so per-push cost is not worth
   counting against finding a credential 33 commits late.

**Guarded, because a trigger list is exactly what gets narrowed during an unrelated tidy-up.**
`scripts/test-secret-scan-coverage.sh` parses the workflow and fails unless both events cover both
branches — the same reasoning as `test-ci-gradle-gate.sh`, which pins the Gradle gate's arguments.
It runs from `local-pr-check.sh` alongside its siblings.

**Negative controls, and one of them nearly passed for the wrong reason.** Narrowing `push` back to
`[main]` fails it; removing the `pull_request` branch filter fails it. Both printed `FAIL` while my
first check reported `EXIT=0` — because the exit code I was reading came from the `head` at the end
of the pipeline, not from the script. A guard that prints a failure and exits 0 does not fail CI.
Re-checked directly: **exit 1 when mutated, exit 0 when correct.**

Also corrected in the handover: the gates table claimed the device warning gate still fails on the
KGP deprecation, which stopped being true when the allowlist landed, and it pointed at a stale run.
A dated line now separates the five gates re-verified on 2026-08-12 from the rows carried forward
from 2026-08-11 — chiefly the `ZF62224F8K` surface sweeps, since that phone is no longer attached.

### 115 — two more clipping dialogs, and a standing guard so there is no next one (closed)

Defect 114 fixed six dialogs found by a line-window search. That search was **wrong twice**, and this
entry is mostly about how.

**The guard.** `test/dialog_overflow_test.dart` scans `lib/` for every `AlertDialog`, walks to its
matching close paren so one dialog's body cannot leak into the next, and fails on any whose `content`
is a multi-child `Column` with nothing to absorb overflow — no `scrollable: true`, no
`SingleChildScrollView`, `ListView`, `Expanded` or `Flexible`. A source scan for the reason
`accessibility_labels_test.dart` gives: the defect is not that one dialog is wrong, it is that
nothing stopped the next one being wrong.

It is also the only practical gate for this class. Measuring dialogs by hand needs a harness per
screen *and the right geometry* — defect 113 passed at the emulator's 914x411 and failed only at
640x360, so the device sweep cannot see these at all.

**What proper paren matching found that a 60-line window missed:**

| Dialog | Why the window was wrong |
|---|---|
| `sftp.size.dialog` | An `Expanded(` **belonging to a different dialog further down the file** fell inside the window, so it was scored as already absorbing overflow. It does not: it is a size line plus a three-line caveat, and the caveat — the part saying the number is wrong — is what gets clipped. |
| `infra.stack.ports.dialog` | Missed entirely. Its `content` is a ternary, so `content:\s*Column\(` never matched. |

The ports dialog is the worst of the eight found across 114 and 115: its children are built by
`for (final detail in stack.portDetails)`, so the height is **data-driven and unbounded**. A stack
with a dozen published ports overflows on any phone, not only a small one. Nothing in the port had
ever rendered it with more than the fixture's two.

**The lesson, which is the same one as defects 105 and 110 in a different costume:** a heuristic that
scores a construct by what appears *near* it will be wrong wherever the construct is nested or
conditional. It found six real defects, which is what made it feel trustworthy enough not to check.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/dialog_overflow_test.dart` | 1 passed (new) |
| Full host suite | **2,515 passed** |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, exit 0 — `20260812T035455Z_android_emulator-5554_core`. Proves the two dialogs still open and behave; as with 113 and 114 it cannot prove the clipping is gone, because the emulator is too large to reproduce it. The guard is the evidence that matters here. |

**Negative controls, both on the guard itself** — a guard that cannot fail is worse than none:

| Mutation | Result |
|---|---|
| remove `scrollable: true` from `sudo_auth_dialog.dart` | fails, naming `sudo_auth_dialog.dart:100` |
| add a brand-new offending dialog to `lib/` | fails, naming the new file and line |

The second matters more than the first: it shows the guard catches a dialog **written after** it,
which is the only thing that makes it a gate rather than a snapshot.

### 114 — six dialogs clipped their own content on a small phone (closed)

The systematic follow-through from 113, done as a search rather than by waiting for the next sweep.

**The shape, stated precisely enough to search for:** an `AlertDialog` whose `content` is a
multi-child `Column`, with no `scrollable: true` and no scroll or flex of its own. Material clips
such a dialog rather than scrolling it. Fourteen dialogs in the port match the first half; **six have
no inner scrollable at all** and are the ones at risk:

| Dialog | File |
|---|---|
| `infra.stack.down.dialog` | `infra_tabs.dart` |
| `infra.scale.dialog` | `infra_tabs.dart` |
| `authKeys.generate.dialog` | `auth_keys_screen.dart` |
| the backup prompt (`${dialogKey}.dialog`) | `backup_screen.dart` |
| `offline.connect.dialog` | `connection_prompt_host.dart` |
| `sudoAuth.dialog` | `sudo_auth_dialog.dart` |

The other eight already hold a `SingleChildScrollView`, `Expanded` or `Flexible`, and were **left
alone deliberately**: adding `scrollable: true` around an inner scrollable is how nested-scroll bugs
are made, and the shape that fails is specifically the one with nothing to absorb the overflow.

**Verified, not assumed.** The Scale dialog is drivable from the existing tests, so it was measured
first: at 640x360 with 200% text it overflows by **3 pixels**. Small, and the same failure mode as
113's 39 — the content is clipped, and what is clipped is the bottom of the dialog. Three pixels
today is a longer error string tomorrow.

`scrollable: true` on all six.

**Honest about coverage:** one of the six has a regression test (the Scale dialog, with a control
that reproduces the 3px overflow when the fix is removed). The other five are fixed by inspection of
a shape now demonstrated to fail, not by individual measurement. That is weaker evidence and is
recorded as such rather than presented as six tested fixes.

**A test-harness fix that came with it.** `openServiceMenu` tapped controls at fixed positions, which
worked only because every harness in that file used a large surface. It now scrolls each control into
view first — a no-op on the big surface, and the only way the small one works at all. The same
blind spot as 113's 1200x4000 settings harness, in a different file.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/infra_screen_test.dart` | 38 passed (+1) |
| Full host suite | **2,514 passed** |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, exit 0 — `20260812T033532Z_android_emulator-5554_core`. Proves the six dialogs still open and behave; it cannot prove the overflow is gone, because the emulator is too large to reproduce it. |

**Negative control.** Removing `scrollable: true` from the Scale dialog fails *the Scale dialog fits
a small phone in landscape at 200% text* with `A RenderFlex overflowed by 3.0 pixels on the bottom`.

### 113 — the PIN dialog overflowed on a small phone, hiding the error explaining why (closed)

Found by taking defect 112's lesson and looking for the rest of its class rather than waiting for the
next sweep to trip.

**The search.** Every `ValueKey` naming an error, empty, failed or unavailable state — 48 of them —
checked against the whole test tree. **Thirteen are referenced by no test at all.** The empty states
among them the surface sweep does reach, because empty is the default when there is no data. The
error ones it cannot: producing them needs a condition no route walk creates. `settings.pin.error`
was the most constrained of those, because it lives in an `AlertDialog`, **and an AlertDialog's
content does not scroll unless it asks to**.

**The defect.** The dialog holds a three-line warning ("There is no PIN recovery…"), two PIN fields,
and — when the entries disagree — an error line. On a small phone in landscape at 200% text it
overflows by **39 pixels**, and what falls off the bottom is the error message explaining what went
wrong, in the flow that sets the lock protecting every stored credential.

`scrollable: true` fixes it, which is the same answer as 112 and as ledger 80 before it.

**Why no test had ever seen this.** Every harness in `settings_screen_test.dart` uses a **1200x4000**
surface, deliberately — "thirty-odd rows across five sections; the default surface would leave most
of them unlaid-out". That is right for driving the screen and wrong for judging whether anything
fits. The dialog had never been laid out at a size a phone actually has.

**The geometry matters, and the first attempt was too generous.** At the emulator's landscape size
(914x411, from `1080x2400 @ 420dpi`) the dialog **fits** — the test passed and would have been
recorded as proof. Only at 640x360, an ordinary small phone in landscape, does it overflow. A device
sweep on this emulator would never have caught it; the emulator is a large device.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/settings_screen_test.dart` | 24 passed (+1) |
| Full host suite | **2,513 passed** |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, exit 0 — `20260812T031943Z_android_emulator-5554_core`. Confirmation only: this defect does not reproduce on the emulator at all, which is the point recorded above. |

**Negative control.** Removing `scrollable: true` fails *the PIN dialog fits a landscape phone at
200% text, error and all* with `A RenderFlex overflowed by 39 pixels on the bottom`.

**The twelve remaining unrendered branches** are listed here so this is a queue rather than an
anecdote: `fleet.dashboard.empty`, `healthScoring.error`, `infra.images.empty`,
`infra.networks.empty`, `infra.volumes.empty`, `monitor.scripts.empty`,
`monitor.scripts.output.error`, `network.error.dismiss`, `network.speedTest.error`,
`network.whois.empty`, `sftp.imagePreview.error`, `tunnels.empty`. Inspected: all are plain `Text`
inside contexts that already scroll, so none carries the shape that bit here — but "inspected" is
weaker than "rendered", and they are still unrendered.

### 112 — Infra's error state overflowed, because until defect 109 it was never shown (closed)

Found by the device surface sweep the moment 109 made the branch reachable. Ten failures, one shape:

```
light-200pc-text/landscape/infra: A RenderFlex overflowed by 49 pixels on the bottom.
[infra_screen.dart:224:14]
```

— every theme, landscape, 200% text, on Infra and its Images subtab.

**This is not a regression from 109; it is 109's fix revealing dead ground.** `_RuntimeError` was
only ever built when `vm.error != null`, and before 109 `load()` parsed `'SSH Error: …'` as data and
never set it. The widget existed, was reachable in principle, and **had never once been rendered** —
so its layout had never been exercised at any text scale or orientation. The surface sweep walks
every route in every theme and orientation and had been walking past it for the life of the port.

Fixed the way the empty states beside it were fixed for the same reason (ledger 80): the centred
`Column` becomes a `SingleChildScrollView`, so a tall error scrolls instead of overflowing.

**The test took three attempts, and the first two were vacuous.** Worth recording because both
failures were about *reproducing the condition*, not about the fix:

1. `tester.takeException()` returned null with the overflow still present. A `RenderFlex` overflow is
   reported through `FlutterError.onError` during paint, not thrown — the sibling test in this file
   already captures it that way, and I had not read it closely enough.
2. With the capture fixed, `Size(720, 150)` at 200% still did not overflow, even though it is
   *shorter* than the device. Height was never the variable: the message length was. `'connection
   refused'` wraps to one line; the device's
   `SSHChannelOpenError(2: open failed) while opening a session channel to …` wraps to several.

The test now uses the emulator's real landscape geometry (914x411 logical, from `1080x2400 @ 420dpi`)
and a message of the length this screen actually receives. Reverting the fix produces a 63px
overflow and fails it.

**The general lesson, which is the reason this entry is long.** A guard that is never reached hides
more than a bug: it hides the *entire branch behind it* from every test that walks the app. Defect
109 was one wrong behaviour; the code it kept unreachable had its own defect waiting. When a slice
makes dead code live, the surface sweep is not a formality — it is the first time anything has looked
at that code at all.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/infra_screen_test.dart` | 37 passed (+1) |
| Full host suite | **2,512 passed** |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, exit **0** — `20260812T030335Z_android_emulator-5554_core`. The surface sweep that found this defect now passes it, and the run reports "passed with no unexpected warnings": the allowlist doing its job on the same run that proves the fix. |

**Negative control.** Reverting `SingleChildScrollView` to `Center` fails *the transport-error state
scrolls on a short 200% landscape phone* with `A RenderFlex overflowed by 63 pixels on the bottom`.

### 110 — six concurrent probes exhausted the host's SSH session limit (closed)

The finding defect 109 exposed, now fixed rather than filed.

`InfraViewModel.load` issues six `exec` calls through one `Future.wait`, deliberately — "serialising
them multiplies the round-trip latency by six on exactly the screen a user opens to check something
quickly". Those six become six **channels on one pooled connection**, and the server decides how many
it grants: OpenSSH's `MaxSessions` defaults to **10**, and NAS firmware often ships lower. Six is
under ten alone, but the telemetry poller and the host-status probe share the same connection and the
server counts the total. Exceeding it does not queue — the server refuses, and dartssh2 raises
`SSHChannelOpenError(2: open failed)`.

**The fan-out is kept and bounded**, not reduced: `ChannelLimiter` caps concurrent `exec` and
`execStream` channels per pooled connection at **4**, and callers past the limit wait for a slot
instead of being refused. Infra's six probes still overlap, four at a time, so the latency argument
survives and the failure mode is removed rather than made rarer.

The limit is deliberately well under 10 because this limiter governs only `exec` and `execStream`:
interactive shells, SFTP subsystems and tunnels open channels on the same connection without passing
through it, so the budget has to leave them room. A limit of 8 would be "correct" against the default
and would still fail on a host with a shell open.

### 111 — nothing ever recorded that a host's credentials were wrong (closed)

`updateAuthState` existed on the repository **and** the DAO, and `grep -rn "updateAuthState" lib/`
found no caller outside those two definitions. Meanwhile the Hosts list already renders the result: a
warning row at `servers_screen.dart:649`, an amber badge at `:697`, and the words "authentication
failed" at `:869`. Every piece was built except the one that writes the column, so a host with a bad
key looked exactly like a healthy one however many times it failed. Compose writes it from the
telemetry loop (`ui/AppViewModel.kt:2409`).

Now written from the same place: `failed` with a described reason when the metrics probe returns an
`SSH Error`, `ok` when the host answers.

**A porting trap worth keeping.** The reason comes from `describeSshFailure`, ported from
`classifySshConnectionFailure` (`ui/AppViewModel.kt:388`) — and porting its needles **verbatim would
have matched nothing**. Compose classifies JSch's wording (`"Auth fail"`, `"USERAUTH fail"`); this
port sees dartssh2's (`SSHAuthFailError`, `SSHAuthAbortError`) — no space, different words. The first
run of the test proved it: `SSHAuthFailError` classified as `unknown`. The classifier now carries both
vocabularies, because the app still has to read Compose-era strings from an older database.

**A second trap, caught by a failing test.** The success path first wrote `ok` only when
`server.authStatus != 'ok'`. That field is a snapshot taken when the cycle began, so a row corrected
in the database mid-flight would keep an old `failed` **forever**. Now written unconditionally on
success — the poller already writes metrics and a history row in the same place, so one more small
update is proportionate.

**Evidence for 110 and 111.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/channel_limiter_test.dart` | 4 passed (new) |
| `test/ssh_failure_test.dart` | 5 passed (new) |
| `test/telemetry_poller_test.dart` | 18 passed (+2) |
| Full host suite | **2,511 passed** |
| `dart format --line-length 100` | 3 files reformatted, then clean |
| `--profile host`, `emulator-5554`, real fixtures | **passing — the first time it has on this device.** `20260812T023955Z_android_emulator-5554_host`, exit **0**, and the gate now reports "Device suite passed with no unexpected warnings". The suite that exposed 109 and 110 is the suite that now proves them. |

**Negative controls:**

| Mutation | Failing test |
|---|---|
| remove the auth-failure write | *is recorded as an auth failure the Hosts list can show* |
| remove the auth-success write | *a host that answers is recorded as authenticated again* |
| raise the channel limit to 99 | *the default leaves room under OpenSSH MaxSessions* |

The third was **vacuous on the first attempt**: every limiter test passed an explicit `maxConcurrent`,
so none pinned the default — the number that actually ships. Raising it to 99 left the file green. A
test asserting the default now exists. That is the eighth vacuous control this session and the second
of exactly this shape, after the replica cap: **a constant used only as a default parameter is
invisible to tests that always override it.**

### 109 — an SSH failure was parsed as output: an unreachable host shown as an empty one (closed)

The open finding above turned out to be a real defect rather than a flaky test, and reading it out
found two more of the same shape. All three have one cause: **`exec` reports failure by returning a
string, not by throwing.**

```dart
// data/ssh/dartssh_transport.dart
return 'SSH Error: command timed out';
return 'SSH Error: ${_describe(e)}';
return 'SSH Error: command failed ($exitCode): $detail';
```

Compose checks that prefix in **21 places**. Before this slice the port checked it in **one**
(`shell_view_model.dart:1065`, the tmux scrollback resync).

| Where | What the port did | What Compose does |
|---|---|---|
| `InfraViewModel.load` | parsed six error strings as data — no containers, no images, no runtimes, `_error` still null | `ui/AppViewModel.kt:6457` sets `dockerError` and clears the lists |
| `TelemetryPoller` OS probe | cached whatever `normaliseOs('SSH Error: …')` returns, **permanently** | `ui/AppViewModel.kt:2404` caches only on success |
| `TelemetryPoller` metrics | parsed the error string into a sample, wrote it to history and charted it | `ui/AppViewModel.kt:2408` branches and records the failure instead |

**Why the Infra one is worse than it sounds.** An unreachable host was presented as a host with
nothing on it. There is no error, no spinner, no retry prompt — just an empty Infra screen, which is
indistinguishable from a host that genuinely runs no containers. This is the same failure the SFTP
sudo-search comment already names in this codebase: *"a wrong answer wearing the clothes of a right
one."*

**Why the OS-cache one is worse still.** The OS is probed once per host and then trusted for the life
of the host. Caching what a *failed* probe normalises to means every later metrics command is the
wrong one — the poller's own comment describes the result: "output the parser reads as a host with no
memory and no disks". One transient failure, permanently wrong readings.

**How it was found.** The device host suite failed at `infra.runtimes` being empty while `infra.error`
was null. Two hypotheses were wrong before the right one: that `inspectedServer` was null (the test
inserts the server with `status: 'online'` and finds it), and that it was a mid-flight server change
(`selectedServerId` is stable across the call). The prefix check was found by looking for how failure
is *represented* rather than where it is handled.

**The reason the suite never caught it.** `RecordingTransport.failure` makes `exec` **throw**, and
every existing failure test uses it. The real transport never throws. The tests added here use
`fallback: 'SSH Error: connection refused'` instead, which is what the app actually sees.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/infra_view_model_test.dart` | 23 passed (+2) |
| `test/telemetry_poller_test.dart` | 16 passed (+2) |
| Full host suite | **2,500 passed** |
| `dart format --line-length 100` | `0 changed` |
| `--profile host`, `emulator-5554`, real fixtures | **still fails — and now says why.** `20260811T232022Z_android_emulator-5554_host`. Before this fix: `Expected: contains 'docker' / Actual: Set:[]` with `error` null. After: `docker runtime discovery failed: SSH Error: SSHChannelOpenError(2: open failed)`. Turning a silent empty screen into a named transport failure **is** what this defect was; the channel failure behind it is a separate finding, below. |

**Negative controls, each matched exactly once:**

| Mutation | Failing test |
|---|---|
| Infra ignores the prefix | *an SSH error returned as output is an error, not an empty host* |
| telemetry caches a failed OS probe | *is not cached, so one bad cycle does not misread the host forever* |
| telemetry parses metrics from an error string | same test — the metrics path feeds the OS cache too |

The third control failing the *same* test as the second is worth noting rather than smoothing over:
the two guards are not independent, because `parseMetrics` also writes the OS cache. One test covers
both paths into it, which is honest but means a future change could remove one guard and still pass.

### 108 — every file on a WebDAV share had no modification date (closed)

Two defects in one parser, found by taking the "does it exist at all" method down a level: after the
UI-control axes were exhausted, the same word-absence search was run over Compose's **view-model and
data-layer functions**. 344 public `AppViewModel` functions produced **zero** candidates — the port
is complete at that level. The 25 files under `data/` produced three, of which two were naming
differences (`formatThrowable`, `execOnceJumped` — both features present, both implemented at least
as well; Flutter's jump-host handling carries the same "never pooled" reasoning as Compose's). The
third was `parseMultistatus`, and reading the two parsers side by side found this.

**The date, which is the one that bit every user of every WebDAV share.**

```dart
final modified = DateTime.tryParse(text('getlastmodified'));   // always null
```

`getlastmodified` is an **HTTP-date** — RFC 4918 says so — and `DateTime.tryParse` parses ISO 8601.
It returns null for `Tue, 11 Aug 2026 10:00:00 GMT`, so `modified?.millisecondsSinceEpoch ?? 0` made
every entry's time **zero**. The listing showed no date, and sorting by date ranked every file equal
while looking like it had worked. Compose parses it with an explicit RFC 1123 format
(`data/shares/WebDavFsClient.kt:215`).

Confirmed against the live fixture rather than argued from the spec — `PROPFIND` on the lab's rclone
server returns:

```
<D:getlastmodified>Tue, 11 Aug 2026 16:27:24 GMT</D:getlastmodified>
```

`parseWebDavDate` now reads RFC 1123 and still falls back to ISO, because a few servers send it
despite the spec.

**The href, which bites only some servers.** RFC 4918 allows `<D:href>` to be an absolute URL or an
absolute path, and real servers send both. The port compared the raw href against the requested path:

```dart
final href = Uri.decodeComponent(text('href')).replaceFirst(RegExp(r'/+$'), '');
if (href == wantedPath || href.isEmpty) continue;      // never true for an absolute URL
```

Against a server answering with absolute URLs, the collection never matched itself and **appeared as
an entry inside its own listing**. Compose strips the scheme and authority first (`hrefToPath`).
`webDavHrefToPath` now does the same.

**Stated rather than implied:** the lab's rclone server sends *relative* hrefs, so this second fix is
not exercised by the fixture. It is a spec-conformance fix verified by unit test only, and the ledger
should not pretend otherwise.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/webdav_remote_fs_client_test.dart` | 10 passed (+8) |
| Full host suite | **2,496 passed** |
| `dart format --line-length 100` | 2 files reformatted, then clean |
| Live `PROPFIND` against the lab | RFC 1123 confirmed as what the server actually sends |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, Patrol included — `20260811T225648Z_android_emulator-5554_core`. Script exit 3 is the warning gate on the upstream KGP warning alone. |
| `--profile host`, `emulator-5554`, real fixtures | **failed, for an unrelated reason** — Infra runtime discovery, not the WebDAV client; see the open finding above (`20260811T225534Z_android_emulator-5554_host`). This fix is therefore **not** fixture-proven end to end on device; the live `PROPFIND` above is the strongest evidence it has. |

**Negative controls, each matched exactly once:**

| Mutation | Failing tests |
|---|---|
| date parser falls back to `DateTime.tryParse` alone | *an RFC 1123 date is parsed*, *a single-digit day and every month name are handled* |
| stop stripping scheme and authority from an href | all three href tests |

One test asserts the bug directly — `expect(DateTime.tryParse('Tue, 11 Aug 2026 10:00:00 GMT'), isNull)`
— so the reason this code exists cannot quietly stop being true.

**A wrong turn:** `Uri.decodeComponent` throws `ArgumentError`, not `FormatException`, for a stray
`%`. The first `on FormatException` catch let a malformed href crash the whole listing instead of
being used verbatim. Caught by the test written for exactly that case.

### 107 — a network share could not be searched at all (closed)

The first **missing feature** the audit has produced, as opposed to a missing rule, and the only one:
every other unmatched control turned out to be a wording difference.

**How it was found, and why the method mattered.** 334 Compose controls had no Flutter peer by label,
which is far too many to read. Instead of eyeballing them, every distinctive word of each label was
checked against the whole of `flutter_app/lib`: a label whose words appear *nowhere* in the port is a
candidate for something that was never built, while a label that appears under different wording is
noise. That reduced 250 distinct labels to **three**, and two of those were interpolated strings
(`${draftIntervalSec}s`, `via $srvName`). The third was Compose's `Wildcards * ?` chip, which sits
beside a `Recursive` chip in the **share search** — and pulling that thread found the feature behind
it missing entirely.

**The defect.** Compose searches a share by walking it (`runShareSearch`, `ui/AppViewModel.kt:8007`),
because a share is not a shell — SMB, FTP, WebDAV and NFS have no `find` to run. Flutter's search
refuses outright when a share is open:

```dart
if (ssh == null || server == null || _browsedShare != null) return;   // searchHost
bool get canSearchHost => canMeasureSize;                             // ... && _browsedShare == null
```

The guard and the button agreed with each other, so nothing looked broken: the control simply was not
rendered while browsing a share. **There was no way to search a network share in this port**, and no
error to say so — the single most invisible kind of gap, and the reason a control-level inventory was
worth building at all.

**The port.** `searchShare` walks breadth-first from the current folder, bounded exactly as Compose
bounds it — `shareSearchMaxHits = 500` results and `shareSearchDirBudget = 4000` directories — sets
`searchTruncated` when either runs out, skips a directory it cannot list rather than failing the
whole search, and abandons the walk if the user closes the share underneath it. Results reuse
`RemoteSearchHit` and `openSearchHit`, so a hit opens the same way a host hit does.

**One deliberate divergence.** Compose asks the user to declare wildcard mode with a chip; this port
infers it, following the rule `remoteSearchCommand` already uses for host search — a query carrying
`*` or `?` is a pattern, anything else matches anywhere in the name. That is one less control for the
same answer on every query except a literal search for an asterisk, and it keeps the two search paths
in this app consistent with each other, which matters more than matching Compose's chip count.
Metacharacters are escaped, so `notes(1)*` finds `notes(1).txt` instead of quietly meaning something
else.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/sftp_view_model_test.dart` | 146 passed (+7) |
| Full host suite | **2,488 passed** |
| `dart format --line-length 100` | 1 file reformatted, then clean |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, Patrol included — `20260811T223244Z_android_emulator-5554_core`. Script exit 3 is the warning gate on the upstream KGP warning alone; no warning from this app. |

**Negative controls, three, each matched once and each failing its own test:**

| Mutation | Failing test |
|---|---|
| stop descending into subdirectories | *the walk descends and finds a match several levels down* |
| let an unlistable directory abort the search | *a directory that cannot be listed does not fail the whole search* |
| stop escaping regex metacharacters | *regex metacharacters in a query are literal, not operators* |

**Two wrong turns worth recording**, because both were caught by tests failing rather than by
reading. The trees were first keyed at `/media`, but `ShareClients.startPath` consumes an SMB share's
first path segment into the connection, so the walk starts at `/` — the tests returned empty until
the fixtures matched what the app actually does. And `canSearchHost` was asserted true in a
`booted()` session that has no SSH transport at all, which it never could be.

### The audit's first false positive: Monitor and the offline host (no defect, change reverted)

Recorded in full because it is the failure mode this whole audit is most exposed to, and because I
had already written the fix, the test and the ledger entry before catching it.

Compose gates command execution on reachability in two places:

| Control | Compose gate |
|---|---|
| Run (one-off command) | `customCommand.isNotBlank() && srv.status == "online"` (`ui/MonitorScreen.kt:199`) |
| a saved script's card | `.clickable(enabled = srv.status == "online")` (`ui/MonitorScreen.kt:240`) |

Flutter checks only `server == null` in both, and `grep -n status` over
`ui/screens/monitor/scripts_tab.dart` returns **nothing**. That reads as a clean two-for-one defect,
and it is not one:

```dart
Server? get monitoredServer {
  final online = _app.servers.where((s) => s.status == 'online');   // <- already filtered
  ...
}
```

Every `server` in that file comes from `monitoredServer`, which only ever yields an online host. So
`server != null` **is** "an online host is selected", and the gate I added — `server != null &&
server.status == 'online'` — was a tautology. The two apps enforce the same rule at different
altitudes: Compose per control, Flutter once at the source.

**How it was caught.** Not by review — by the test failing for the wrong reason. `openScripts` could
not find the tab strip, because with only an offline host Monitor renders no tabs at all. The
scenario I had written was unreachable, which is what a tautological guard looks like from the test's
side. The change and its test are reverted; `git diff` on `scripts_tab.dart` is empty.

**The rule this adds to the audit.** The extractor compares *controls*, and a control's gate is only
half the story — the other half is what the values feeding it can be. Four defects (101, 103, 105,
106) were real because the guarded thing really could reach a bad state. This one was not, and the
difference is invisible at the control. **Follow the value to its source before believing a missing
gate.** The ledger has said "follow the call chain" since the early entries; this is the first time
skipping it produced a fix rather than a wrong conclusion, which is worse.

No defect number is assigned, and the count is unchanged.

### More of the unlabelled gated set, cleared on inspection

Six more Compose gates read against their Flutter peers, all matching. Recorded because the audit is
only worth anything if the clears are as visible as the hits:

| Compose gate | Flutter | Verdict |
|---|---|---|
| `ToolsScreen.kt:2306` `alias.isNotBlank() && !sshKeygenRunning` | `_alias.text.trim().isEmpty \|\| _running` | identical |
| `ToolsScreen.kt:3119` `checked \|\| selectedIds.size < effectiveMax` (free-tier restore cap) | `_atCap && !_hostIds.contains(...)`, with the cap explained above the list | identical, and Flutter says it before the boxes grey out |
| `SftpScreen.kt:325` `!scanning` on the protocol chips | `onSelected: vm.scanning ? null` | identical |
| `SftpScreen.kt:459` `enabled = browsable` on Browse | button hidden, reason rendered as visible text | different shape, and Flutter's reason is on screen rather than only in a content description |
| `SftpScreen.kt:3221` `.clickable(enabled = available)` on an endpoint bookmark | `onTap: available ? … : null` plus the same 0.38 opacity | identical |
| `ToolsScreen.kt:1265` quick-script Save | Compose disables the button; Flutter validates on submit and shows *why* (`Name is required.`, `Offer this script in Quick scripts, Fleet commands, or both.`) | **not a defect** — the three rules are all present in `saveScript`; only the affordance differs, and the one that names the problem is the better of the two |

That last row is worth keeping as a rule for this audit: **a missing `enabled=` is not automatically
a defect.** It is a defect when the action behind it can do damage (101, 103), when it routes around
a rule the app keeps elsewhere (107), or when the form hides the field that would fix it (106). Where
the alternative is an explicit message, it is a design difference.

### Working the unlabelled set

167 Compose controls carry no extractable label. **31 of them carry a gate**, and those were worked
first on the evidence of defects 101 and 105 that a gating divergence is where the damage is. Two
defects out of the first pass (105, 106).

**Cleared on inspection**, recorded because a row that is checked and dismissed is a result too, and
because the reasons say something about where the port diverges *safely*:

| Compose gate | Verdict |
|---|---|
| `ToolsScreen.kt:4497` `scoringError == null` | **No defect.** Compose chains four `firstError`s by hand; Flutter's `validateAll` iterates `HealthMetric.values`, which is the same rule expressed once instead of four times. Flutter additionally requires `isDirty` — extra scope, and the better behaviour. |
| `AppUi.kt:207` `checkedForSplit \|\| splitSelection.size < 2` | **No defect.** Compose caps a checkbox multi-select at two panes; Flutter models the same feature as `splitWith(id)` — one companion session — so the limit is structural rather than enforced. A different shape, not a missing rule. |

Still unexamined, so the next pass starts with a queue rather than a number: `ToolsScreen.kt:1265`
and `:1258` (quick-script name and command), `:2306` (`alias.isNotBlank() && !sshKeygenRunning`),
`:3119` (`canAdd`), `SftpScreen.kt:325` (`!scanning`), `:459` (`browsable`), `:3221` (`available`),
`MonitorScreen.kt:190` and `:240`. The remaining 136 unlabelled controls carry no gate at all and are
the lower-yield tail.

### Never run `flutter test` and a device sweep at the same time on this box (closed, operational)

Worth recording because it manufactures a device failure that looks exactly like a real one, and the
next person to hit it will spend the time I did.

The `20260811T193504Z` sweep reported `app_actions_test.dart` failing to load with
`Gradle task assembleDebug failed with exit code 1`, under:

```
* What went wrong:
Gradle build daemon disappeared unexpectedly (it may have been killed or may have crashed)
```

Cause, from the kernel log rather than inference:

```
Out of memory: Killed process 2977062 (java) total-vm:15786092kB, anon-rss:6025592kB
```

I had launched the sweep in the background and then run the full host suite in the same project. On
this 18 GB machine the Gradle daemon (`-Xmx4g`, per [[dev-machine-toolchain]]), the Kotlin compile
daemon (another 4 GB) and `flutter test`'s isolates do not fit together. The two also share
`flutter_app/build/` and `.dart_tool/`, which is a second reason not to overlap them.

**The failure was not in the app and not in the test.** Re-run serially, the file loads. The lesson
is narrow: device sweeps are exclusive on this host — nothing else may touch the project while one
runs, and a device failure whose message mentions the daemon disappearing should be re-run before it
is believed.

### The device warning gate now has a narrow allowlist (closed)

Carried as "needs a decision" for three slices. Decided: an allowlist, not `--allow-warnings`.

That flag suppresses *everything*, and a gate routinely passed with a suppression flag has stopped
being a gate. The allowlist names the one upstream warning this app cannot fix from its own source —
Flutter warning that `flutter_file_dialog`, `flutter_foreground_task`, `home_widget` and `patrol`
apply the Kotlin Gradle Plugin — and **anything else still fails the run**.

Verified to discriminate rather than assumed. Against a log holding only the known warning it reports
0 unexpected lines; against the same log plus an `unused_local_variable` warning it reports exactly 1
and names it. The run also now distinguishes "no warnings" from "only known upstream warnings", so a
reader can tell which they are looking at — the `20260812T023955Z` host run prints the latter.

**The plugin upgrade is not available**, which was worth establishing rather than carrying as an
open debt. All four are already pinned at the newest version published:

| Plugin | Locked | Latest on pub.dev |
|---|---|---|
| `flutter_file_dialog` | 3.3.2 | 3.3.2 (18 days) |
| `flutter_foreground_task` | 10.0.0 | 10.0.0 (28 days) |
| `home_widget` | 0.9.3 | 0.9.3 (2 months) |
| `patrol` | 4.8.0 | 4.8.0 (18 days) |

So there is nothing to upgrade *to*: none of them has shipped a build-tools-compatible release yet,
and the warning cannot be cleared from this repository at all. The allowlist is not a stopgap for
work we are putting off — it is the only correct response until upstream moves, and it keeps the
warning visible in every log meanwhile.

Flutter's own guidance is to "report the issue to the plugin" authors. Filing four upstream issues is
an outward-facing action and is left for the maintainer to decide, not taken here. Re-check the
versions when a future Flutter actually refuses the build; the warning says that day is coming, not
that it has arrived.

### 104 — two SFTP file operations could run at once, and the last one decided what you were told (closed)

Second row out of the control audit. **The entry as first written was wrong and is corrected here**,
because the correction is the useful part.

It claimed the Flutter SFTP view model had "no concurrent-operation guard — one line, `isSearching`".
That was an artefact of the grep: it searched for `isBusy|opRunning|transferRunning|busy` and the
flag is called `_loading`. It exists, it is exposed as `loading`, and it already gates Upload,
Refresh and Paste (`sftp_tabs.dart:733, 785, 823`) exactly as Compose does. A name-shaped search
found a name-shaped absence.

**What was actually wrong, once read rather than grepped**, is narrower and still real:

- The per-file context menu (`sftp_tabs.dart:1277`) was gated on file *type* only —
  `if (!entry.isDirectory)`, `if (vm.canArchive)` — never on whether an operation was in flight.
  Compose gates Rename, Delete and Download on `!shareOpRunning` / `!shareTransferRunning`
  (`ui/SftpScreen.kt:1118-1139`).
- `_mutate` set `_loading = true` but never checked it on entry, so it was re-entrant.

Those compose into the defect. Delete file A; while it runs, open the menu on file B and delete that
too. Both calls enter `_mutate`. Each one, on finishing, sets `_loading = false`, calls `refresh()`
and overwrites `_error` and `_status` — so **whichever returns last decides what the user is told**.
A delete that failed is reported as a success because the operation beside it worked, and the listing
refreshes mid-flight while the other mutation is still running.

**Fixed with both guards**, the same shape as defect 103: `enabled: !vm.loading` on the menu for the
affordance, and `if (_loading) return;` at the top of `_mutate` for the boundary. The menu gate alone
would leave every other caller of `_mutate` re-entrant; the boundary alone would leave a menu that
looks live and silently does nothing.


**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/sftp_view_model_test.dart` | 139 passed (+2) |
| Full host suite | **2,469 passed** |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, Patrol included — `20260811T195106Z_android_emulator-5554_core`. Script exit 3: the suite passed and the *warning gate* failed, on the upstream KGP warning alone (see the gate note above); no warning from this app. |

**Negative control.** Removing `if (_loading) return;` — matched exactly once — fails *a second
delete issued mid-flight is refused rather than interleaved*, with the second path appearing in
`client.deleted`. The companion test (*a delete issued after the first finished still runs*) passes
either way by design: it is there to catch the opposite mistake, a guard that never releases.

### 103 — the editor's Replace button overwrote whatever the user had selected (closed)

Found by the control-by-control audit the user asked for after defect 101 — "every single button
every single option every single toggle" — and specifically at the granularity they named: not "does
Flutter have a find bar" but "does each control carry the same enabling condition as its Compose
peer". It is the first defect out of that audit.

**The divergence.** Compose gates four controls on one condition (`ui/CodeEditor.kt:582-596`):

```kotlin
IconButton(onClick = onPrev, enabled = matchCount > 0)
IconButton(onClick = onNext, enabled = matchCount > 0)
TextButton(onClick = onReplace,    enabled = matchCount > 0)
TextButton(onClick = onReplaceAll, enabled = matchCount > 0)
```

Flutter gated none of them. Three survived that anyway, because they re-check internally —
`_selectMatch` returns on `matches.isEmpty`, `_replaceAll` returns on an empty query. Those three
were a missing affordance: the buttons looked live and did nothing.

**`_replaceCurrent` was the real one.** It never consulted the search at all:

```dart
final selection = widget.controller.selection;
if (!selection.isValid || selection.isCollapsed) return;
// ...replaceRange(selection.start, selection.end, _replacement.text)
```

Its only precondition was *some non-empty selection exists* — and in a text editor there is nearly
always one. So: open Find, type a query that matches nothing, select a line by hand as anyone editing
would, press Replace. Flutter deleted the selection and substituted the replacement text. Compose
could not: the button was disabled.

That is silent data loss in an editor, from a button whose label promises a search-and-replace, and
it is the same shape as defect 101 — **a control offered as available while the operation behind it
was not valid.** The audit was built to find exactly this shape and this is what it returned first.

**Fixed with both guards, deliberately.** The button gate (`count > 0`) restores parity with Compose
and the honest affordance. The check inside `_replaceCurrent` — that the selection *is* one of the
matches — is the boundary, and it holds for a case the gate cannot reach: matches exist, so the
button is live, but the selection is the user's own rather than one `_selectMatch` produced. Compose
has the gate and not the boundary, so it still mis-replaces a hand-made selection when the query
matches something else. Recorded rather than ported: Kotlin is the app being retired, and the Flutter
behaviour is the correct one.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/code_editor_test.dart` | 9 passed (+3) |
| Full host suite | **2,467 passed** (was 2,464) |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` (API 35) | **24 passed**, Patrol included — `20260811T195106Z_android_emulator-5554_core`. Script exit 3: the suite passed and the *warning gate* failed, on the upstream KGP warning alone (see the gate note above); no warning from this app. |

**Negative controls, both non-vacuous.** Each mutation matched exactly once and failed exactly the
test that covers it:

| Mutation | Failing test |
|---|---|
| drop `if (!selected) return;` | *Replace ignores a hand-made selection even while matches exist* |
| drop `count > 0 ?` on the Replace button | *Replace leaves a hand-made selection alone when the query matches nothing* |

The first control is why a third test exists. The two tests written first both passed with the
boundary check removed — the button gate alone satisfied them — which would have shipped an
unexercised guard and recorded it as tested. That is the sixth time this session a control has caught
a vacuous test, and the pattern is always the same: the test reached the *outer* guard and never the
inner one.

### The tool that found it

`scripts/parity_controls.py`. `scripts/inventory.py` already walked composables and screens, which is
why it never found this: both apps plainly "have" a code editor. The new script walks **controls** —
buttons, switches, checkboxes, sliders, fields, menu items, taps, long-presses, drags — and records
each one's label and its enabling condition, then pairs the two sides by normalised label.

Two faults in the first run are worth keeping, because both made the tool confidently wrong:

- **It reported 70 suspects out of 70 gated controls.** A 100% hit rate is not a finding, it is a
  broken comparison. Dart rarely writes `enabled:`; it writes `onPressed: cond ? action : null`.
  The tool saw no gate on any Flutter control because it was looking for the Compose idiom.
- **Compose labels are `R.string` keys**, so every resource-labelled control looked absent from
  Flutter. The very first "missing" row, `connect_non_resumable`, has a peer in
  `connection_prompt_host.dart:171` — correctly gated on the same condition. Resolving the keys
  through `res/values/strings.xml` fixed it.

After both fixes: 70 gated-and-labelled Compose controls, 38 with no Flutter peer found, **15 whose
peer carries no gate**. Defect 103 came out of those 15. The remaining rows are the queue, and they
are questions rather than defects — several are label collisions where a generic word like "All" or
"Password" matched the wrong widget on the other side.

Counts as of this entry: **692 Compose controls / 627 Flutter**, and 301 Compose controls carry no
extractable label at all — those need reading by hand and are not yet covered by anything.

### The tmux copy-mode exit is dead on both sides (closed, no defect)

Entry 99 left `tmuxExitCopyModeCommand` ported but unreferenced and called it "a separate slice".
It is not a slice — it is nothing, and the check that settled it took one grep.

**Kotlin's caller does not exist.** `terminalJumpToLiveTail` and `terminalJumpToLiveTailFor`
(`ui/AppViewModel.kt:6291`) have no callers. Nor does `terminalMouseWheel`, nor
`terminalTmuxScrolledBack`, nor `clearTerminalTmuxScrolledBack`. The whole cluster — forward the
wheel to tmux, remember that the pane went into copy-mode, offer a jump-to-tail that cancels it — is
unreachable in the app it was written for.

**And the reason is already written down, twice.** `terminal_surface.dart:271` records it as settled
design: "the Kotlin settled on tracking the local buffer rather than forwarding wheel events to
tmux, because the forwarded version had inconsistent direction and never quite reached the bottom."
`TERMINAL_COMPATIBILITY.md` states the same outcome as a contract: "Touch gestures operate local
scrollback; tmux mouse mode is disabled for app-created persistent sessions."

So the copy-mode exit is the tail of an approach Kotlin **abandoned**. Nothing puts the pane into
copy-mode any more, because nothing forwards the wheel, so nothing needs to take it out.

**What was done: the command was removed**, along with its test. It was added one slice earlier as
part of ledger 99 and never acquired a caller. Keeping it would have been the twelfth unreferenced
primitive in this codebase, and this time with the extra insult of mirroring dead code on the other
side — a port of an abandonment.

**Evidence.** `flutter analyze --fatal-infos` clean; **2,462 passed** (-1, the removed test);
`dart format --line-length 100` reports `0 changed`. No device sweep: the only change is a deletion
of code nothing reached, and the suite proves nothing reached it.

**The lesson, since this is the third time.** A missing caller in *this* port is a defect. A missing
caller in **both** ports is a decision somebody already made, and the way to tell them apart is to
grep the other side for callers before writing anything. Entry 99 assumed the second case was the
first, and would have shipped dead code on the strength of it.

### 99 — a reattached tmux session lost its history (closed)

The third `TERMINAL_COMPATIBILITY.md` claim to fail, and the first that is a **missing feature**
rather than a wiring bug. **No fix in this slice** — the honest reason is below.

The doc claimed, under "Standard persistent tmux | Supported": "App-created session, bounded
history, reconnect/reattach, **capture-based history recovery**". The first three are real. The
fourth does not exist in this port.

**What Kotlin does.** When a persistent session is scrolled up after a reattach, it streams the
pane's history over a side exec channel and merges it into local scrollback:

| Piece | Kotlin | Flutter |
|---|---|---|
| The command | `RemoteCommands.tmuxCaptureHistoryCommand` (`data/RemoteParsers.kt:280`) | **absent** |
| The capture | `captureTmuxHistoryFull` — `execStream` with a byte budget of `scrollbackLimit * 300 + 65_536`, trimming from the front (`ui/AppViewModel.kt:4884`) | **absent** |
| The trigger and bookkeeping | dirty flag cleared *before* the capture so mid-capture output re-arms it, a `tryLock` so two scroll-ups do not race, a geometry generation so a resize mid-capture is discarded (`:4970`) | **absent** |
| Snapping the pane back to the live tail | `tmuxExitCopyModeCommand` (`RemoteParsers.kt:293`), sent over exec rather than typed, because a typed `q` lands at the shell prompt as a letter if the pane already left copy mode | **absent** |

**The alternate-screen guard is the part worth reading.** The command is wrapped in a
`#{alternate_on}` test, with the reason recorded from a real observation: while a full-screen TUI
owns the alternate screen, `capture-pane` returns TUI frames rather than the primary screen's
history — verified on tmux 3.3a — which would seed local scrollback with stale `vim` junk. Empty
output leaves the caller's dirty flag armed so it retries once the TUI exits.

That guard is also the answer to a loose end from the emulator sweep that started this slice:
`isAlternateScreenActive` is the one piece of emulator state with **zero consumers** in `lib/`, and
Kotlin's only consumer of its equivalent is exactly this capture guard (`ui/AppViewModel.kt:4981`).
The getter is not dead code — it is the missing feature's missing caller.

**Why no fix here.** This is four coupled pieces — a guarded command, a budgeted streaming capture,
merge-into-scrollback, and concurrency bookkeeping — landing in the terminal session core. Porting
only the command builder would add exactly the unreferenced, unit-tested, never-called code this
ledger has recorded eleven times; porting the capture without the dirty-flag and geometry
bookkeeping would produce a race whose symptom is corrupted scrollback. It needs its own slice, with
the persistent-tmux fixture driving a real reattach.

**What was done.** The doc no longer claims the feature. `TERMINAL_COMPATIBILITY.md` now states the
gap and points here, because a shipped document asserting a capability the app lacks is the same
defect as a switch that does nothing (ledger 95) — and unlike the compression switch, this one is
buildable, so the sentence is a placeholder until it is.

**Sized properly (2026-08-11), and the plan changed as a result.** An attempt to start the port
established what already exists, which is more than the entry assumed:

| Piece | State |
|---|---|
| `TerminalEmulator.adoptScrollbackFrom` | **Already in Flutter, unreferenced.** Kotlin's only callers are this feature (`ui/AppViewModel.kt:5021` and `:5407`). |
| `scrollbackRowCount()` | present |
| A standalone `TerminalEmulator(cols:, rows:, scrollbackLimit:)` for the scratch re-parse | present |
| `ShellSession` viewport anchor that survives trimming | present |
| `tmuxCaptureHistoryCommand`, `tmuxExitCopyModeCommand` | absent |
| The capture, the swap, the trigger, the guards | absent |

So the port is smaller than four fresh pieces — but it is still one vertical, and it must land as one.
Both command builders were written during this slice and **reverted before finishing**: with no
caller they would have been the twelfth instance of the unreferenced-code defect this ledger keeps
recording, which is precisely what this entry warned against.

**What the swap actually does**, read from `ui/AppViewModel.kt:4998`, since the entry only had the
shape of it:

1. A scratch emulator at the *live* grid's cols/rows and the configured scrollback limit.
2. Feed the capture with `\n` → `\r\n`, then a screen-height of `\r\n` so the tail rows are pushed
   off the scratch screen and its scrollback holds everything.
3. Under the emulator lock, re-check the alt state **and** the geometry generation; if either moved,
   leave the dirty flag armed and abandon the capture rather than trust it.
4. `adoptScrollbackFrom(scratch)`, then shift `viewportFirstRow` by the row delta so the content
   under the user's finger does not move.
5. Publish on every adoption, not only when the count changed — a replacement can fix gaps and
   colours while keeping the same number of rows.

**The doc that pointed the wrong way.** `adoptScrollbackFrom` carried a comment saying it was "used
when a reconnect replaces the live session". Nothing reconnects through it in either app; the
sentence described a plausible caller rather than a real one, which is worse than a stale reference
because it makes dead code look wired. Corrected to name the caller it is actually waiting for.

**Also absent, same area:** `tmuxExitCopyModeCommand`. Kotlin sends it when the user scrolls back to
the bottom so the pane snaps to the live tail; without it a Flutter session left in tmux copy mode
stays there.

**Evidence.** `grep -rn "tmuxCaptureHistoryCommand\|captureHistory" lib/` and the same for
`tmuxExitCopyModeCommand` return nothing; `capturePane` in `data/term/tmux_control_commands.dart:68`
is referenced only by its own tests. Entry 9 closed the *input* half of that file — `sendKeysHex`
and `refreshClientSize`, both named in it — and `capturePane` was never part of that fix.

## Closed (2026-08-11)

Ported as one vertical, as this entry insisted. What each piece became:

| Kotlin | Flutter |
|---|---|
| `RemoteCommands.tmuxCaptureHistoryCommand` | `tmuxCaptureHistoryCommand`, guard and 1,000–50,000 clamp included |
| `tmuxExitCopyModeCommand` | ported alongside it |
| `captureTmuxHistoryFull` byte budget | `execStream` with the same `limit * 300 + 65_536`, trimming from the front |
| dirty flag / `tryLock` / geometry generation | `ShellSession.scrollbackDirty`, a `_resyncing` single-flight, and a cols/rows re-check |
| `adoptScrollbackFrom` + viewport shift | `ShellSession.adoptScrollback`, which moves `_anchorRow` by the delta |
| the scroll-up trigger | `TerminalSurface.onScrolledBack`, fired only on a backward drag with the flag armed |

**The ordering that is not obvious**, taken from `ui/AppViewModel.kt:4987`: the dirty flag is cleared
**before** the capture, not after. Output arriving mid-capture re-arms it, so the next scroll retries
rather than trusting a capture that missed those rows. Clearing afterwards would swallow exactly the
rows the feature exists to recover.

Three things leave the flag armed instead of adopting: an **empty** capture (the `#{alternate_on}`
guard firing, so a TUI owns the pane and its frames are not history), a **grid change** between
taking the capture and applying it (the rows would be re-wrapped to the wrong width), and any
**exception** (a capture that could not run is not evidence the history is gone).

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/tmux_scrollback_resync_test.dart` | 5 passed, all new |
| `test/shell_view_model_test.dart` | 46 passed (+3) |
| Full host suite | **2,463 passed** (+8) |
| `dart format --line-length 100` | `0 changed` |
| `--profile core`, `emulator-5554` | **29 passed, no warnings** — `20260811T173545Z_android_emulator-5554_core` |

**Negative controls**, each asserting the mutation matched exactly once. Dropping the re-arm on an
empty capture fails `an empty capture leaves the flag armed, so a later scroll retries`. Removing the
`tmuxName == null` guard fails `a session that is not persistent is never captured` with
`Expected: <0>, Actual: <1>` — a command sent per scroll gesture on an ordinary PTY.

**A wrong assertion, corrected rather than accommodated.** The first version of the adoption test
expected a positive row delta and got **-35**. That was the test being wrong, not the code: the
capture replaces the scrollback *wholesale*, so a capture shorter than the local buffer legitimately
shrinks it. Rewritten to assert the rows themselves — `pane-history-0` and `pane-history-89` present
after the swap — which is the property that matters, with the count left as a secondary check on a
capture deliberately made longer than the client's own buffer.

**What is still not proven.** No device or fixture test drives a real reattach: the wiring, the
guards and the swap are covered against a fake transport, but "tmux collapsed output and the pane
still had it" has not been reproduced against a live tmux. The persistent-tmux fixture is the place
to do it, and `tmuxExitCopyModeCommand` was removed in the slice above this entry: its
Kotlin caller does not exist either, and the behaviour it served was abandoned on both sides.

### 98 — a hardware keyboard's Ctrl and Alt did nothing (closed)

The second claim from `TERMINAL_COMPATIBILITY.md` checked against this port: "Hardware keyboard |
Supported | Navigation, Insert/Delete, Page Up/Down, F1–F12, **explicit Ctrl-byte mappings, xterm
modifiers, and Alt-prefixed input** are encoded; **Ctrl+Alt is reserved for AltGr**".

The *encoder* is faithful — `terminal_key_encoder.dart` and `ui/TerminalKeyEncoder.kt` are the same
function, key for key, modifier for modifier. The defect is that nothing told it which modifiers
were held. `_onKey` mapped the special keys, sent `event.character` for everything else, and never
asked `HardwareKeyboard` anything:

| With a keyboard attached | Kotlin | Flutter before |
|---|---|---|
| Ctrl+C | `0x03` | the letter `c` |
| Ctrl+Left | `CSI 1;5D` | `CSI D` — a bare Left |
| Alt+b | `ESC b` | the letter `b` |
| AltGr+q (`@` on many layouts) | typed as text | typed as text |

Kotlin assigns the event's modifiers into the view model before every physical key
(`ui/ShellScreen.kt:2322`) and again before a Ctrl/Alt chord (`:2363`); `sendKey` and `typeText`
read those fields and clear them, so a modifier applies to one keystroke and then goes. The port had
the same fields — used only by the on-screen key bar — and the hardware path never wrote to them.

**Fix.** `applyHardwareModifiers` writes the event's modifiers into that same state, OR-ed with any
latched sticky ones, so an unmodified hardware key cannot drop a modifier the user latched on screen.
The chord path takes the letter from `event.logicalKey.keyLabel` when `character` is null — a Ctrl
chord suppresses the text on most platforms, which is exactly why the old code fell through — and
leaves Ctrl+Alt alone, because Android reports AltGr that way and an international layout typing `@`
must not be read as a control chord.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/shell_screen_test.dart` | 52 passed (+4) |
| Full host suite | **2,450 passed** (+4) |
| `dart format --line-length 100` | `0 changed` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T122537Z_android_emulator-5554_core` |

**Negative controls**, each asserting the mutation matched exactly once. Dropping the modifier
assignment before `sendKey` fails `Ctrl+arrow carries the xterm modifier`
(`Expected: ends with '[1;5D', Actual: 'ESC[D'`). Disabling the chord branch fails `Ctrl+C sends the
interrupt byte` with `Expected: [3], Actual: [99]`.

That `[99]` is worth keeping: in the test harness the old code sent a literal **`c`** for Ctrl+C. On
a device `event.character` is usually null for a Ctrl chord, in which case it sent nothing at all.
Both are wrong and the tests pin the fix, but only the harness behaviour was observed here — the
device behaviour is inference from the platform's documented handling, not something this slice
measured.

**Not covered.** A real keyboard. The suite drives `HardwareKeyboard` through Flutter's test
bindings, which is the same state the widget reads, but AltGr specifically depends on how Android
reports a physical international layout — the case Kotlin's comment exists for. The fourth test
asserts an unmodified key is still plain text, which is the regression that matters if the chord
branch ever grows too greedy.

### 97 — pastes were never bracketed, on a shell that asked for them to be (closed, **safety**)

`TERMINAL_COMPATIBILITY.md` has been carried since the Kotlin era with a note in the handover that
nobody had checked it against the Dart emulator. This slice checked five of its claims. Four held.
The fifth was the one that mattered.

| Claim | Verdict |
|---|---|
| OSC "safely ignored… OSC 52 cannot write the Android clipboard" | **True.** `terminal_parser.dart:144` consumes the sequence to its BEL or ST terminator and acts on none of it. |
| Mouse reporting "not supported" | **True.** No DECSET case for 1000/1002/1003/1006/1015 exists. |
| Focus reporting "not supported" | **True.** Nothing in `lib/data/term` emits focus events. |
| Alternate screen "DEC 47/1047/1049" | **True.** All four cases present, 1048 included. |
| Bracketed paste "DECSET 2004 is **tracked and pasted blocks are wrapped** with the standard begin/end markers" | **Half false, and the wrong half.** |

The mode was tracked — `_bracketedPasteMode`, set from DECSET 2004, with a doc comment saying
pasted blocks are wrapped. Nothing outside the emulator ever read it. `encodePastedText` normalised
newlines to CR and sent the bytes raw, so **every paste reached the remote as plain typing**.

That is the one thing bracketed paste exists to prevent. A shell that turns 2004 on is asking for
pasted text to arrive as *text*; without the markers a multi-line paste is executed line by line as
it arrives, before the user can read what they pasted. The app's paste-confirmation dialog softens
the surprise but does not change what the shell does with the bytes.

**Fix.** `bracketedPastePayload` is ported from `ui/AppViewModel.kt:696`, including the part that is
not obvious: readline treats **everything** between the markers as literal, a trailing Enter
included, so a pasted command ending in a newline would be echoed at the prompt and never run.
Mainstream terminals keep interior newlines inside the brackets — literal, as the mode intends — and
send trailing CRs *after* the closing marker so they act as real Enter presses. `paste()` reads the
mode from the emulator at the moment of the paste rather than caching it, because a shell turns 2004
on and off around its own prompt.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/terminal_input_test.dart` | 24 passed (+6) |
| `test/shell_view_model_test.dart` | 43 passed (+2) |
| Full host suite | **2,446 passed** (+8) |
| `dart format --line-length 100` | `0 changed` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T120724Z_android_emulator-5554_core` |

**Negative controls**, each asserting the mutation matched exactly once:

- Reverting `paste()` to ignore the emulator fails `a paste is bracketed once the remote turns
  DECSET 2004 on` — the wiring, which was the actual defect.
- Leaving the trailing CR inside the brackets fails `a trailing Enter is sent after the closing
  marker` — the subtle half, which a straight reading of the spec would get wrong.

The wiring test drives the mode by feeding `ESC [ ? 2004 h` through the real emulator rather than
setting a flag, because "the remote enabled it" is the only way this is ever true in the app.

**The doc is a Kotlin document no longer.** Four of its claims are now verified against this
implementation and one was wrong; that one is corrected by the code rather than by editing the
sentence, which is the right direction of fix. The claims not checked here are the large ones —
UTF-8 clustering, reflow, tmux control framing, the hardware-keyboard matrix — and they remain
unverified against Flutter.

### 96 — a copied private key was displayed by the system and left on the clipboard (closed, **security**)

The last caller on the platform-argument seam, and the one where the missing argument is a whole
behaviour. Kotlin has a dedicated helper for copying a secret — `copySensitiveClipboard`
(`ui/ToolsScreen.kt:115`) — with exactly one call site: **Copy private key**, on the sheet that shows
a freshly generated key once (`:2563`). It does two things a plain copy does not:

| Kotlin | Why | Flutter before |
|---|---|---|
| `ClipDescription.EXTRA_IS_SENSITIVE` on API 33+ | From Android 13 the system shows a **preview** of what was copied. Without the marker, the private key is displayed on screen next to the button pressed to keep it private. | nothing |
| Clears the clipboard after 60s, **if it still holds the same text** | A clipboard is readable by whatever the user pastes into next, for as long as it sits there. | nothing |

Flutter used `Clipboard.setData` for all three blocks on that sheet. That API cannot express the
marker at all — it writes a plain clip — so this needed a platform channel rather than an argument.

**Fix.** `SensitiveClipboardBridge` sets the marker and answers two narrow questions (does the
clipboard still hold this text; clear it). The 60-second policy lives in Dart, in
`SensitiveClipboard`, because that is the part with decisions in it and therefore the part worth
testing. Only the private-key block opts in, matching Kotlin's single call site: the public key and
the install command are meant to be pasted around.

Three details that are decisions rather than mechanics:

- **The clear is conditional.** Wiping unconditionally would destroy whatever the user copied in the
  meantime — a worse defect than the one being fixed.
- **`dispose` cancels the timer but never the clipboard.** Someone who copies a key and closes the
  sheet still needs to paste it.
- **No channel means a plain copy, not a refusal.** On iOS and in tests the marker is unavailable;
  skipping the copy would leave a button that silently does nothing.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/sensitive_clipboard_test.dart` | 6 passed, all new |
| Full host suite | **2,438 passed** (+6) |
| `dart format --line-length 100` | `0 changed` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T115423Z_android_emulator-5554_core` |

**Negative controls.** Clearing unconditionally fails `something the user copied afterwards is left
alone` (`Expected: 'something the user copied later', Actual: <null>`) and the call-order assertion.
Dropping the timer cancellation fails `tapping copy again restarts the minute`
(`Expected: 'PRIVATE-KEY-BODY', Actual: <null>`).

**A control that proved nothing, and what replaced it.** The timer-cancellation test was first
written with *different* text for the second copy — and it passed with the cancellation removed,
because the conditional clear already protects a different value. It could not fail for the line it
claimed to guard. Rewritten to copy the **same** secret twice, which is what a user tapping the
button again does, it fails correctly. Sixth vacuous control caught in this ledger; the tell each
time is a test that passes on the mutation, and the fix each time is a scenario where the two
implementations genuinely differ.

**What is not covered.** The marker itself is a platform behaviour: the tests prove the bridge is
called with the right text and label, not that Android hides the preview. That needs eyes on a
device running API 33+ — the emulator is API 35, so the check is available, and it is a *look*, not
an assertion a suite can make.

### 95 — the compression switch stops claiming a behaviour the app cannot perform (closed)

The half of defect 94 left open. dartssh2 proposes `compression: ['none']` in its KEX and ships no
zlib — the CHANGELOG has never mentioned compression in any version — so "SSH compression" was a
control that could be set, saved, restored and read back, and never once compressed anything. Kotlin
negotiates `zlib@openssh.com,zlib,none` (`JschSession.kt:85`).

Defect 77 settled the principle on a button ("biometric unlock was offered where it cannot work");
this is the same rule applied to a setting. The row is now **shown and disabled**, with the reason
under it, and three options were weighed rather than one:

| Option | Why not |
|---|---|
| Leave it live | It reports a state the connection does not have. That is the defect. |
| Remove the row | Hides a setting the user may have switched on in the Kotlin app and can still see in their backup file, with no explanation of where it went. |
| **Show it disabled, say why** | Keeps the setting visible and its stored value untouched, so backup and restore round-trip and it starts working the day the library does. |

The stored value being left alone is the part worth stating: disabling a control must not rewrite
the row underneath it, and the second test exists because that is an easy thing to get wrong.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/server_form_sheet_test.dart` | 22 passed (+2) |
| Full host suite | **2,432 passed** (+2) |
| `dart format --line-length 100` | `0 changed` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T112341Z_android_emulator-5554_core` |

**Negative control.** Restoring the live `onChanged` fails `cannot be switched on, and says why` with
`Expected: null, Actual: <Closure: (bool) => void>` — "a switch that cannot take effect must not
invite a tap". The mutation asserted it matched exactly once.

**Still true, and still open.** The app cannot compress. This closes the lie, not the gap: a user who
wants compression on a slow link is no better off than before, and the only fix for that is a
library that implements it. Recorded in the handover as a capability difference from Kotlin rather
than as a defect, because there is nothing left in this repository to change about it.

### 94 — two host-form switches that changed nothing (agent forwarding closed, compression evidenced)

Continuing the platform-argument seam from 92 and 93 into the SSH client. The client's own arguments
were fine — both `SSHClient`s set `onVerifyHostKey`, so host keys are checked on the target and on
the bastion. The defect was one level out: of the eleven fields `SshCredentials` carries, the
transport reads nine. **`compression` and `agentForwarding` are never read at all.**

Both are real switches in the host form, saved to the database, carried through
`server_credentials.dart:101-102` into `SshCredentials`, and then dropped. `compression` reaches
`ssh_session_pool.dart:56` — but only as part of the pool's cache key, so toggling it opens a fresh
connection that ignores it just as thoroughly as the old one did.

**Both are implemented in Kotlin**, which is what makes them defects rather than shared gaps:

| | Kotlin | Flutter (before) |
|---|---|---|
| Agent forwarding | `if (creds.agentForwarding) runCatching { setAgentForwarding(true) }` on the shell channel (`JschSshTransport.kt:351`) | nothing |
| Compression | `compression.s2c` / `compression.c2s` set to `zlib@openssh.com,zlib,none` (`JschSession.kt:85-90`) | nothing |

This also **withdraws a ruling**. Agent forwarding sits in this ledger's "Ruled out (verified
present, wording differs only)" list. That ruling came from a string sweep, and the strings *were*
present — the switch, its label, its help text, its database column and its backup round trip all
exist. Only the four lines that would have made it do something were missing. A string sweep cannot
tell those apart, and this is the fourth time that has been true here.

**Agent forwarding: fixed.** dartssh2 supports it and even ships the agent — `SSHKeyPairAgent`
answers identity and signing requests. There is no ssh-agent on a phone, so the app *is* the agent,
signing with the same key the connection authenticated with; that is what lets an onward hop work
without the private key being copied to the server. `agentHandlerFor` returns one only when the
setting is on **and** there is a key to sign with: a password host has nothing to serve, and an empty
agent would ask the server for a forwarding channel that could never answer.

Two placement details, both taken from Kotlin rather than from convenience:

- **Shell only.** Kotlin sets it on the channel from `openChannel("shell")`. dartssh2 attaches the
  agent to the *client*, and then requests forwarding on **every** channel that client opens — so
  passing it to the pooled `exec` connections would have put the monitoring commands behind a
  request the user made for their terminal. `_connect` takes `forwardAgent` per call; only
  `openShell` passes it.
- **A refusal must not cost the shell.** Kotlin wraps the request in `runCatching`, so
  `AllowAgentForwarding no` is survivable. dartssh2 instead throws `SSHChannelRequestError` and
  closes the channel, and because the agent belongs to the client, retrying the channel would fail
  identically — so the fallback reconnects without it. That mirrors the `COLORTERM` fallback three
  lines above it, which exists for the same reason: an optional request that is refused must never
  be the reason a terminal will not open.

**Compression: evidenced, not fixed, and not fixable here.** dartssh2 hard-codes its KEX proposal to
`compressionClientToServer: ['none']` and `compressionServerToClient: ['none']`
(`ssh_transport.dart:1035`) and ships no zlib implementation, so the switch cannot be honoured
without patching the library. What must not stand is the current state: a switch that claims a
behaviour the app cannot perform. Defect 77 settled the principle — do not offer what cannot work —
and the options are to disable it with an explanation or to remove it, which is a parity decision
about a feature Kotlin *has*. **Left open deliberately, with the evidence, rather than guessed at.**

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/ssh_agent_forwarding_test.dart` | 3 passed, all new |
| Full host suite | **2,430 passed** (+3) |
| `dart format --line-length 100` | `0 changed` |
| Device host suite, live SSH fixtures, `ZF62224F8K` | **passed, no warnings** — `20260811T111105Z_android_ZF62224F8K_host` |

**Negative control.** Dropping the `!creds.agentForwarding` clause — the exact state the code was in
— fails `a host with it off is served none` with `Expected: null, Actual: <Instance of
'SSHKeyPairAgent'>`, asserting the mutation matched exactly once.

The test generates its key through `test/support/ed25519_fixture.dart` rather than embedding one.
The first draft of it carried a `BEGIN OPENSSH PRIVATE KEY` block, which is precisely what that
helper exists to prevent: the secret gate scans **all history**, so a committed key keeps reporting
forever even after deletion.

**What this does not prove.** The unit tests cover which agent is built, not the forwarding
handshake — that needs a server with `AllowAgentForwarding` set both ways, which the lab does not
yet have. The device run above proves the shell path still opens against real hosts, i.e. that the
new argument broke nothing; it does not prove an onward hop can authenticate. A fixture host with
forwarding refused is the missing coverage, and the refusal fallback above is the code it would
exercise.

**An unexplained flake, recorded rather than dismissed.** The first device run of this change failed
— `20260811T110727Z_android_ZF62224F8K_host`. Podman's raw probe answered `podman` over the app's
own transport, and then `infra.load` returned an empty runtime set two lines later; Docker had
passed the identical sequence seconds before. `./scripts/test-hosts.sh verify` was fully green
afterwards, including the Podman host and its Compose smoke, and the second run of the same build
passed all six protocols. So it is not the fixture and it does not reproduce, and **it is not
attributed to this change** — the exec path this failure sits on never receives the new argument
(`forwardAgent` defaults to false, and `agentHandlerFor` is not called for pooled connections).

That is the whole of what is known. Intermittent runtime discovery on the Podman host is now an open
question with an artifact attached, not a passing thought: the next host run that fails the same way
should compare `infra.error` and the raw probe in the same breath, because a null error with an
empty set is the part that does not add up.

### 93 — one failed read could blank every stored credential (closed, **data safety**)

Found by generalising defect 92 rather than by a new sweep: that one was a defect in the *arguments*
to a platform call, so the question became which other platform calls carry arguments nobody chose.
`SecretStore` is the highest-stakes of them, and its Android options were inherited defaults.

**What the default does.** `flutter_secure_storage` 11's `AndroidOptions` defaults
`resetOnError: true`, and its own doc says it "will PERMANENTLY erase the data when an error
occurs". The Android source is literal about it — `handleStorageError` calls `delete(key)` after a
failed read, `deleteAll()` after a failed `readAll`, and `deleteAllDataAndKeys` after a failed
migration.

**Why that is catastrophic here specifically.** This store keeps exactly one thing in the platform
keystore: `omniterm_secret_key_v2`, the AES key under which every `enc:v2:` value in the database is
encrypted — server, sudo and proxy passwords, imported private keys, credential-profile passwords,
share passwords. Deleting the key that failed to read once makes all of them permanently
undecryptable while the ciphertext sits in the database looking intact.

**And the app would not notice.** `_key()` treats a missing key as first run and mints a new one, so
after the wipe the app carries on encrypting under a fresh key and reports nothing. That is exactly
the failure this class's own header warns about for the v1→v2 migration — "an updating user would
open the app to find every saved password and private key silently blank" — reintroduced by a
different route, in a class whose header already knew the shape of it.

**Kotlin does none of this.** `data/SecretStore.kt:35` logs the failure *class* — never the secret —
and returns null. A transient failure stays transient; nothing is deleted, and every other value is
untouched.

**Fix.** The options are now stated rather than inherited: `resetOnError: false`. The plugin then
surfaces the error instead of deleting, `decrypt` catches it and returns null exactly as Kotlin
does, and the only null `_key()` can see is a key that was genuinely never written.
`migrateOnAlgorithmChange` keeps its default of true — that one *preserves* data across a plugin
cipher change. The iOS accessibility choice, previously a comment, is now a named constant next to
it.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/secret_store_test.dart` | 19 passed (+3) |
| Full host suite | **2,427 passed** (+3) |
| `dart format --line-length 100` | `0 changed` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T104432Z_android_emulator-5554_core` |

**Negative control.** Restoring the inherited `AndroidOptions()` fails `a failed read must not
delete the key` with `Expected: 'false', Actual: 'true'`, asserting the mutation matched exactly
once.

**On testing arguments rather than behaviour.** These three tests assert a configuration, which is
usually a weak thing to test. Here it is the whole defect: the behaviour they protect can only be
produced by a platform failing a keystore read on a real device, which no unit test can stage, and
the cost of it happening once is unrecoverable. A tripwire on the argument is the only guard
available, and it fails the moment someone deletes the option — which is precisely how the defect
arrived.

**What this did not settle.** `encrypt()` calls `_key()` without a catch, so with the delete-on-error
behaviour gone a keystore read failure now propagates out of a save rather than silently writing
under a new key. That is the better of the two, and it is *deliberately* left as is: failing a save
loudly beats saving a password nothing can read back. Whether the UI reports it well has not been
checked, and is not claimed here.

### 92 — the app lock accepted the phone's own PIN (closed, **security**)

The handover listed `lib/platform/biometric_gate.dart` as "a second, unused biometric implementation
duplicating the live `BiometricAuth`… a hazard rather than a defect — the risk is someone wiring the
wrong one". Reading the two side by side, the wrong one was **already wired**. The unreferenced file
was the faithful port; the live one had quietly relaxed the thing the gate exists to enforce.

| | Kotlin `BiometricCryptoGate` | `BiometricGate` (unused) | `BiometricAuth` (live) |
|---|---|---|---|
| Authenticators | `BIOMETRIC_STRONG` only (`:91`) | `biometricOnly: true` | **`biometricOnly: false`** |
| Availability | `canAuthenticate(BIOMETRIC_STRONG) == SUCCESS` (`:44`) — enrolled | — | **`canCheckBiometrics`** — hardware only |

Kotlin has exactly one biometric implementation and five call sites, the app lock among them
(`AppUi.kt:709`), and it allows one authenticator: `setAllowedAuthenticators(BIOMETRIC_STRONG)`,
with no `DEVICE_CREDENTIAL`. It goes further — `setUserAuthenticationParameters(0,
AUTH_BIOMETRIC_STRONG)` binds a KeyStore key to that same class of authentication.

**Why `biometricOnly: false` is not a small difference.** The device credential is the PIN, pattern
or password of the phone's own lock screen. The app lock and the sudo re-prompt both exist to defend
against someone *holding the unlocked phone* — the port says so itself at
`app_lock_controller.dart:268`: "a saved sudo password turns 'holding the unlocked phone' into 'can
reboot the server', so the password is not used until the person is re-identified." Accepting the
device credential re-identifies them with the very secret that unlocked the phone in the first
place. It is not a weaker check; for that threat it is not a check at all.

The live file argued its own case in a comment — refusing the device credential "would lock out
anyone whose sensor is wet, gloved, or simply worn out". That argument does not survive contact with
the rest of the screen: **the app has its own PIN**, PBKDF2-hashed and separate from the device's
(`domain/app_pin.dart`), and the lock screen offers it underneath the biometric button. The
lockout it feared cannot happen.

**Availability was wrong in the same direction.** `canCheckBiometrics` resolves to
`deviceSupportsBiometrics()` — whether the *hardware* exists — so a phone with a fingerprint reader
and no finger registered answered yes. `getAvailableBiometrics()` resolves to
`getEnrolledBiometrics()`, which is what Kotlin's `canAuthenticate(BIOMETRIC_STRONG) ==
BIOMETRIC_SUCCESS` means. This is defect 77 one level deeper: 77 found that the availability check
was never *called*; the check itself was also answering the wrong question, which no amount of
wiring would have fixed.

**Fix.** `prompt` asks for a biometric only, and `isAvailable` asks whether one is enrolled. The
duplicate `biometric_gate.dart` is deleted: with the live class now doing what it did, keeping a
second copy of a security decision is how the two drift apart again.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/biometric_auth_test.dart` | 7 passed, all new |
| Full host suite | **2,424 passed** (+7) |
| `dart format --line-length 100` | `0 changed` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T102728Z_android_emulator-5554_core` |

**Negative controls**, each asserting the mutation matched exactly once:

- `biometricOnly: false` fails `asks for a biometric, not the device credential`
  (`Expected: true, Actual: <false>`).
- Availability back to `canCheckBiometrics` fails `hardware with nothing enrolled is not available`
  (`Expected: false, Actual: <true>`).

The tests fake `LocalAuthentication` and record what the wrapper asks the platform for, because the
defect is entirely in the *arguments* — a wrapper that returns the right booleans while asking the
wrong question passes any test that only checks its return value.

**A note on the dead file.** It had been sitting there since the port, containing the correct
`biometricOnly: true`. Two sweeps found it, both classified it as duplication, and neither compared
the two implementations — the assumption each time was that the live one was right and the spare was
redundant. The lesson is narrow and worth keeping: when a sweep finds two implementations of one
thing, the question is not which is unused, it is **which is correct**.

### The copy dialog's focus restore: no defect, and the axis is now closed (closed)

The last of Kotlin's four focus sites, and the one entry 90 explicitly refused to call a gap without
reading Flutter's copy path first. Reading it was the right call: there is no defect, and the shapes
are different enough that a literal port would have been wrong.

**Kotlin**, `ShellScreen.kt:2555`: the copy dialog's `dismiss()` clears its state and then
`if (!viewModel.terminalReadOnly) { focusRequester.requestFocus(); keyboard?.show() }`. The restore
is *conditional*, and that condition is the same one as everywhere else on this axis.

**Flutter** has no copy dialog. The counterpart is `openTerminalTranscript`, a modal bottom sheet
opened by a long press on the grid (`terminal_surface.dart:246`), which is where defect 67 put the
two copy ranges. Popping a route restores focus to whatever held it before, so the writable case
already behaves as Kotlin's `dismiss()` arranges by hand — and the read-only case behaves correctly
for a different reason than Kotlin's: there is nothing to restore, because read-only released the
hidden input before the sheet ever opened (entries 90 and 91).

So the same two outcomes arrive by two different routes. Kotlin restores conditionally; Flutter
restores unconditionally but has nothing to restore in the case Kotlin's condition excludes. Porting
`dismiss()` literally — an unconditional `requestFocus` after the sheet — would have broken the
read-only case that currently works by construction.

**One test, both cases.** `closing the copy sheet hands the keyboard back to the terminal` drives
the real long press, asserts the sheet opened, pops it, and checks the keyboard returned; then
switches the session to read-only and repeats the whole round trip, requiring the keyboard to stay
down.

**Negative control.** Making the long press dismiss the keyboard before opening the sheet — a
one-line change modelling the ordinary regression here, a sheet that takes the keyboard and never
gives it back — fails the writable assertion with `Expected: true, Actual: <false>`. The read-only
half's control is entry 90's: without the read-only release, the keyboard is already up before the
long press.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/shell_screen_test.dart` | 48 passed (+1) |
| Full host suite | **2,417 passed** (+1) |
| `dart format --line-length 100` | `0 changed` |
| Device sweep | not run — **no product code changed in this slice** |

**The terminal focus axis is closed.** All four Kotlin sites are accounted for, and it is worth
recording how they divided: two were real gaps and were ported (`:1889` in 90 and 91, `:2077` in
90); two were behaviours Flutter already had for its own reasons, where the work was proving it and
leaving a guard (`:1905` in the entry below, `:2555` here). Half of a "port these four sites" list
turned out to be "read these four sites". Counting sites on one side says nothing about how many
defects are behind them — the same lesson the confirmed-defect table records for string diffs, in a
different disguise.

### The last focus-lifecycle item: no defect, two guards instead (closed)

Entries 90 and 91 left one Kotlin site unported — the `ON_STOP` / `ON_RESUME` handler at
`ShellScreen.kt:1905` that frees the hidden input on background and re-acquires it on return. This
slice answered it. **There is no defect, and porting it would have created one.** No product code
changed; the slice's output is the answer and two tests that keep it answered.

**Why Kotlin does it.** Its own comment: backgrounding tears down the IME text-input session, and if
the field is still focused when the app resumes, "Compose's legacy cursor-anchor path
(LegacyCursorAnchorInfoController via onGloballyPositioned) dereferences the now-null session and
crashes at draw time." That is a Compose defect being worked around. It is not a behaviour anyone
chose, and it is not a contract the port owes.

**What Flutter does.** Reattaches its own IME on resume and keeps the keyboard. The user-visible
outcome is what Kotlin's workaround laboriously restores — so the two agree on behaviour and differ
only in how much code it takes. Ported literally, the `ON_STOP` half would be a **regression**: the
keyboard would drop every time the user glanced at a notification and never come back, because
Flutter has no reason to re-acquire.

`a trip to another app leaves the keyboard where it was` therefore asserts the outcome rather than
the mechanism. It drives the real lifecycle sequence — `inactive → hidden → paused` and
`hidden → inactive → resumed`; the framework asserts on the shortcuts, which is worth knowing before
writing any lifecycle test here.

**Negative control, and a caught vacuous test.** The first attempt at the control added Kotlin's
`ON_STOP` unfocus to `_ActiveTerminalState` — and the test **passed**, which would have been
recorded as proof the guard worked. It proved nothing: the mutation never called
`WidgetsBinding.instance.addObserver(this)`, so its `didChangeAppLifecycleState` was never
dispatched. With the observer registered the control fails correctly (`Expected: true, Actual:
<false>`). This is the fifth vacuous control in this ledger and the second whose cause was the
mutation not being *reachable* rather than not being *applied* — checking that the edit landed is
not the same as checking it runs.

### The lock and the terminal's keyboard (verified, no defect)

Following the call chain from the lifecycle question reached `AppLockGate`, which hides the app
behind `ExcludeSemantics(ExcludeFocus(...))` while locked. That takes the terminal's hidden input
out of the focus tree — correctly, since a keyboard over the unlock screen would be absurd — and the
question was whether anything gives it back, since entry 91's effect keys on three values that
locking does not change.

It does: removing the exclusion restores the previously focused node, so unlocking returns to a
session that accepts typing. `unlocking the app gives the terminal its keyboard back` pins both
halves — no keyboard while locked, keyboard back afterwards — using the real gate rather than a
stand-in.

**Negative control.** Removing `ExcludeFocus` from the gate fails the *first* assertion
(`Expected: false, Actual: <true>` — "no keyboard over the unlock screen"), which is the half worth
protecting: it is the difference between a locked app and a locked-looking one.

**Two traps for anyone writing lock tests here**, both of which cost time:

- `pumpAndSettle` never returns while the app is locked. The unlock screen focuses its PIN field and
  a focused field blinks its cursor forever. Pump explicit frames.
- `setPin` and `unlockWithPin` hang inside `testWidgets`. PBKDF2 at 210,000 iterations yields to the
  event loop between chunks, and a widget test's fake-async zone never advances it. Wrap both in
  `tester.runAsync`.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/shell_screen_test.dart` | 47 passed (+2) |
| Full host suite | **2,416 passed** (+2) |
| `dart format --line-length 100` | `0 changed` |
| Device sweep | not run — **no product code changed in this slice** |

**Three of four sites settled here.** `:1889` ported (90, 91), `:2077` ported (90), `:1905`
deliberately not ported and guarded against being ported (this entry). The fourth, the copy-dialog
restore at `:2555`, was read in the slice after this one and needed no change either — see the
copy-dialog entry above, which closes the axis.

### 91 — a fresh session made you tap the grid before you could type (closed)

The first of the two items entry 90 left open, taken as its own slice because auto-raising a
keyboard changes what every session looks like on open.

**Kotlin:** `LaunchedEffect(sessionId, isFocused, viewModel.terminalReadOnly)` at
`ShellScreen.kt:1889` — "Focus the hidden input immediately so the keyboard is available — but only
for the focused pane. In split view the unfocused pane must not grab the keyboard."

**Flutter before:** focus was only ever taken in the tap handler, so a newly connected session had
no keyboard until the user tapped the grid. On the one screen whose entire purpose is typing, that
is a step Kotlin never asks for.

**Fix.** The port now mirrors the effect, including its keys. That last part is the whole design:
`LaunchedEffect` keys mean *run when one of these changes*, not *run on every recomposition*. A
Flutter `build` has no such semantics, so the three values — session id, whether this pane is the
focused one, and read-only — are compared against the last triple acted on. Without that, dismissing
the keyboard with Back would be undone by the next rebuild, and on a terminal rebuilds arrive with
the output.

The same effect subsumes the read-only release added in entry 90, so there is now one place that
decides whether the hidden input holds focus, rather than two that must agree.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/shell_screen_test.dart` | 45 passed (+2) |
| Full host suite | **2,414 passed** (+2) |
| `dart format --line-length 100` | `0 changed` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T092349Z_android_emulator-5554_core` |

**Negative controls**, each asserting the mutation matched exactly once:

- Disabling the focus branch fails `a connected session takes the keyboard without waiting for a
  tap` — `Expected: true, Actual: <false>`.
- Replacing the triple comparison with `if (true)` — an effect that fires on every build — fails
  `a dismissed keyboard is not re-raised by an unrelated rebuild` with
  `Expected: false, Actual: <true>`. That test dismisses the keyboard, emits terminal output, and
  requires it to stay dismissed.

The second control is the one worth keeping. The obvious implementation of "focus on open" passes
the first test and fails the user: it re-raises a keyboard they deliberately closed, every time a
line of output arrives.

**Still open on this axis.** Nothing. Background and resume (`ShellScreen.kt:1905`) was settled in
the slice above this entry: no defect, and a guard against porting Kotlin's Compose workaround.

### 90 — a read-only terminal summoned a keyboard that could not type (closed)

Found by continuing the accessibility axis (71, 73, 79) with the marker method: count a construct on
both sides, then read the call chain. Three of the four remaining sub-items dissolved on contact and
the fourth was this.

**Kotlin** ties the hidden input's focus — and therefore the software keyboard — to read-only in
four places, all in `ShellScreen.kt`:

| Site | Behaviour |
|---|---|
| `:1889` `LaunchedEffect(sessionId, isFocused, terminalReadOnly)` | focus + show keyboard when the pane is focused and writable; **free focus + hide keyboard when read-only** |
| `:2077` terminal tap | focus + show only when focused and writable; otherwise "Read-only taps may focus a split pane for scrolling but never summon its keyboard" |
| `:1905` `ON_STOP` / `ON_RESUME` | free focus and hide on background, re-acquire on return when focused and writable |
| `:2555` copy-dialog dismiss | restore focus and keyboard **unless** read-only |

**Flutter before:** the tap handler called `_imeFocus.requestFocus()` unconditionally, and nothing
released focus when read-only was switched on. So a read-only session raised the soft keyboard on
any tap and kept it up after the toggle — covering the output the user turned read-only in order to
read, in exchange for keystrokes that are dropped at `shell_view_model.dart:899`. Read-only already
hid the useless keys from the key bar (an earlier defect); the keyboard was the same mistake one
layer down.

**Fix.** The tap guard now mirrors `:2077`, and the read-only state releases the IME from inside the
`ListenableBuilder` that the toggle rebuilds — reacting to the state rather than to the toolbar
callback, so it holds however read-only was reached: the toggle, a resumed read-only session, or a
pane swap onto one.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/shell_screen_test.dart` | 43 passed (+2) |
| Full host suite | **2,412 passed** (+2) |
| `dart format --line-length 100` | `0 changed` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T090643Z_android_emulator-5554_core` |

The hidden 1x1 field owns the platform IME, so "does that node have focus" is the same question as
"is the keyboard up", and that is what both tests assert.

**Negative controls**, one per half, each asserting the mutation matched exactly once:

- Dropping the `if (!session.readOnly)` guard fails `tapping a read-only terminal focuses it without
  summoning the keyboard` — `Expected: false, Actual: <true>`.
- Deleting the unfocus block fails `turning read-only on takes the keyboard away` with the same
  signature.

The first test also asserts a **writable** terminal still takes the keyboard on tap, before it
checks the read-only case. Without that line the fix could have "passed" by disabling terminal input
altogether.

### Still open on this axis, with the Kotlin references

Two of Kotlin's four focus sites have no Flutter counterpart and were **not** addressed here:

- **Focus on open.** `ShellScreen.kt:1889` focuses the hidden input as soon as a pane becomes the
  focused one, so the keyboard is available without a tap. Flutter required a tap first.
  **Closed by entry 91**, in its own slice as intended here.
- **Background and resume.** `ShellScreen.kt:1905` frees focus on `ON_STOP` and re-acquires on
  `ON_RESUME`. Kotlin's comment says this exists to dodge a Compose IME crash, which is a
  framework-specific reason that may not transfer — but the *user-visible* half (the keyboard state
  surviving a trip to another app) still needs checking on a device before anyone concludes Flutter
  is fine.

The copy-dialog restore at `:2555` reaches the same two outcomes by a different route; read and
settled, with a test, in the copy-dialog entry above.

### Three accessibility sub-items that dissolved when counted

Recorded so nobody re-derives them. The handover listed four open accessibility items; three are not
defects:

- **`liveRegion` for state changes** — **zero** uses in Kotlin and zero in Flutter. There is nothing
  to port. (See the scope note below: the user has since said additions are welcome when they make
  sense, provided they land in *both* apps. That makes this a possible enhancement, jointly, rather
  than a parity defect.)
- **Focus order** — Kotlin has no `traversalIndex`, `isTraversalGroup` or `focusProperties` anywhere.
  There is no traversal order to match.
- **`Semantics` grouping on composite rows** — Kotlin's single `semantics(mergeDescendants = ...)`
  and both `stateDescription` uses are the same site, the terminal pane, closed as defect 79.

## The 2026-08-11 live-fixture device pass (81–89)

Nine defects found by driving the app on a physical phone against the real SFTP/SMB/FTP/WebDAV
fixtures. They were written up in `HANDOVER.md` first and carried there alone for a session, which
is the wrong way round — this file is the authority. Each was re-read against the current code
before being entered here.

Two are parity gaps against Kotlin (81, 83). The other seven are defects in the Flutter port's own
share stack that no Kotlin comparison could have found, because Kotlin does not have the code: its
share clients are synchronous JVM streams, while Flutter's cross a method channel and an event
channel. **That is the lesson of this pass.** Every earlier slice looked for behaviour Kotlin has
and Flutter lacks. These were found the only way they could be — by pointing the app at a real
server and using it.

### 81 — a share's configured start path was thrown away (closed)

**Kotlin:** `ShareClients.startPath` (`data/shares/RemoteFsClient.kt:74`), called at
`AppViewModel.kt:7662` as `sharePath.ifBlank { ShareClients.startPath(share, client) }`. SMB
consumes the first path segment as the share name; FTP, SFTP and WebDAV treat the configured path as
the initial directory. `startPath` is what keeps those two readings apart.

**Flutter before:** `SftpViewModel.openShare` called `openPath('')` unconditionally, so every
non-SMB share opened at the protocol root and nested SMB paths were lost — while the Shares card
went on displaying the saved path the browser was ignoring. Now `sftp_view_model.dart:203` resolves
through the same helper.

**Evidence.** `test/sftp_view_model_test.dart` — `a share opens its configured start path instead of
the protocol root`. **Negative control:** the WebDAV `/fixture/nested/` case fails on the old
`openPath('')`.

### 82 — the native SMB client crashed on first use (closed)

smbj needs Bouncy Castle at runtime. The Flutter Android build excluded it as a transitive, so the
first SMB editor path taken on a device died immediately. Kotlin pins it explicitly —
`gradle/libs.versions.toml:52` at `1.85`, used at `app/build.gradle.kts:202`, with the comment that
smbj's "bcprov needs are satisfied by the pinned bcprov-jdk18on above". Flutter now pins the same
version at `flutter_app/android/app/build.gradle.kts:128`.

A dependency exclusion is invisible to every gate in this project except running the code on a
device. `flutter analyze`, the host suite and the emulator sweeps were all green while this shipped.

### 83 — text files on an SMB share could not be edited on Android (closed)

**Kotlin:** `AppViewModel.openShareFileForEdit` (`AppViewModel.kt:8070`) edits a file on **any**
share protocol, through `downloadTo`/`uploadStream`, gated only by `shareEditMaxBytes`. There is no
per-protocol capability check, because there is nothing to check: every `RemoteFsClient` streams.

**Flutter before:** the Android SMB client reported `supportsTextEditing == false` and implemented
neither `readText` nor `writeText`, so the editor was simply unavailable for SMB — a capability
present in Kotlin for every protocol and in Flutter for all but one. Both now stream UTF-8 through
the native bridge (`platform_smb_client.dart:265`).

**Evidence.** `test/platform_smb_client_test.dart` — `text editing is available and writes UTF-8
through the streaming bridge`; and the device host suite's SMB read/save/reread.

### 84 — a completed transfer could be missed entirely (closed)

FTP, WebDAV and native SMB all registered their stream-completion future **after** closing the
producer. A completion that arrived in between was never observed, and the transfer hung. All three
now register before the transfer starts — `ftp_remote_fs_client.dart:175`,
`webdav_remote_fs_client.dart:183`, `platform_smb_client.dart:279`.

No Kotlin counterpart: Kotlin copies bytes on a blocking stream and needs no completion event.

### 85 — every list, read and write leaked a share client (closed)

`SftpViewModel` resolved a fresh `RemoteFsClient` per operation. Each may own a native session and
event channel, so a rapid editor read-save-reread raced the previous stream's cancellation and left
authenticated sessions open. One client is now kept for the browse/editor session and closed once
(`sftp_view_model.dart:164`). Host SFTP stays resolver-owned deliberately: that transport has its
own connection pool and must pick up credential edits from `AppState`.

**Evidence.** `test/sftp_view_model_test.dart` — `a share reuses one client through editor save and
closes it`.

### 86 — a finished SMB read could end the *next* read (closed)

The native bridge sent both a transfer-scoped `done` message and `endOfStream` on an EventChannel
name shared by sequential downloads. The delayed global end could land after the next read had
subscribed and terminate it before its first chunk. The redundant end was removed; `done` is the
terminator and Dart cancels on it.

**Negative artifact:** `20260811T074224Z_android_ZF62224F8K_host`. SMB read/save/reread and
mutations pass after the change.

### 87 — FTP could not list a current vsftpd at all (closed)

`ftpconnect` defaults to MLSD without capability discovery, and vsftpd 3.0.5 answers
`500 Unknown command`, which made an otherwise healthy share impossible to open. FTP now probes
RFC 2389 `FEAT`, prefers MLSD only when MLST/MLSD is advertised, and otherwise uses the
interoperable LIST. A rejected or unsupported FEAT leaves LIST selected rather than failing the
login — FEAT is optional and an older server must not be refused for lacking it.

**Evidence.** `test/ftp_remote_fs_client_test.dart` — `FTP uses structured MLSD only when the server
advertises it` and `FTP falls back to portable LIST when MLSD is unavailable`. **Negative
artifact:** `20260811T074451Z_android_ZF62224F8K_host`.

### 88 — WebDAV rejected the redirect it had provoked (closed)

PROPFIND addressed the collection as `/fixture`; Apache answered `301` to `/fixture/`, and the
client treated the redirect as a failure. Collection paths are now canonically encoded with a
trailing slash (`webdav_remote_fs_client.dart:59`).

**Evidence.** `test/webdav_remote_fs_client_test.dart` — `WebDAV collection paths are encoded and
end in a slash` and `WebDAV file paths do not gain a collection slash`. **Negative artifact:**
`20260811T074848Z_android_ZF62224F8K_host`.

**Now unverified where it was verified.** The fixture that produced that 301 has since been replaced
by rclone, which answers `207` directly (see the lab entry below). The unit guard is the only thing
holding this fix; the live path no longer exercises the redirect.

### 89 — Go-to-line disposed a controller the dialog was still painting (closed)

`_goToLine` disposed its `TextEditingController` as soon as `showDialog` returned, while the
dialog's exit transition was still rendering the `TextField` bound to it. The dialog now records
what was typed through `onChanged` and owns no controller at all, which removes the lifetime
question rather than moving it.

**Evidence.** `test/code_editor_test.dart` — `go-to-line moves the selection to the requested line
start`, with a failing widget control captured before the fix.

### 80 — the file browser's controls pushed the listing off the screen at 200% text (closed)

Found by the surface sweep on the physical API-32 phone, not by reading code:
`dark-200pc-text/landscape/sftp/files: A RenderFlex overflowed by 25 pixels on the bottom
[sftp_tabs.dart:389]`, artifact `20260811T081441Z_android_ZF62224F8K_surface`. It is the one
signature the sweep found across every route, subtab, theme and orientation at the app's maximum
text size.

The browser body already had a responsive answer to this: above 600dp wide and below 120dp tall it
puts the breadcrumbs and the toolbar side by side instead of stacking them. That answer was
incomplete rather than wrong. **A `Column` child with no ceiling does not yield — it overflows**, so
once even the compact row needed more height than the body had, the layout had nowhere to go. The
`Expanded` listing below it was already at zero.

Everything above the listing is now one block with a ceiling: at most 55% of the body height (less
the 6px gap, which sits outside the block and would otherwise be unaccounted for), scrolling inside
that ceiling. At ordinary sizes the block is far shorter than the cap and nothing changes. At 200%
in landscape the controls stay reachable by scrolling and the listing keeps 45% of the body.

`720x360dp` is the phone's own landscape geometry, so the failing heights were found by bisecting
the body height on the host rather than by guessing: clean at 224, and overflowing by 4, 12, 20, 28
and 36 pixels at 216, 208, 200, 192 and 184. The device's 25 pixels sits inside that range. All five
are clean after the fix.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `test/sftp_screen_test.dart` | 60 passed (+1) |
| Full host suite | 2,410 passed |
| Device surface sweep, 200% text, `ZF62224F8K` | **passed, no warnings** — `20260811T082511Z_android_ZF62224F8K_surface` |
| API 35 core profile, `emulator-5554` | **13 passed, no warnings** — `20260811T083355Z_android_emulator-5554_core` |

**Negative control.** Replacing the ceiling with `maxHeight: double.infinity` fails the new test at
`body height 208.0 overflowed` with `A RenderFlex overflowed by 12 pixels on the bottom` — the same
signature the phone produced. The mutation asserts it matched exactly once before applying, per
entry 75.

The test also asserts the listing is still present at every height. An overflow check alone would be
satisfied by a header that swallowed the whole body, which is the failure mode this fix could
plausibly introduce.

### The lab itself was the last thing blocking the host suite (closed)

The 2026-08-11 device pass left one failure standing: WebDAV listed and read on the phone but every
save returned 500. `HANDOVER.md` recorded it as an Alpine Apache fixture fault and said to fix the
fixture rather than the assertion. It is worse than a missing package.

**What it actually was.** `mod_dav_fs` opens its lock database through `apr_dbm`, and apr-util
1.6.4 ships **no `apr_dbm_*.so` driver at all**. Reproduced identically on four independent images —
Alpine 3.22 (`apr-util-1.6.4-r0`), Alpine 3.21 (same version, backported), `httpd:2.4-alpine` and
Debian-based `httpd:2.4`. Alpine has no `apr-util-dbm_*` subpackage to install; the Debian image
carries `apr_dbm_db-1.so` and `apr_dbm_gdbm-1.so` but not the `sdbm` driver httpd asks for. This
build of `mod_dav_fs` also has no `DavLockDBType` directive to point at another driver:

```text
[dav_fs:crit] (20019)DSO load failed: AH00576: The DBM driver could not be loaded
```

Dropping `DavLockDB` does not help, and that is the part worth remembering: `mod_dav` consults the
lock database on **writes as well as locks**, because it queries lock-null status first. With the
directive removed the failure simply renames itself — `AH00623: Failed to query lock-null status`,
still 500. Reads and `PROPFIND` keep working throughout, which is exactly why `verify` was happy.

**Fix.** WebDAV is now served by `rclone serve webdav` from the same Alpine image, over the same
`/srv/share` volume and the same `/fixture` base URL. It runs as the share user through `su-exec`,
so a WebDAV write lands with the same ownership as an SMB or FTP write — a root-owned file would be
unwritable over the other two protocols and would have produced cross-protocol flakiness later.
Unprivileged means it cannot bind 80, so the share answers on 8080 and Compose maps the host's 8082
onto it; nothing outside the container changed. `apache2*`, `dav.conf` and the htpasswd file are
gone.

**The gap that let this reach a device run.** `test-hosts.sh verify` proved SMB, FTP and WebDAV
**reads** and nothing else, so a share that could not be written to passed every lab gate. Each of
the three now does a write round trip — PUT/STOR/put a uniquely named file, read the same bytes
back, delete it — leaving the seeded baseline untouched. This is the same shape of error the ledger
keeps recording in the product: the check existed, passed, and could not have failed for the thing
that was broken.

**Evidence.**

| Gate | Result |
|---|---|
| `curl -T` against the old Apache fixture | **PUT 500**, `PROPFIND 207` |
| `curl -T` against the rclone fixture | **PUT 201**, GET 200, MKCOL 201, MOVE 201, DELETE 204, unauthenticated PROPFIND 401 |
| `./scripts/test-hosts.sh verify` | 18/18 OK, including the three new write round trips |
| Device host suite, `ZF62224F8K` | `HOST-E2E share passed: WEBDAV` in `artifacts/device-tests/20260811T080903Z_android_ZF62224F8K_host` |

**Negative controls.** The old fixture is the control for the fix: the identical `curl -T` returned
500 before the change and 201 after. For the new probes, pointing the WebDAV write probe at a
missing collection makes the chain return non-zero and report FAILED, so the probe can fail.

**Rejected alternatives, and why.** Pinning the image to Alpine 3.21 does not work — it carries the
same apr-util 1.6.4. Keeping Apache and installing a DBM provider is not possible: no Alpine package
supplies one. `nginx` with `dav-ext` would cover the verbs this client uses but drops LOCK entirely;
rclone's `golang.org/x/net/webdav` server answers `supportedlock` and is the closer server.

**Written down as changed, not as equivalent.** Apache answered `/fixture` (no trailing slash) with
a 301 to `/fixture/`; rclone answers 207 directly. The client fix for that redirect — canonical
trailing-slash encoding of collection paths — is therefore no longer exercised by the fixture. It is
still covered by the unit guard in `test/webdav_remote_fs_client_test.dart`, and that guard is now
the only thing holding it.

### The host suite failed after every product assertion had passed (closed)

With the fixture fixed, `host_backed_e2e_test.dart` printed
`HOST-E2E complete: Docker, Podman, SFTP, SMB, FTP and WebDAV passed` and then failed anyway. Its
`addTearDown` closure called `context.read<HostStatusProbe>()` and `context.read<TelemetryPoller>()`
on a context whose widget is deactivated by teardown time; an inherited-widget lookup on a
deactivated element throws. Both objects are now captured as locals when the test first reads them,
and teardown stops those. Artifact: `20260811T080903Z_android_ZF62224F8K_host` is the failing
control; `20260811T081220Z_android_ZF62224F8K_host` is the pass.

This is a harness defect, not a parity defect, and it is recorded here because it had the same
effect as one: a red suite that named nothing real, over a product that worked.

### Defect 72 recurred in the working tree (closed)

`dart format` had been run at its default 80 columns again, leaving 14 files in the dirty worktree
formatted against a gate that uses 100 — `integration_test/host_backed_e2e_test.dart`, four
`lib/data/shares` and `lib/ui` files, and nine tests. `dart format --output=none
--set-exit-if-changed --line-length 100 .` reported `14 changed`; after reformatting at 100 it
reports `0 changed`. The branch still has no PR, so CI would not have caught it. Entry 72 predicted
exactly this and it happened again anyway, which argues the width belongs in a wrapper or a hook
rather than in a paragraph of documentation.

### Action-level device coverage (task 4, closed)

Open since the start of this work, and the thing the last two no-defect slices argued was the
highest-value remaining work: the two device suites open every destination and check it renders,
which catches a screen that crashes on a real engine **and nothing else**.

`integration_test/app_actions_test.dart` drives actions instead — the ones that write to the
database, open a dialog and come back. **Five flows**, all host-free on purpose (the ones needing a
reachable host belong in the lab suites): creating a quick script and finding it after leaving the
screen, enabling App Lock, changing a setting and reading it back, creating **and deleting** an
alert rule, and adding a host.

The alert-rule flow drives both halves deliberately. A create that is not verified and a delete that
is not verified hide opposite defects, and alert rules are the one thing in the app that acts on its
own — a rule that appears to save and does not is a monitor silently watching nothing. Deleting it
again also leaves the device as the suite found it, which is what makes the suite re-runnable
against a device that keeps its data.

**Negative control on the device suite itself.** Making `saveRule` silently drop new rules fails the
flow — so it is testing persistence rather than the dialog closing. Worth doing once for a device
suite: a flow that only taps through screens passes whatever the app does.

**It found something on its first run.** Defect 70's widget test asserted the App Lock
off-transition and passed — but its harness has no `AppLockController`, so enabling the lock never
prompted for a PIN, the save silently reverted, and the "on to off" transition it claimed to cover
**was never an on-to-off transition at all**. On a device the PIN dialog appears and the flow is
real. That is the whole argument for device coverage in one example: the widget test was not wrong
about the code, it was wrong about the state it had put the app in.

**Two lessons about writing these**, both of which cost a device round-trip:

* **A control below the fold is not built at all.** These screens are `ListView`s, so
  `ensureVisible` cannot reach a widget that does not yet exist — every "key not found" here was
  that, not a missing key. Both the tap and the read helpers scroll first.
* **Reading a widget after navigating away and back needs the same scroll**, for the same reason.

**The App Lock *off* transition was attempted on device and withdrawn**, with the evidence kept in
the test file rather than the attempt silently dropped. Instrumenting each step showed the flow
reaching the off-save with no dialog of any kind and the switch already back to false:

```
AFTER-ON       switch=true  pinDialog=0 lockScreen=0
AFTER-OFF-SAVE off=0 sudo=0 pin=0 lock=0 switch=false
```

The confirmation keys off `vm.saved.appLockEnabled`, and by the second save that was still false —
the first save set the PIN and left the *draft* on without the saved value following. **Whether that
is the test driving the screen faster than it commits, or the screen genuinely not persisting the
preference, is not established**, and asserting either would be a guess. Both paths stay covered at
the widget level.

**Resolved the following slice: not a defect.** Asserting `vm.saved.appLockEnabled` directly in a
widget test with a real `AppLockController` shows the preference *is* committed — the PIN is stored,
`isConfigured` is true, and the saved value follows. The device failure was the flow outrunning the
save, not the screen failing to persist it. Recorded because it was flagged here as possibly
security-relevant, and an unretracted suspicion is worse than none.

**That answer also removed a limitation this ledger had asserted twice.** Defect 62 recorded the
gated-save path as undrivable — *"providing a live `AppLockController` stops the harness settling at
all… the gated path cannot be driven through this screen without a harness rewrite larger than the
fix"*. It can: `pumpWithLock` provides a real controller and **bounded pumps** replace
`pumpAndSettle`, which is the only thing the repeating background-lock timer actually breaks. The
harness rewrite was two helpers.

Two tests now cover what was previously assumption:

| Test | What it pins |
|---|---|
| `the preference is saved, not just the PIN` | enabling collects a PIN **and** turns the lock on — a switch reporting protection it is not providing would fail here |
| `with a PIN stored, saving asks for it first` | defect 62's wiring: the join between `hasStoredPin` and the save, and that cancelling changes nothing |

**Negative control.** Disabling the gate (`if (false && lock != null && lock.hasStoredPin)`) fails
the second test; mutation asserted before running.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `dart format --set-exit-if-changed --line-length 100 .` | passes |
| Full host suite | **2,386 passed** |
| `app_actions_test.dart`, API 35 `emulator-5554` | **5 passed** |
| Surface sweep + walkthrough, API 35 | **8 passed** |

The emulator had to be rebuilt to run this: `Xvfb :99` was gone and `pkill -f "Xvfb :99"` **matched
its own command line** and killed the shell — the second time this session a `-f` pattern matched
the process running it. Start it with `setsid … & disown` and check `/tmp/.X11-unix/` for `X99`
rather than pattern-matching for the process.

### Swept clean: colour (no defects)

| Layer | Result |
|---|---|
| `OmniColors` palette | 21 names both sides, **every value identical** |
| Terminal base palette | same 16 xterm-variant colours, same 6×6×6 cube steps `[0,95,135,175,215,255]`, same 24-step grey ramp |
| Terminal themes | same five keys and labels (`system`, `omni_dark`, `solarized_dark`, `matrix`, `light`), and the same background/foreground/cursor triples behind each |

Two differences examined and both correct:

* **Compose's `background` role has no Flutter equivalent** — it was deprecated in favour of
  `surface`, and the legacy themes set the two to *different* tokens (bg0 vs bg1). The port carries
  `background` into `ThemeData.scaffoldBackgroundColor` and documents why, so the terminal's
  system-theme background resolves to bg0 on both sides. Not a divergence; a translation.
* **Light/dark is decided differently in the system branch** — Kotlin measures
  `relativeLuminance(scheme.background) > 0.5`, this port reads `Theme.of(context).brightness`.
  These agree for all four of the app's own themes (dark, light, AMOLED, high contrast), so the
  distinction is theoretical here and changing it would be churn.

**Two consecutive slices have now found nothing** (this and the data/commands/presets sweep before
it). That is worth stating plainly rather than hunting harder in the same places: the mechanical
axes — anything with a symbol to diff on both sides — are largely exhausted. What remains open is
the work that cannot be swept by grep: **action-by-action semantics** (does this button do the same
thing to the host?), **spacing and layout**, the rest of **accessibility**, **iOS**, and the
outstanding **action-level device coverage** task. Those need a screen driven, not a file compared.

### Swept clean: data model, remote tooling, and preset scripts (no defects)

Three axes swept in one pass, all at parity. Recorded so they are not re-derived — a clean axis is
worth as much as a defect, provided the sweep is written down.

| Axis | Method | Result |
|---|---|---|
| **Database columns** | Kotlin `Entities.kt` field names vs drift `tables.dart` getters | 96 vs 101 — **0 missing** |
| **Remote tooling** | every command head invoked on a host (`systemctl`, `journalctl`, `docker`, `podman`, `crontab`, `df`, `ss`, `smartctl`, package managers, …) | 27 vs 26 — the one difference, `apt`, is help text and a preset command, both present |
| **Preset scripts** | all 32 `presetKey` values, then the **command text** behind each shared key | 32 vs 32 keys, **0 differing commands** |

The commands matter more than the keys: a preset with the same name and a different body runs
something else on the user's server. All 20 comparable bodies are byte-identical once escaping is
normalised.

**Four false differences, and why they are worth naming.** The first comparison reported 11
differing commands and every one was an artifact of my extractor:

* Kotlin escapes `$` as `\$` inside its strings; Dart does not.
* Dart escapes `'` as `\'` inside single-quoted strings; Kotlin does not.
* Flutter concatenates a long command across lines **alternating `'` and `"` quoting**, so a regex
  matching only `'…'` truncated `fleet.syslog` at its first `||`.
* Picking "the longest string in the row" grabbed *labels* rather than commands for the five
  `homelab.pve_*` presets, whose commands are short (`qm list`, `pct list`).

Each looked exactly like a real finding. `fleet.syslog` in particular read as "Flutter only runs the
first of four fallbacks", which would have been a serious defect on any host without journald — and
the file shows all four present. **The lesson is the one from defect 78, one turn later: when a
sweep and the code disagree, suspect the sweep first.**

### 79 — split panes and live status figures were not operable or understandable without sight (closed)

Continuing the accessibility axis from 71 and 73 against the current Kotlin code, not against a
generic accessibility wish list. Four Kotlin semantic contracts were absent from Flutter:

| Surface | Kotlin contract | Flutter before |
|---|---|---|
| MultiSSH pane | `Terminal pane 1: host`, selected state, active/inactive state and an `OnClick` semantics action | A cyan border only; TalkBack could read both terminal grids but could not identify or focus either pane |
| Monitor health ring | `Health score: 82 out of 100` | The bare number and progress indicator |
| Fleet host score | `Health score: 82 out of 100` | The bare number |
| Fleet refresh countdown | `Refreshing in 15 seconds` | `15s` |

The pane gap was functional, not merely wording. Every per-session action targets the focused pane,
including typed input, the key bar and disconnect. A sighted user could tap the cyan-bordered pane;
an accessibility service had no equivalent action. `_FocusablePane` now exposes the same named,
selected action as Kotlin's `TerminalPaneFrame`, while leaving pointer input on `TerminalSurface` so
the wrapper does not compete for its gesture arena. Flutter has no direct `stateDescription`
property, so active/inactive is carried as the semantics value.

The three status figures now use explicit labels and exclude their terse visual descendants. This
does not add design scope: all three labels are the existing Kotlin defaults from
`OmniComponents.kt` (`ScoreRing` and `RefreshCountdown`). The server-card status dot was deliberately
left alone because the card already announces the host status; adding a second node would duplicate
information rather than improve parity.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,387 passed** (+1) |
| `shell_screen_test.dart` | 40 (+1) |
| API 35 surface sweep + walkthrough | **8 passed** |
| API 35 action suite | **5 passed** |

The split test dispatches a real `SemanticsAction.tap` through the platform dispatcher and asserts
that the selected state moves to the other pane. A synthesized pointer tap would only re-test touch
input and could pass while TalkBack remained unable to focus it.

**Negative controls.** Removing the pane's semantics `onTap` fails on the missing tap action.
Replacing the score and countdown labels with their terse visible values fails all three label
assertions.

**Device-run note.** The first validation attempt accidentally left two Flutter invocations alive;
one reinstalled/uninstalled the APK under the other, which reached 7 tests and then disconnected.
That result was rejected. After terminating the exact duplicate processes, a single clean invocation
executed all 8 tests and passed. The KGP built-in migration warning from four third-party plugins is
still emitted during Android assembly; it is a future toolchain warning, not a skipped test.

### 78 — an upgrading user's share sort was silently dropped (closed)

Found by diffing every persisted settings key between the two apps: 44 in Kotlin, 37 here. The first
pass reported 31 differences, which was wrong — this port maps its keys in `AppPreferences.keys`
rather than calling `getSetting` per key, so a grep for call sites measured the wrong thing.
Re-running against the actual key set left 8, of which 7 are legitimately absent (`first_run_complete`
is the write-only field removed from Kotlin in the parity branch; the `*_presets` keys are seeding
markers; `health_scoring` *is* persisted here, via a constant the regex missed).

The remaining one is real. Kotlin keeps **two** sorts and this port has **one**:

| | Kotlin | This port |
|---|---|---|
| Files tab | `sftp_sort` | `sftp_sort` — already read |
| Share browser | `share_sort` | *(none — a share takes over the Files tab)* |

So a user who only ever changed the sort while browsing a share had that choice dropped on upgrade.
`_restoreSortOption` now falls back to `share_sort` when this app has written nothing yet — the same
reasoning that keeps `app_lock_grace_ms` under its original Android key rather than a tidier one.

`SftpSortOption.fromStored` already lowercases, so Kotlin's `NameAsc` spelling reads correctly
without further work.

**The files sort wins when both exist.** Not a merge: `sftp_sort` is this app's own key and the one
it writes, so a value the user set *here* must not be overridden by one carried in from the old app.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `dart format --set-exit-if-changed --line-length 100 .` | passes |
| Full host suite | **2,384 passed** (+2) |
| `sftp_view_model_test.dart` | 135 (+2) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**Negative control.** Dropping the `share_sort` fallback fails the migration test; the precedence
test keeps passing, which is the right shape since it asserts the *absence* of an override.

**A claim in an existing test was worth checking rather than trusting.** `sort order persistence`
says Kotlin writes `sftp_sort` at `AppViewModel.kt:1410` — my key diff appeared to contradict it,
and the test was right: the key is in both apps, so it never showed up in the difference. Worth
recording because the instinct on seeing a contradiction was to doubt the older claim, and the newer
measurement was the faulty one.

### 77 — biometric unlock was offered where it cannot work (closed)

Found by generalising defect 76's method: instead of chasing one symbol, sweeping every public
member in `lib/` for one with no reference outside its own file. That produced 36 candidates, most
of them legitimate. This one was not, and it is in an area worth being strict about.

```dart
/// True when the device has an enrolled biometric or device credential to check against.
///
/// Checked before offering the option: enabling "unlock with biometrics" on a device with none
/// enrolled would leave the user staring at a button that can never succeed.
Future<bool> isAvailable() async { … }
```

`grep -rn isAvailable lib test integration_test` returned its own definition and an unrelated
in-app-purchase call. **The comment describes a check that does not happen**, and the consequence is
precisely the one it warns about. This is the same shape as the Kotlin `isFirstRun` removal in the
parity branch — a comment asserting a behaviour nothing implements — and it is worth noting that
both survived review because the *documentation* was correct about intent.

**The fix** gives `AppLockController` an optional availability probe, wired in `main.dart` to
`BiometricAuth.isAvailable`, and gates the Settings switch on it with a subtitle naming the reason.
Two states needed distinguishing, because they need different actions from the user: *"enable the
lock first"* and *"this device has nothing enrolled"*.

Three deliberate choices:

* **It fails open.** No probe wired — tests, and any build without one — leaves the option offered
  exactly as before. A wrong "unavailable" hides a working feature; a wrong "available" costs one
  prompt that falls back to the PIN.
* **A probe that throws counts as unavailable, and `load()` still completes.** A hardware probe must
  never stop the lock loading: a controller that failed to load would leave the app unlocked.
* **The switch's *value* is gated too**, not just its enabled state, so a device that loses its
  enrolment does not keep showing biometrics as on.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `dart format --set-exit-if-changed --line-length 100 .` | passes |
| Full host suite | **2,382 passed** (+4) |
| `app_lock_test.dart` | 61 (+4) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**Negative control.** Ignoring the probe's result fails two of the four new tests — the mutation was
asserted to have applied before running.

**Also found, not fixed:** `lib/platform/biometric_gate.dart` is a **second, unused biometric
implementation** duplicating the live `BiometricAuth`, including its own `canAuthenticate`. Nothing
references it. It is a hazard rather than a defect — the risk is that someone wires the wrong one —
and deleting it is a decision left rather than taken, since this slice was about the missing check.

**The orphan sweep's other findings**, recorded so they are not re-derived: `moveScript` (superseded
by the renumbering reorder beside it), `setAvailableForFleet` and `setAvailableForQuick` (the editor
dialog sets both flags; Kotlin has no inline toggle either, only display tags), `lockNow` (no Kotlin
counterpart), `clearBulkSelection`, `clearTargets`, `finishInput`, `adoptScrollbackFrom`. **None is
a parity gap** — checked against Kotlin rather than assumed — so they are dead or convenience code,
not missing wiring.

### 76 — the split launcher shortcut had no caller (closed)

The last piece of the multi-SSH gap, and the purest example of this session's dominant defect class
so far. Every layer was built:

```
lib/platform/shortcut_helper.dart   Future<bool> pushSplit(Server first, Server second)
android/.../ShortcutBridge.kt       "pushSplit" -> upsert(manager, splitShortcut(context, args))
                                    splitShortcut(): id "split_${first}_$second", both extras set
```

and `grep -rn pushSplit --include=*.dart lib test` returned **one line — its own definition**. The
Dart method, the method-channel handler, the `ShortcutInfo` builder and the launch-intent extras
were all written, and nothing ever invoked any of it. Kotlin pushes the shortcut whenever two hosts
are loaded into panes, so a user who splits regularly gets a one-tap way back to that pair; the port
silently offered nothing.

**The fix** calls it where the split is established — `splitWith`, which both the picker and
`splitWithNewSession` (defect 75) go through, so there is one place rather than two. `ShellViewModel`
takes a `ShortcutHelper` the way the other view models do, and `main.dart` provides it — without
that last line this would have been the same defect one layer up.

The pair is recorded in **pane order**, so the shortcut reopens the layout the user had rather than
a mirror of it.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `dart format --set-exit-if-changed --line-length 100 .` | passes |
| Full host suite | **2,378 passed** (+2) |
| `shell_view_model_test.dart` | 41 (+2) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

Tested with a `ShortcutHelper` subclass that records instead of calling the platform — the channel
itself is not the thing in doubt. The second test pins the degradation path: with no helper at all,
splitting still works and simply offers no shortcut, which is how every other `ShortcutHelper`
action behaves.

**Negative control.** Removing the `_offerSplitShortcut()` call fails the first test — and the
mutation was asserted to have applied before running, after the lesson recorded in defect 75.

**The multi-SSH gap is now closed** as far as it is worth closing. Of the four differences listed
below: the host-picker selection is served by defect 75's sheet (a checkbox flow *as well* would be
two ways to do one thing), the focused-pane model was already present, the connect-into-pane flow is
defect 75, and the shortcut is this entry.

### 75 — a second host could not be opened into a pane (closed)

The first slice of the multi-SSH gap recorded below, chosen because it is the part that stands on
its own: it extends the split the port already has rather than starting a second, competing one.

**Before:** `splitCandidates` listed only sessions that were already connected, and the split control
was gated on `sessions.length > 1`. With one terminal open the control was hidden and the sheet said
*"Open a second session first"* — so putting a host alongside meant connecting it, watching it take
over the screen, and splitting back. Three steps for what Kotlin does in one.

**After:** the sheet has a second group, *"Connect into the second pane"*, listing online hosts with
no session open. `splitWithNewSession` connects and splits in one action, reusing the sequence
`main.dart`'s `open_split` external action already performs.

Two details that are the whole behaviour:

* **The current pane is restored after connecting.** `connect` focuses what it opens
  (`shell_view_model.dart:687`), which is right normally and wrong here — the user asked for this
  host *alongside* the one they are reading, not in front of it.
* **A failed or cancelled connection leaves the split untouched.** `connect` has already put its
  reason on screen; forcing a split with nothing in it would replace that explanation with an empty
  pane.

The visibility gate widened to `sessions.length > 1 || canConnectSecondPane`, or the new entries
would be unreachable in exactly the case they exist for. A host already open is not offered again —
it would appear twice, once as a session and once as a host, and connecting it twice would open a
duplicate terminal to the same machine.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `dart format --set-exit-if-changed --line-length 100 .` | passes |
| Full host suite | **2,376 passed** (+2) |
| `shell_screen_test.dart` | 39 (+2) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**A negative control that proved nothing, and how it was caught.** The first attempt at mutating the
focus-restore reported *all tests passing* — which would have meant the restore was dead code. It
was not: the mutation string never matched, so nothing was mutated and the control could not fail.
Re-run with `assert s.count(old) == 1` before mutating, it fails the new test as it should. **A
mutation that is not asserted to have applied is not a negative control**, and this is the second
time that class of mistake has appeared in this session.

**Still open** from the multi-SSH comparison below: the host-picker checkbox flow with `P1`/`P2`
badges, and the launcher shortcut. The focused-pane model turned out to be **already present and
wired** (`focusPane`, `shell_screen.dart:933`) — worth recording, because the entry below listed it
as missing on the strength of Kotlin having a named field for it.

### Open, evidenced: multi-SSH is a *mode* in Kotlin and an ad-hoc split in Flutter

Not fixed. Investigated to the point where the shape is certain, and written down so the next
session starts from evidence rather than from the guess this began as.

It surfaced from the accessibility sweep — a checkbox with a stateful label, *"Add nas to split
panes"* / *"Remove nas from pane 2"* (`ui/AppUi.kt:211`) — and following it found the label was the
smallest part.

**Kotlin has a second terminal mode.** `isMultiSsh` is `activeSshTab == 1`
(`AppViewModel.kt:1589`), and it carries:

| | Kotlin | Flutter |
|---|---|---|
| Entry from the host picker | checkboxes with `P1`/`P2` badges and *"Load selected hosts into panes"*, enabled at 2/2 (`AppUi.kt:196–235`, gated by `allowSplitSelection`) | **none found** |
| Pane focus | `multiSshFocusedPane`; the header, key bar and actions all address the focused pane | ~~no focus concept~~ — **present after all**: `focusPane` swaps primary and split, wired at `shell_screen.dart:933` (corrected while closing defect 75) |
| Entering split | pane 2 defaults to another live session, or shows its own connect prompt | `splitWith(id)` picks from **already-connected** sessions only |
| Leaving split | focused pane's session becomes the single current session (`AppViewModel.kt:1661`) | `unsplit()` drops the second pane |
| Launcher shortcut | `pushSplitTerminalShortcut(srv1, srv2)` | — |

**What Flutter does have:** `splitWith`, `unsplit`, `toggleSplitAxis`, `splitCandidates`, and the
`open_split` external action in `main.dart`, which connects two hosts and splits them. So splitting
works; what is missing is choosing two hosts *before* connecting, and the focused-pane model that
Kotlin's whole shell header is written against.

**Why it is not a slice.** It is a mode, a selection UI, a focus model and a shortcut. Sizing it
honestly matters more than starting it: half of this landed would be worse than none, because
`splitWith` already works and a partial second path would give two ways to split that disagree.

**Where to start:** `ui/ShellScreen.kt:482` (`allowSplitSelection = viewModel.isMultiSsh`) is the
single switch that turns the host picker into the selection UI; read outward from there.

### 74 — a crash report could be lost by the button meant to save it (closed)

Found by sweeping action feedback: Kotlin has 13 toasts, Flutter 17 snackbars. Most of the wording
differs harmlessly, but two Kotlin messages describe *failure* paths — "Couldn't share the report"
and "No browser found — issue link copied to clipboard" — and chasing those into Flutter found the
handling, not the copy, was wrong.

**Handing work to another app fails in two ways, and only one is a return value.** `launchUrl`
answers `false` when a handler declines, and **throws** when there is no handler at all.
`SharePlus.share` only throws.

The same file already knew this — `_openUrl` wraps its call in a try/catch — but the knowledge had
not reached the two call sites next to it:

| Call site | Before | Consequence |
|---|---|---|
| `_reportCrash` | `if (!await launchUrl(...))` | On a device with no browser: no browser, **no copy**, no message. The fallback that exists precisely for this case was itself taken down by the throw. |
| `_shareCrash` | bare `await SharePlus…share(...)` | Share fails, nothing said. Kotlin reports it. |

The report is the one artefact worth keeping when the app has just crashed, and the button offering
to save it was the one that dropped it.

`_shareCrash` now also falls back to the clipboard, because that is the only other way to get a
report off the device.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `dart format --set-exit-if-changed --line-length 100 .` | passes |
| Full host suite | **2,374 passed** (+1) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**On the test, honestly.** I first wrote a widget test that stubbed the launcher to fail and drove
the real button. It passed for the wrong reason: `url_launcher_android` routes through **pigeon**
channels, not the plain `MethodChannel` a test can stub by name, so the stub was never consulted and
the launch "succeeded". I spent a long time on that before recognising it, and threw it away rather
than keep a test whose green meant nothing.

`test/external_handoff_guard_test.dart` replaces it: a source scan asserting that every `launchUrl`
and `SharePlus…share` call sits inside a `try`. It cannot prove the fallback *behaves* — that limit
is written into the file — but it does prove no call site is left unguarded, which is the defect
that actually happened, and it fails with the file and line of any new one.

**Negative control.** Restoring the unguarded `_reportCrash` call fails the guard, naming
`about_screen.dart:142`.

### 73 — the terminal output was invisible to a screen reader (closed)

Continuing the accessibility axis that defect 71 left part-swept. 71 covered icon-only *buttons*;
this is the content itself.

The terminal surface paints its grid with a `CustomPaint`, which puts **nothing** in the semantics
tree. Not a wrong label — no node at all. On an SSH client that is the primary content of the
primary screen: a screen-reader user could reach the terminal, type into it, and never hear a word
of what came back.

Kotlin labels the same surface, and the port simply dropped it:

```kotlin
.semantics {
    contentDescription = "Terminal output: " + snapshot.rows
        .joinToString("\n") { row -> row.spans.joinToString("") { it.text } }
        .takeLast(2_000)
}
```

**The fix** adds `Semantics(label: terminalSemanticsLabel(...), readOnly: true)` around the painter.
Three decisions, all inherited or forced:

* **The cap is 2,000 characters**, as Kotlin's is. A cap is needed because the label is re-announced
  whenever it changes; uncapped, a terminal would read its whole grid on every arriving character.
* **The tail is kept, not the head** — a terminal's newest output is the part being read.
* **The label is built from the viewport snapshot**, not the full buffer, so it costs a short string
  per publish rather than a walk of the scrollback. `session.snapshot` is already the viewport
  window the surface paints, so this is free.
* **An empty grid is named `Terminal output: empty`** rather than left blank, because a blank label
  makes the node *unlabelled* rather than *empty* — which reads as a bug rather than an idle
  terminal.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| `dart format --set-exit-if-changed --line-length 100 .` | passes |
| Full host suite | **2,373 passed** (+4) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

Three unit tests on the pure `terminalSemanticsLabel`, plus one end-to-end test that reads the real
`SemanticsNode` off the live surface — the pure function being right proves nothing about whether it
reaches the tree, which for a `CustomPaint` is the entire question.

**Negative control.** Removing the label leaves the node without one and fails the end-to-end test.

**Accessibility axis, still open:** non-interactive `Icon`s that convey state, `Semantics` grouping
on composite rows (a host card announces as its separate fragments), focus order, and announced
state changes (`liveRegion`). Icon-only buttons (71) and terminal content (73) are done.

### 71 — thirty icon-only controls had no accessible name (closed)

Sweeping the accessibility axis. Kotlin carries 179 `contentDescription`s; the 59 that are `null`
are decorative icons, which is the correct use of null rather than an omission. The port dropped the
names on every icon-only *button*:

```
IconButtons with neither `tooltip:` nor `semanticLabel`: 30
```

To a screen-reader user each announced as "button" with no indication of what it does — every
dismiss and close, the find bar's previous/next arrows, the numeric steppers. The controls worked;
they were simply unnameable, which for a blind user is the same as not working.

**The fix** adds `tooltip:` to all thirty, which supplies the semantic label and a long-press label
in one. Wording follows Kotlin where it has some ("Dismiss", "Clear", "Close image preview", "Close
editor"), and otherwise plainly describes the effect.

**The guard matters more than the fix.** `test/accessibility_labels_test.dart` scans `lib/` and
fails with the file, line and widget key of any icon button lacking a name. A per-screen widget test
would only cover screens someone remembered to write a test for, and the defect here was not that
one screen was wrong — it was that nothing stopped the next one being wrong.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,369 passed** (+1) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**Negative control.** Removing a single tooltip fails the guard and names it exactly:
`lib/ui/widgets/terminal_transcript_sheet.dart:168 (transcript.close)`.

**Not swept here:** non-interactive `Icon`s, `Semantics` on composite rows, focus order, and
announced state changes. This entry closes icon-only *buttons* only, and the rest of the
accessibility axis remains open.

### 72 — the branch would have failed CI's format gate (closed)

Not a parity defect. A mistake of mine, recorded because it was committed and would have failed the
first PR check that ran.

`flutter-pr-check.yml` formats with an explicit width:

```yaml
run: dart format --output=none --set-exit-if-changed --line-length 100 .
```

I had been running plain `dart format` — default width **80** — after every slice this session, and
those files went into the commits. Verified against HEAD rather than assumed: formatting three
committed files at width 100 changes all three, so the branch as pushed does not satisfy the gate.

Found only because a careless `dart format lib` reformatted 122 files at once and the size of the
diff was obviously wrong. The narrower per-file commands had been making the same error quietly all
along — the visible mistake exposed the invisible one.

**The fix** reformats `lib`, `test` and `integration_test` at width 100; 163 files changed, and the
tree now passes CI's exact command. Two consequences worth knowing:

* **The diff is large and almost entirely mechanical.** Reviewing it line by line is not useful;
  `dart format --output=none --set-exit-if-changed --line-length 100 .` returning 0 is the check
  that matters.
* **Always pass `--line-length 100` in this repository.** The default is not the project's style,
  and nothing local catches the difference — `flutter analyze` is silent on formatting, and the
  branch has no PR, so the gate that would have caught it never ran.

### 70 — turning App Lock off never said what it destroys (closed)

The last item from the confirmation-dialog sweep. Unlike 68 and 69, the capability was present and
reachable — only the warning was missing, which is what I had expected all three to be.

Defect 62 already made the *save* re-authenticate, so this switch could not be flipped by someone
who could not already pass the lock. What was still missing is that the switch does more than it
says: it deletes the stored PIN and the biometric enrolment, and there is no undo — turning the lock
back on means enrolling from scratch.

**Ordering is the part worth getting right.** The confirmation runs **before** the
re-authentication, as Kotlin orders it (`:3903` then `:3902`). The other way round would collect the
user's PIN and *then* reveal that passing the prompt is what deletes it — asking someone to
authenticate before telling them what they are authorising.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,368 passed** (+1) |
| `settings_screen_test.dart` | 21 (+1) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**Negative controls.** Two, because the branch has two ways to fail open:

| Mutation | Result |
|---|---|
| Skip the confirmation entirely | the new test fails |
| Ignore Cancel and save anyway | the new test fails |

**This one is testable where defect 62's gate was not**, which is worth recording. The prompt fires
*before* the `AppLockController` gate and keys off saved-versus-draft state, so it needs no live
controller — and it is the live controller's background-lock timer that stops `pumpAndSettle`
quieting and left 62's wiring uncovered. The test also asserts that turning the lock *on* does not
ask, so a prompt attached to the switch rather than to the disabling direction would not pass.

**Dialog axis complete.** Kotlin's 70 `confirm.ask` sites, compared by concept rather than by
string, left four gaps: force kill (68), clear scrollback (69), this one, and "Remove trusted key?",
which turned out to be present with different wording. Two of the four were missing *capabilities*
rather than missing prompts — the sweep was worth running for that reason alone.

### 69 — the scrollback could be read but never dropped (closed)

The second of the three confirmations defect 68 left open, and — like 68 — the missing dialog turned
out to be the smaller half. The capability itself was unreachable:

```dart
void clearScrollback() { _scrollback.clear(); _scrollbackSpanCache.clear(); }   // one caller:
if (mode == 3) clearScrollback();                                              // the DECSTR handler
```

So the only thing that could clear the buffer was the remote sending an escape sequence. Nothing the
user could tap reached it. Kotlin puts the action beside the copy ranges (`ui/ShellScreen.kt:2508`),
which is where defect 67 had just built the same sheet.

**Why it matters more than housekeeping.** A long session's scrollback holds up to 2,000 rows of
whatever was printed — credentials echoed by a careless script, customer data from a query, a token
in a log line. Clearing it is a privacy action, not just a memory one. And with a **persistent tmux
session** the buffer survives leaving the session, so there was no way to drop it short of
uninstalling.

**The fix.** `ShellSession.clearScrollback()` clears the emulator and snaps the viewport back to the
tail — every row it might have been anchored to is gone, and leaving it anchored would render a
blank region above the live screen. The sheet asks first, in Kotlin's words.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,367 passed** (+1) |
| `shell_screen_test.dart` | 36 (+1) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**Negative control.** Making the confirmed path skip `emulator.clearScrollback()` fails the new
test. The test also asserts Cancel keeps the buffer, and that the live screen survives — a clear
that took the screen with it would pass a weaker assertion.

### Correction to defect 68's open list

**"Remove trusted key?" is not a defect.** I listed it as possibly missing, and speculated that if
host-key revocation did not exist it would be a security defect. It does exist: the Auth Keys screen
has a trusted-hosts section with a per-host revoke button (`authKeys.trust.<host>.revoke`) that goes
through `_confirmRevoke`, and `AuthKeysViewModel.revokeKnownHost` removes the pin. Only the wording
differs from Kotlin's. Recorded because the speculation was published in the ledger and would
otherwise be inherited as a finding.

That leaves **"Turn off App Lock?"** as the one item still open from the dialog sweep — a missing
confirmation, with the serious half (re-authentication before the save that clears the PIN) already
closed by defect 62.

### 68 — SIGKILL was implemented but unreachable (closed)

Found by sweeping the confirmation-dialog axis: Kotlin has 70 `confirm.ask` sites, Flutter had 32
`?`-titled dialogs. Comparing the *destructive* ones by concept rather than by string left four with
no Flutter counterpart — clear scrollback, remove trusted key, turn off App Lock, and force kill.
This entry closes the fourth; the other three are recorded below as still open.

This is the session's dominant defect class in its purest form. The capability was fully
implemented:

```dart
Future<void> killProcess(int pid, {int signal = 15}) async { … }   // signal honoured throughout
String killProcessCommand(int pid, {int signal = 15}) => 'kill -$signal $pid 2>&1';
```

and the one call site was `vm.killProcess(proc.pid)`. Nothing ever passed a signal, so the parameter
— and the command builder's support for it — existed, was tested, and could not be reached.

**What it cost the user.** SIGTERM is *the signal a wedged process ignores*, so the single situation
that makes you open a process list and reach for Kill was the one the app could not resolve. The
workaround is a shell session and `kill -9` typed by hand, which is exactly what the Monitor screen
exists to avoid.

**The fix.** A second action per row, and `_confirmKill(force:)` selecting the signal. Kotlin's
warning is kept verbatim in substance — *"Unsaved work in that process is lost"* — because the
consequence is the whole difference between the two actions.

They are deliberately **not** one dialog with a checkbox: whether the process gets to save its work
is a choice to make *before* confirming, not while confirming.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,366 passed** (+1) |
| `monitor_screen_test.dart` | 42 (+1) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**Negative control.** Reverting the call to `vm.killProcess(proc.pid)` — the old behaviour — fails
the new test. The test also asserts the *absence* of `kill -15`, so a force action that sent both
signals would not pass.

**Still open from this axis**, each a Kotlin confirmation with no Flutter counterpart, and each
needing its underlying action checked before assuming the dialog is all that is missing:

* **"Clear scrollback?"** — `TerminalEmulator.clearScrollback()` exists and is called only by the
  DECSTR escape handler (`mode == 3`). There appears to be no user-facing action at all, so this is
  probably a missing feature rather than a missing prompt.
* **"Remove trusted key?"** — no match anywhere in `lib/`. Host-key trust can be granted; whether it
  can be revoked needs checking. If it cannot, that is a security defect, not a copy one.
* **"Turn off App Lock?"** — disabling the lock clears the stored PIN (see defect 62) and Kotlin
  confirms before doing it. Flutter's settings save is now re-authenticated, which covers the
  serious half, but the explicit confirmation is absent.

### 67 — the terminal offered one copy range where Kotlin offers two (closed)

Found by sweeping the long-press axis, which the handover still listed as unswept. The axis itself
was nearly clean — Kotlin has five long-press sites and Flutter had counterparts for four, the fifth
being a Tools card whose `onLongClick` is identical to its `onClick` and so carries no behaviour.
The defect was not a *missing* handler but a handler doing something different.

| | Kotlin | Flutter (before) |
|---|---|---|
| Long press | Visible screen | Full buffer |
| Second range | Full buffer, via the chooser at `:2491` | *none* |

So the port had exactly one of the two ranges, and it was the wrong one to default to:

* **The common case was unreachable.** Copying the error currently on screen — the reason to reach
  for this at all — could only be done by copying thousands of lines and finding it again.
* **Every long press did the expensive thing.** `session.snapshot` is already the viewport window
  the surface paints, but the sheet called `session.emulator.snapshot()`, building spans for the
  entire scrollback (limit 2,000 rows) on each open. Kotlin defaults to the cheap range for this
  reason.

**The fix.** `TranscriptRange` and `transcriptTextFor` make both ranges explicit; the sheet opens on
`visibleScreen` and a button switches to `fullBuffer` and back. The title, the copy tooltip and the
confirmation snackbar all name the range, because "Transcript copied" after copying 2,000 lines when
you wanted 12 is a silent wrong answer.

**Evidence.**

| Gate | Result |
|---|---|
| `flutter analyze --fatal-infos` | clean |
| Full host suite | **2,365 passed** (+1) |
| `shell_screen_test.dart` | 35 (+1) |
| Surface sweep + walkthrough, API 35 `emulator-5554` | **8 passed** |

**An existing test was changed, deliberately.** `output that scrolled out of view is still in the
transcript` asserted that a long press shows `line 0` — the behaviour this defect corrects. It is
replaced by a test asserting the visible screen excludes `line 0`, and that the full buffer still
contains it, so the capability it protected is still covered rather than dropped. A second test
switches back, since a one-way toggle would trade one missing range for the other.

**Negative control.** Defaulting `_range` to `fullBuffer` — the old behaviour — fails both new
tests.

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
