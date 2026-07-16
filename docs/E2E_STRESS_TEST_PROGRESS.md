# End-to-end stress-test progress

Last updated: 2026-07-15

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

### Alerts, notifications, and refresh lifecycle

- `E2eAlertLifecycleStressTest` passed on the physical device in 45.594 seconds.
  - Created a host-scoped rule through the UI host picker, fired it from real disposable-lab telemetry, and verified its exact Android system notification.
  - Mute dismissed the notification; the muted incident and Unmute action survived Activity recreation; Unmute reposted the notification.
  - A real Wi-Fi disable/enable cycle preserved the incident, restored the host, and left the UI responsive.
  - Global disable/enable reconciled notification state without discarding the incident; acknowledgement dismissed it and recorded history.
  - Editing the rule closed the old incident as resolved, and a restarted five-second auto-refresh poller fired a new incident without a direct host refresh.
- Manual and periodic telemetry probes are serialized per host. Active incidents also have a database-unique `(ruleId, serverId)` identity using conflict-ignore semantics, so concurrent refreshes cannot reset acknowledgement/mute state or create duplicate cards.
- Schema 19 migrates legacy duplicate incidents by retaining the newest row before creating the unique index. Both the full schema 8→19 chain and the targeted duplicate migration passed on-device.

### Build verification

- Focused CodeEditor, ComposeBuilder, terminal buffer/emulator/navigation, and SSH host-key tests passed.
- `:app:assembleOpenSourceDebugAndroidTest` passed after adding all current device suites.
- `E2eAppSurfaceStressTest` passed on the physical device in 62.100 seconds.
  - Every top-level route and nested tab composed without a crash.
  - All app and terminal themes, orientation changes, Settings dirty navigation, and cross-screen swipe carry-over completed.
  - Real process, service, log, cron, Docker, and SFTP loaders were observed from start through completion against the disposable lab.
  - Fleet broadcast completed and returned its expected marker.
  - Loader synchronization observes both loading-state edges, preventing a false pass or stale error before a launched coroutine starts.

## Remaining critical coverage

1. Toggle Wi-Fi during terminal output, tmux restoration, proxy/jump-host connections, and file transfers; verify bounded retries and lossless UI recovery.
2. Stress the file-browser UI above the verified SFTP/SMB/FTP/HTTPS-WebDAV client matrix: dual-pane navigation, transfer cancellation, overwrite prompts, bookmarks, refresh, larger files, cross-protocol operations, and lifecycle recreation.
3. Cover all Settings combinations, backup/restore, app lock, battery-saver behavior, all themes, configuration changes, Fleet refresh/broadcast, and monitoring auto-refresh.
4. Trigger a deliberate app-side crash in a controlled test build. Verify startup crash capture, About/history display, redaction, and safe clearing.
5. Record a sanitized foreground-service-permission proof video. Use a clean test profile/host label, disable notification previews, clear Recents and notification history, crop status/navigation bars where possible, and review every frame before upload.
6. Run the full unit/instrumentation/migration/static verification set, inspect PR checks, and remove disposable lab artifacts only after their evidence is no longer needed.

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
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eComposeBuilderUiStressTest -e omniterm_e2e_compose_ui yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eComposeDeployStressTest -e omniterm_e2e_compose_deploy yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eNetworkToolsTest -e omniterm_e2e_network yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eAlertLifecycleStressTest -e omniterm_e2e_alerts yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.jetsetslow.omniterm.E2eRemoteFilesStressTest -e omniterm_e2e_remote_files yes com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner
```

`E2eLabSeedTest` requires runtime arguments sourced locally from the ignored secret files. Inspect its `requireArg` calls for the argument names and pass them without shell tracing or copying the resulting command into this document.

## Checkpoint discipline

- Before a costly run, record which unverified item it closes and what pass/fail result ends the iteration.
- After a fix passes its narrow regression and relevant device path, update this document and create a signed incremental commit.
- Keep verified fixes in separate signed local commits, but batch pushes to avoid launching the full PR workflow set for every commit.
- PR workflows cancel superseded runs; never skip or weaken the final required checks.
- Do not describe the app as exhaustively tested until every item above is either verified or explicitly accepted as an outstanding limitation.
