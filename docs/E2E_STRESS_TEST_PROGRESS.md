# End-to-end stress-test progress

Last updated: 2026-07-18

This is the durable checkpoint for the current physical-device and disposable-lab stress-test campaign. Update it after each verified fix so work can stop and resume without repeating expensive runs.

## Safety boundaries

- Never commit or paste values from `secrets/hosts.txt` or `secrets/wifi.txt`. The whole `secrets/` directory is ignored.
- Treat the public host as read-only. Run destructive, package, container, proxy, and file-transfer experiments only on the disposable Raspberry Pi lab.
- Pass lab addresses and credentials as instrumentation arguments at runtime; do not hard-code them in tests, logs, screenshots, or recordings.
- Use test ads and the configured test-device identifier during device testing. Do not include the identifier in public recordings or repository files.

## Verified on the physical Android device

### Terminal and session lifecycle

- `E2eTerminalStressTest` passed in 75.681 seconds.
  - 3,500-line ordinary shell output and 4,500 wide tmux lines, including ANSI and Unicode.
  - 120 resize bursts.
  - Mixed ordinary/tmux splits in both pane orders.
  - Exactly one leave prompt for the one remaining live pane.
  - Ordinary-session background traffic and tmux park/restore with history.
  - Scroll isolation and reverse-order destructive disconnect.
- `E2eTerminalLifecycleStressTest` passed in 41.068 seconds.
  - Mixed ordinary/tmux split across Home, remote output, screen off/on, keyguard dismissal, configuration recreation, and a literal system Recents swipe.
  - The test temporarily locked portrait so Quickstep and ADB shared a coordinate space, verified the OmniTerm accessibility snapshot disappeared after the swipe, and restored the device's rotation settings during cleanup.
  - The persistent pane's real foreground notification resumed the app. Pane order, layout, focus, and both live sessions were intact; post-resume input succeeded in both tmux and ordinary SSH.
- The expanded `E2eTerminalLifecycleStressTest` passed in 47.988 seconds after the adaptive toolbar change.
  - Persistent/tmux panes expose `LEAVE` directly and ordinary panes expose `BG`, including mixed split orders.
  - The destructive Disconnect dialog contains only Disconnect/Cancel; it no longer nests background or resumable actions.
  - Accessibility assertions cover both toolbar actions and the pure destructive gate.
- `E2eTerminalNavigationMatrixTest` passed on the physical device in 47.230 seconds without contacting a remote host.
  - Real Compose UI clicks covered every direct bottom-tab destination (Servers, Fleet, Monitor, Files, Containers, and Tools) from a two-pane terminal, with accidental Stay and system-Back dialog dismissal preserving both sessions and pane attachments.
  - Unsplit, one-pane split, two-pane split, first-pane disconnected, both panes disconnected, ordinary Background, mixed ordinary/tmux `Keep sessions`, single/all-tmux `Leave resumable`, and destructive `Disconnect`/`Disconnect all` combinations all committed the original destination exactly once.
  - Backgrounding both ordinary panes preserves the user's split layout with two empty pane pickers and live background sessions; returning to Term and leaving again does not re-prompt because no session is attached to either pane.
  - The suite explicitly closes the terminal IME before direct-tab checks, covering the landscape behavior where global chrome is intentionally hidden while the keyboard is visible.
- `E2eTerminalNetworkRecoveryStressTest` passed in 73.726 seconds.
  - A real 12-second Wi-Fi outage exceeded the seeded ten-second SSH keepalive while direct tmux, HTTP-proxy, SOCKS5-proxy, and SSH-jump interactive sessions were active.
  - All four original session objects recovered, split-pane order stayed intact, every route accepted fresh commands, and tmux delivered the end of its background stream after reconnection.
  - Cleanup now reconciles all active Android notifications in the session channel, not only ids remembered by the current Service instance. The suite verified zero terminal notifications after repeated failed/successful service lifecycles.
- The terminal navigation matrix has a deterministic 10,000-case unit test covering mixed session types, pane orders, and leave actions.
- Large tmux replay is attached and painted immediately while history hydrates in the background; the 500 KiB replay timeout regression test passes.

### Compose builder, YAML, and syntax highlighting

- `E2eComposeBuilderUiStressTest` passed in 49.661 seconds.
  - Lossless parse/render for a 335,783-byte, 11,635-line, 400-service Compose fixture.
  - Comments, anchors, profiles, health checks, mappings, block strings, Unicode, secrets, configs, and custom build structures.
  - Large visual-mode virtualization and paged raw-editor navigation.
  - Unsaved edits across portrait and landscape recreation.
  - Full-screen editor Back behavior and dirty raw-to-visual confirmation.
- The fixture passes `docker compose config -q` in the disposable lab.
- Flow-style top-level `volumes` and `networks` parsing has a regression test preventing header loss during a no-op render.
- Syntax/editor unit coverage includes malformed input, quotes, comments, URLs, anchors, Unicode, shell escaping, the exact 200,000-character paging boundary, and page clamping.
- `E2eComposeDeployStressTest` passed on the physical device in 54.904 seconds.
  - A Docker custom-image stack deployed through Raw YAML and a Podman stack deployed through the visual builder.
  - Malformed YAML failed safely and restored the previous remote file; successful and failed no-edit deployments preserved all three fixtures byte-for-byte.
  - The draft remained bound to its originating host even when that host had stale offline status, preventing an Infra recomposition from silently deploying through another selected host.
  - Pinned Podman actions prefer native `podman-compose`; this avoids `podman compose` dispatching to an installed Docker Compose plugin and the wrong runtime socket.
- The disposable Podman fixture retains read-only filesystems, tmpfs mounts, labels, networks, dependencies, and rootless execution. Its invalid forced nginx UID was removed after an isolated provider run proved it caused a permission failure and an indefinite dependency wait.

### Network and SSH paths

- `E2eNetworkToolsTest` passed against the disposable lab.
  - Ping, traceroute, port probe, DNS, WHOIS, speed test, and LAN scan.
  - Real HTTP through local forwarding and dynamic SOCKS5 forwarding.
- SOCKS forwarding and jump-host host-key alias handling have regression coverage.
- Disposable SSH, FTP, SMB, WebDAV, Docker, HTTP proxy, and SOCKS services were used; the public production host was not mutated.
- `E2eRemoteFilesStressTest` passed on the physical device in 28.161 seconds.
  - FTP, SMB, SFTP, and HTTPS WebDAV each completed isolated create/list, 2 MiB upload with monotonic progress, byte-for-byte download, overwrite-not-append, Unicode/space rename, nested directory and empty Unicode file handling, and reverse cleanup.
  - The suite uses unique disposable directories and verified that no protocol left an artifact after completion. The Android crash buffer and app fatal/ANR log scan were empty.
  - The WebDAV lab now uses a dedicated TLS CA and port 8443. Its public CA is trusted only by the debug source set; release variants retain the system-only trust configuration and cleartext WebDAV remains rejected.
- `E2eFilesUiStressTest` passed the combined FTP/SMB/SFTP/HTTPS-WebDAV UI matrix on the physical device in 77.672 seconds.
  - Each saved profile completed the visible create, rename, and delete dialogs; nested navigation; bookmark add/remove and unified bookmark persistence; explicit refresh; and Activity recreation while inside the bookmarked directory.
  - The run exposed a WebDAV collection-MOVE false success: Apache redirected a directory URL without its canonical trailing slash and OkHttp followed the redirect as a successful non-MOVE response. The common rename contract now carries the directory type so WebDAV sends canonical source and destination URLs; the focused WebDAV rerun passed in 28.758 seconds.
  - Unique directories, pre-test bookmark values, auto-rotation, and Wi-Fi state were restored. No disposable directory, crash-buffer entry, app fatal exception, or ANR remained.
- `E2eFileTransferLifecycleStressTest` passed on the physical device in 90.030 seconds.
  - Live FTP, SMB, SFTP, and HTTPS WebDAV uploads cancelled within their bounded waits and left neither final nor hidden staging files.
  - A 32 MiB SFTP upload survived CREATED/RESUMED transitions and Activity recreation with the same retained ViewModel and exact remote size.
  - Cancelled downloads deleted their partial SAF documents; short local providers failed before commit; Retry stayed bound to the original endpoint and path after UI navigation.
  - A real Wi-Fi disable/enable cycle cancelled a blocked FTP upload, recovered the endpoint, and left no partial data.
  - The UI overwrite gate, FTP→SMB copy, SMB→HTTPS-WebDAV move, SHA-256 verification, and independent dual-pane SFTP navigation all passed.
  - Transfers now stage to hidden siblings and atomically commit with destination backup/restore. SFTP cancellation closes its active stream before the JSch channel so pipe-backed providers cannot remain blocked.

### Alerts, notifications, and refresh lifecycle

- `E2eAlertLifecycleStressTest` passed on the physical device in 45.594 seconds.
  - Created a host-scoped rule through the UI host picker, fired it from real disposable-lab telemetry, and verified its exact Android system notification.
  - Mute dismissed the notification; the muted incident and Unmute action survived Activity recreation; Unmute reposted the notification.
  - A real Wi-Fi disable/enable cycle preserved the incident, restored the host, and left the UI responsive.
  - Global disable/enable reconciled notification state without discarding the incident; acknowledgement dismissed it and recorded history.
  - Editing the rule closed the old incident as resolved, and a restarted five-second auto-refresh poller fired a new incident without a direct host refresh.
- Manual and periodic telemetry probes are serialized per host. Active incidents also have a database-unique `(ruleId, serverId)` identity using conflict-ignore semantics, so concurrent refreshes cannot reset acknowledgement/mute state or create duplicate cards.
- Schema 19 migrates legacy duplicate incidents by retaining the newest row before creating the unique index. Both the full schema 8→19 chain and the targeted duplicate migration passed on-device.

### Settings, crash capture, Fleet, and power state

- The focused Settings draft lifecycle passed in 14.281 seconds.
  - An unsaved text-size draft survived Activity recreation in Compose save state, retained the same ViewModel, and guarded navigation until explicit discard.
- The Settings/backup/security method passed in 83.833 seconds.
  - Theme, font, scrollback, link, tmux-control, accessibility, AMOLED, syntax-highlight, telemetry, and large-transfer threshold bounds were exercised.
  - Selective encrypted settings export rejected a wrong passphrase and corrupted envelope, restored valid settings into live state, and excluded device-local lock data.
  - PIN setup, wrong-PIN handling, zero-grace background relock, typed unlock, biometric enablement, and lock disable cleanup passed.
- `batterySaverFleetCancellationAndAutoRefreshRemainCoherent` passed in 29.696 seconds.
  - Rooted Android battery simulation engaged saver, released keep-screen-on, resumed polling after manual refresh, and restored device battery state during cleanup.
  - The run exposed and fixed an asynchronous keep-screen-on write that could re-enable the flag after battery saver released it.
  - Explicitly confirmed Fleet targets are no longer silently removed by stale cached offline status. A small probe, 180 KiB truncation/tail marker, infinite-stream cancellation, and the next five-second refresh cycle passed.
- The controlled startup crash suite passed in 10.409 seconds.
  - Startup capture, history persistence, recovery, clearing, and redaction of credentials, authorization data, URI userinfo, private keys, IP addresses, and private paths were verified.
- `CrashLogRedactionTest` passed locally. The controlled crash uses only reserved test-network data and the hook is debug-only.
- The Android 15 adaptive-icon render check passed on the physical device in 6.320 seconds.
  - The biometric prompt's monochrome source was an opaque full-colour tile, which Android reduced to a featureless grey circle.
  - Both adaptive launcher variants now use a transparent OmniTerm infinity/terminal vector mask; the device render asserts meaningful alpha coverage and rejects an opaque tile.
  - The reproducible real-prompt visual fixture safely skips on this device because no strong biometric is currently enrolled; secure biometric enrollment was not modified through root.
- `E2eForegroundServiceProofTest` passed on the physical device in 42.414 seconds; the exact recorded rerun passed in 42.338 seconds.
  - Enabling background keep-alive for an already-active session now recomputes the permission need immediately instead of waiting for an unrelated Activity resume.
  - Granting notification permission reposts the already-running service payload, because Android does not retroactively reveal a foreground-service notification that was started while permission was denied.
  - The opt-in flow keeps endpoint setup behind `FLAG_SECURE`, uses the neutral label `E2E Foreground Demo`, proves the in-app disclosure, Android permission dialog, and live service/session notification, then restores keep-alive, capture, and session state.
  - The ignored local proof artifact is `artifacts/omniterm-foreground-service-proof-sanitized-final.mp4` (15.700 seconds, SHA-256 `840bda42d424f8cd2814c288016f19a72ba93075aecea4bc9adef06f704e003c`). It was sampled across every second and manually reviewed at full resolution around each transition. Setup, battery-settings transition, endpoint data, and unrelated notification cards are absent; the notification portion is cropped to OmniTerm's card.

### Build verification

- Focused CodeEditor, ComposeBuilder, terminal buffer/emulator/navigation, and SSH host-key tests passed.
- `:app:assembleOpenSourceDebugAndroidTest` passed after adding all current device suites.
- The full `testOpenSourceDebugUnitTest` and `testPlayStoreDebugUnitTest` tasks passed. The real-tmux contract gate now waits for the isolated control client to appear in `list-clients` before sending client-scoped commands, eliminating a startup race that intermittently returned `no current client`; its focused regression passed in 29 seconds.
- `lintOpenSourceDebug` and `lintPlayStoreDebug` both passed, followed by successful open-source, Play Store, and instrumentation debug APK assemblies in one fixed-point run.
  - The first full lint exposed an API-24/25 crash risk in stale session-notification cleanup: `Notification.channelId` exists only on API 26+. Pre-channel devices now identify only OmniTerm session rows using a compat group plus exact legacy title/text signatures, preserving monitoring and battery-saver notifications.
- Dependabot is healthy on the default branch: Gradle and GitHub Actions weekly schedules are valid, security updates are enabled, no update PR limit is occupied, the July 13 grouped Gradle PR merged with all gates green, and its config validation passed. The next scheduled checks are July 20 at 04:00 and 04:30 Asia/Kolkata; no repository change is required.
- The on-device `com.jetsetslow.omniterm.data` package passed 3/3 tests in 4.308 seconds: the complete supported Room migration chain, targeted duplicate-incident migration, and repository cascade behavior.
- `E2eAppSurfaceStressTest` passed on the physical device in 62.100 seconds.
  - Every top-level route and nested tab composed without a crash.
  - All app and terminal themes, orientation changes, Settings dirty navigation, and cross-screen swipe carry-over completed.
  - Real process, service, log, cron, Docker, and SFTP loaders were observed from start through completion against the disposable lab.
  - Fleet broadcast completed and returned its expected marker.
  - Loader synchronization observes both loading-state edges, preventing a false pass or stale error before a launched coroutine starts.

## Remaining critical coverage

1. Inspect final PR checks and remove disposable lab artifacts only after their evidence is no longer needed.

## Resume commands

Build and focused local verification:

```bash
./gradlew :app:testOpenSourceDebugUnitTest
./gradlew :app:assembleOpenSourceDebug :app:assembleOpenSourceDebugAndroidTest
```

Install the current test build, replacing `<debug-apk>` and `<test-apk>` with paths reported by Gradle:

```bash
adb install -r <debug-apk>
adb install -r <test-apk>
```

Run the previously verified opt-in suites:

```bash
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eTerminalStressTest -e omniterm_e2e_terminal yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eTerminalLifecycleStressTest -e omniterm_e2e_terminal_lifecycle yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eTerminalNetworkRecoveryStressTest -e omniterm_e2e_terminal_network yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eComposeBuilderUiStressTest -e omniterm_e2e_compose_ui yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eComposeDeployStressTest -e omniterm_e2e_compose_deploy yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eNetworkToolsTest -e omniterm_e2e_network yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eAlertLifecycleStressTest -e omniterm_e2e_alerts yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eRemoteFilesStressTest -e omniterm_e2e_remote_files yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eFilesUiStressTest -e omniterm_e2e_files_ui yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eFileTransferLifecycleStressTest -e omniterm_e2e_transfer_lifecycle yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eSettingsStateStressTest -e omniterm_e2e_settings_state yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eForegroundServiceProofTest -e omniterm_e2e_foreground_proof yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eTerminalNavigationMatrixTest -e omniterm_e2e_terminal_nav_matrix yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
```

`E2eLabSeedTest` requires runtime arguments sourced locally from the ignored secret files. Inspect its `requireArg` calls for the argument names and pass them without shell tracing or copying the resulting command into this document.

## Checkpoint discipline

- Before a costly run, record which unverified item it closes and what pass/fail result ends the iteration.
- After a fix passes its narrow regression and relevant device path, update this document and create a signed incremental commit.
- Keep verified fixes in separate signed local commits, but batch pushes to avoid launching the full PR workflow set for every commit.
- PR workflows cancel superseded runs; never skip or weaken the final required checks.
- Do not describe the app as exhaustively tested until every item above is either verified or explicitly accepted as an outstanding limitation.
