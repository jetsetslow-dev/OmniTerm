# Kotlin automation round — 2026-11-08

Scope (user request, Nov 7–8): review comparable open-source apps for missed bugs and features,
give OmniTerm a capability no other app has for homelab and server admins, re-check Quick Scripts
and Fleet after the cross-OS/container/Kubernetes work, add automation hooks (Tasker and similar
apps, an opt-in private MCP server), optional per-host WireGuard/Tailscale tunnels, credit every
project we learn from. (The Flutter sync first asked for was dropped on Nov 8; see the pivot below.)
Branch `kotlin-automation` from main
after #136 and #137. Independent review and merge remain the user's.

The private audit (sources per finding, designs, order) is in the internal docs as
`COMPETITOR_AUDIT_2026-11-08.md`.

## Checkpoint A — scripts and Fleet defects (82702ea)

- Script values: `{{name}}` and `{{name=default}}` in a saved script ask for a value when it runs
  from Monitor → Scripts or Fleet. Values are quoted for each host's shell (POSIX single quotes;
  Windows double quotes, refusing `" % ! $ \`` and line breaks), so a value is always one word.
  Shared code: `data/ScriptParams.kt`, `ui/ScriptParamsDialog.kt`. Credit: Semaphore UI.
- Proxmox presets: "start VM" and "shut down VM" ask for the VM id (they ran `qm start 100` /
  `qm stop 100`); shutdown is `qm shutdown`. Untouched stored copies of retired presets are moved to
  the current ones at startup (`retiredPresetScripts`); edited copies are left alone.
- Fleet honours a picked preset's target OS/system: hosts known not to match are skipped and named
  in the confirmation; none matching shows "No host matches". Unprobed hosts are tried. The target
  fields in the script editor now apply to Fleet too.
- Fleet's command field is multi-line. As a single-line field, Enter could not add a line break and a
  pasted script showed as one long line (it still ran as written). Credit: ssh-mcp.
- Broken fallbacks: "Syslog errors" never reached `/var/log` when `logread` was missing (pipeline
  status is the last command's); "Updates available" never reached dnf and reported dnf's exit 100
  as failure. Both now test for each tool; updates cover apt, dnf, yum, zypper, pacman, apk, pkg.
- Danger warning: adds ZFS/LVM/mdadm, container prunes and `compose down -v`, `kubectl
  delete|drain`, `helm uninstall`, `qm|pct destroy|stop`, `find -delete`, `crontab -r`, SSH
  lock-outs (stop/disable sshd, `ufw enable`, INPUT DROP), and Windows deletes/formats/restarts.
  `qm shutdown` no longer reads as a host shutdown.
- Windows output is UTF-8 (`RemoteCommands.POWERSHELL_PRELUDE`). Credit: Termix, ssh-mcp-server.
- SSH banners: kept by `KeyboardInteractiveUserInfo.showMessage` and printed at the top of a new
  terminal session after removing control characters (`bannerForTerminal`).
- Monitor → Scripts "Save" now keeps the notes field (it was dropped).
- README: Terminal, Fleet, Scripts and Acknowledgements; NOTICE: acknowledgements.
- Dependency updates the gate required (taken here rather than as Dependabot PRs): AGP 9.5.1,
  Gradle wrapper 9.9.0 (distribution and wrapper-jar SHA-256 match services.gradle.org), biometric
  1.4.0-beta01, mockk 1.14.12, Roborazzi 1.78.0, UI Automator 2.4.1, actions/setup-java 6.2.0,
  github/codeql-action 4.39.3 (bundles CLI 2.27.4, so the local CodeQL pin is unchanged).
  Checksums via `scripts/refresh-verification-metadata.sh --write`; the Actions allowlist check
  passes.

## Checkpoint B — rolling Fleet runs, retry, share, targets (this commit)

- Rolling runs: Fleet → Broadcast → Rolling run takes 1, 2, 5 or 10 hosts at a time (persisted as
  `broadcast_batch_size`, 0 = all at once) in the confirmed order, with "Stop if a host fails"
  (`broadcast_stop_on_failure`, default on). New card states: waiting, not run (with the reason).
  Stop or a timeout leaves the waiting hosts not run; the 10-minute limit applies per batch.
  `broadcastBatches()` in `AppViewModel.kt`. Credit: Komodo batch deploys (moghtech/komodo#1080).
- Retry: "Retry N" after a run re-runs the last command and values on the failed and not-run hosts
  only, behind the same confirmation (with the danger warning); other cards keep their results.
- Share output: the whole run as text through the share sheet. `data/TextShare.kt` is shared with
  the crash report, whose after-crash screen now uses the same redacted payload
  (`CrashLog.sharePayload`) as Tools: always an attached file, plus the message body up to 100,000 characters, because
  a larger body overflows the Binder transaction and crashes the share. New FileProvider path
  `shared-text/`.
- Status words, placeholders and the truncation line moved to string resources
  (`BroadcastStatus.label`).
- Script targets: the Linux probe reports podman, kubernetes (kubectl, k3s or microk8s), synology,
  truenas, unraid and openwrt; the BSD probe reports truenas, pfsense and opnsense. The script
  editor offers all of them.
- README: Fleet rolling runs, Retry, Share output, target list; Komodo in Acknowledgements and
  NOTICE.
- Validation: JVM and Robolectric tests, the API 35 device test `E2eRollingFleetTest` (fails
  without batching), and `./scripts/local-pr-check.sh --full` passed: unit and Robolectric tests, lint, dependency and SBOM verification, the API 35 device suite (including the rolling-run test), and CodeQL with no alerts.

## Checkpoint C1 — host checks (d8dc948)

- Seven rule types about a host's state (`data/HostChecks.kt`, pure Kotlin): Host Offline, Failed
  Services, Container Problems, Storage Health (ZFS pools, mdadm, SMART), ZFS Scrub Age, UPS On
  Battery, Reboot Required. Readings are plain numbers, so incidents and history are unchanged; no
  database change.
- One probe (`HostChecks.PROBE`, POSIX sh with the `ot` time limits) per host with such rules, at
  most once a minute, in its own job. A section prints `!OK` only when its tool ran, so a host
  without systemd, ZFS or NUT reads "Not available on this host" rather than "none". Windows hosts
  skip it. Reboot Required covers the Debian flag and a newer installed kernel of the running
  flavour (plain Debian and Proxmox never write the flag), needs-restarting, Arch and FreeBSD.
- Containers stopped by hand (exit 0, 130, 137, 143) do not count; `SimContainer.exitCode` is new.
- Host Offline comes from each finished probe's verdict. It and the phone-side TLS/URL checks
  record nothing while the phone has no active network (`ACCESS_NETWORK_STATE`, now declared and
  in `PRIVACY.md`).
- Metrics polls skip host-check rules; before, a rule kind they did not know read as "recovered".
- Editor: the new chips, a hint per check, no threshold for yes-or-no checks, no window for an old
  scrub or a pending reboot; the dialog now scrolls. The rule list shows each host's last reading
  (`RuleCheckLines`, shared with the TLS/URL checks). Notifications name up to five items.
- Tests: `HostChecksTest` (parsing, values, texts, and the probe in a real sh against stub tools
  with every system path moved to a scratch folder), `HostCheckAlertsRobolectricTest` (offline
  incident; none while the phone is offline; a failed-service incident that metrics polls leave
  open, both guards seen failing without the fix), device `E2eHostChecksTest`.
- README: Host checks; Beszel and Uptime Kuma credited for the alert kinds.

## Checkpoint C2 — phone-side ping, TCP and DNS checks (c24f0e9)

- Three more `EndpointChecks` kinds, each timing a reply in ms (below zero on failure), giving up
  after 3 s (`QUICK_TIMEOUT_MS`), checked every poll but at most once a minute, like URL checks:
  - Ping: one `-c 1 -W 3` through `/system/bin/ping` (`ANDROID_PING_BINARY`, now in the data
    package). Blank target = the host's own address. A watchdog thread ends a ping that hangs past
    the limit: the timed `Process.waitFor` needs API 26 and the app supports 24 (lint caught it).
  - TCP Port: a bare port connects to each host's own address, so it suits "All hosts";
    `host:port` is one endpoint and needs one host.
  - DNS: an A, then AAAA, query over UDP. A bare name asks each host as its DNS server (Pi-hole,
    AdGuard Home); `name@server[:port]` asks another one. Values: NXDOMAIN and other rcodes are
    -(100 + rcode), no address is -100. Replies are matched on server address, port and a random
    query id.
- One target rule for every `ping`: `EndpointChecks.pingHost` refuses a leading `-` (an option) and
  strips IPv6 brackets. Tools → Ping and Traceroute used to accept `-f` and similar; they now use it.
- One copy of each network piece: `EndpointChecks.connect` also serves the SSH reachability probe,
  the share probe and Host Scan's port probe. `serializeDnsQuery` moved to `data/DnsWire.kt` and
  takes the query id, so Tools → DNS Lookup now sends a random id, not a fixed 0x1234.
  `hostAndPort` is shared by the TLS, TCP and DNS targets.
- Editor: the chips, defaults (Ping 200 ms, TCP 1000 ms, DNS 500 ms), labels, examples and hints;
  thresholds must be under the check's time limit.
- Tests: `PhoneChecksTest` (targets; TCP against local sockets; DNS against a stand-in server,
  including NXDOMAIN, no address, no answer and a forged reply under another id; ping through stand-in
  binaries, including the exact arguments). A second `EndpointAlertRobolectricTest`: one All-hosts
  TCP rule given a bare port is quiet on the host that listens and opens an incident on the one that
  does not. More `InputValidationTest` cases. Removing the leading-`-` guard or the query-id match
  fails them. Device `E2ePhoneChecksTest` (`omniterm_e2e_phone_checks=yes`) passed on API 35.
- README: the three checks; Uptime Kuma credited for them.

## Checkpoint C3 — opt-in alert forwarding (this commit)

- `data/AlertForwarding`: Off (the default), an ntfy topic (ntfy.sh or the user's server, optional
  access token), a Gotify server (application token) or any webhook (optional bearer token).
  `request()` builds the JSON POST and does no I/O: ntfy's JSON publish to the server root (titles
  stay out of HTTP headers), Gotify's `/message` with `X-Gotify-Key`, and a webhook object with
  source, event (triggered or resolved), severity, host, rule, title, message, value, threshold and
  UTC time. Priorities follow severity; a resolved message is low priority.
- `send()` never follows a redirect (that would take the token to an address the user did not enter;
  the outcome names where it pointed). No answer or a 5xx is tried twice more, after 5 s and 30 s; a
  4xx or redirect is not.
- What goes out is the notification's own title and text (`alertNotificationTitle`/`Text`, now
  shared by both), and nothing else. Hooks: an incident opening (the same place the notification is
  posted) and an incident resolving. A muted incident's recovery is not forwarded; the alerts switch
  being off stops both, as it stops evaluation. Re-posts (unmute, alerts turned back on) are not
  forwarded again.
- Settings: `alert_forward_*`; the token is in `secureSettingKeys`, so it is stored with the
  Keystore key like the app PIN. Backups carry it inside their passphrase-encrypted settings, so a
  restored phone keeps forwarding.
- UI: the Alerts screen's monitoring card has an **Alert forwarding** line (where alerts go, when the
  last one went out or why not) and a dialog with the service chips, fields, the public-topic and
  clear-text warnings, an optional resolved message, and **Send test** for the unsaved settings.
- PRIVACY.md: an Alert Forwarding (Opt-In) section and the sharing exception. The network security
  config comment now lists it (and URL checks) among the user-typed cleartext addresses.
- Tests: `AlertForwardingTest` (validation; each service's request, byte for byte; JSON quoting of
  quotes, controls and U+2028; delivery against a local server: 2xx ok, 401 not retried, 503
  retried, a 302 not followed and the token never reaching the other address, a closed port
  retried). `AlertForwardingRobolectricTest` (a webhook hears a Host Offline incident open and
  recover, exactly once each; a muted incident recovers quietly; Off with an address filled in sends
  nothing). Device `E2eAlertForwardingTest` (`omniterm_e2e_alert_forwarding=yes`): the dialog sets
  up a webhook with a token, warns about clear text, Send test delivers with the token, the saved
  token is stored encrypted, and a closed-port incident on the provisioned host is forwarded with
  the notification's words; passed on API 35.
- Guards seen failing: forwarding a muted recovery fails the Robolectric mute test; following
  redirects (with the fixed-length body removed, which on its own already stops the JDK resending a
  POST) fails the redirect test; storing the token in clear fails the device test.
- `./scripts/local-pr-check.sh --full` passed: unit tests, five repeats of the 15 changed test
  classes, lint, strict dependency verification, no advisories or outstanding updates, secret scan,
  no new duplicates, the API 35 device matrix, and CodeQL 2.27.4 with no alerts (79,332 lines).
- README: the feature, the privacy line, and Uptime Kuma and Beszel credited for the idea.

## Decision pivot — 2026-11-08

The Flutter migration (PR #92, `migration-to-flutter`) is cancelled. Flutter never shipped; the
Kotlin app is the only one that went live. OmniTerm stays one Kotlin codebase and gains iOS through
Compose Multiplatform, so nothing from this round is ported to Flutter. #92 is closed once Kotlin
Multiplatform works for iOS: the shared module builds for Android and iOS, the iOS app builds and
passes its tests on macOS CI, and a host connects with a working terminal on a simulator.

Later on Nov 8 the user settled the rest:

- Android and iOS must be in sync in features and behaviour. Shared Kotlin, plus one shared Go
  network core, makes that the default; only small platform adapters differ.
- Go core for both platforms: the Java-only engines move to one Go library built for Android (AAR)
  and iOS (xcframework), the same library that carries the tunnels:
  - SSH and SFTP: JSch → x/crypto/ssh and pkg/sftp.
  - SMB: smbj → a go-smb2 fork.
  - FTP/FTPS: commons-net → jlaffaye/ftp.
  Licences are to be checked before use. It goes in behind the existing `SshTransport` interface
  as a second implementation, runs the same device suites as JSch, and becomes the default only
  when it passes them; JSch is then removed.
- Flutter archived: PR #92 closed, branch tip 336b8b6 kept as the signed tag
  `archive/flutter-migration`, remote branch deleted. Its 28 unpublished WIP commits stay local as
  `archive/flutter-merge-main-wip`.
- Branches, split like the old Kotlin/Flutter pair: `kotlin-automation` (features, PR #138) first;
  `kotlin-multiplatform` (from main 06474d5) for the shared module, the Go engine move and iOS,
  merging main as features land.
- Order: the researched new features first, then iOS completion.

## Remaining, in order

1. Alerts (checkpoint C), C1 to C3 done above:
   - C4: script checks, runbooks offered from the notification, run history.
2. Automation: token-guarded Tasker/Locale plugin and broadcast to run a saved script or runbook,
   `ssh://` links, share target, one-tap public-key install.
3. MCP: opt-in, loopback only, reached through an SSH reverse tunnel, read-only by default,
   on-phone approval for writes, audit log, `PRIVACY.md` section.
4. Per-host tunnels: WireGuard, Tailscale/Headscale, NetBird, Nebula and Cloudflare Access from one
   Go library, built with a repo-local, checksum-verified Go toolchain (approved Nov 8). ZeroTier,
   OpenVPN and Pangolin's Olm are left out for their licences; Pangolin raw TCP resources work as a
   plain host and port.
5. Homelab additions (user, Nov 8): Proxmox VE API, SNMP, container image updates, backup freshness
   presets.
6. On `kotlin-multiplatform`: a shared module from the Aug 1 groundwork, pure logic first, then
   UI; the Go engine behind `SshTransport` on Android and iOS; then the iOS pieces (Keychain,
   notifications, background limits), with iOS CI on macOS runners.

## Validation

Commands (run from the repository root):

- `./scripts/local-pr-check.sh --full` before every push, plus `git diff --check` and
  `git diff --cached --check`.
- New unit tests: `ScriptParamsTest`, `ScriptTargetsTest`, `SshBannerTest`; extended
  `CommandDangerHitsTest`; `CrossShellCommandsTest` and `HostOsCommandsTest` follow the prelude.
- Device (API 35, repository Docker fixture via `./scripts/test-hosts.sh up`): provision with
  `E2eLabHostProvisioner` (`omniterm_e2e_provision_host=yes`, `omniterm_e2e_trust_host=yes`), then
  `E2eScriptParamsFleetTest` with `-e omniterm_e2e_script_params yes`.

Results so far:
- The eight affected unit classes pass locally (68 tests, 0 failures).
- API 35 against the repository fixture: `E2eLabHostProvisioner` 2 passed, `E2eScriptParamsFleetTest`
  1 passed (multi-line command typed with Enter, `{{msg}}` value `it's; echo INJECTED` arrives as
  one word, a Windows-only preset leaves the Linux host out). With the old single-line field it
  fails at the typed line break, as expected.
- `./scripts/local-pr-check.sh --full` passed on the final tree: both unit variants, five extra
  runs of the six changed test classes, both lint gates, strict dependency verification, no
  advisories, no outstanding updates (66 Gradle, 36 Actions), secret scan, no new duplicate code,
  the API 35 device matrix, and local CodeQL 2.27.4 with zero alerts (76,475 lines). The CodeQL
  step's clean build removed the per-test result files, so this record has no per-test counts.
- CI for checkpoint A: see PR #138.

Checkpoint B results:
- Unit: `FleetRollingRunRobolectricTest` (4: batches, stop on failure then retry, no-stop order,
  stop leaves waiting hosts not run), `ScriptTargetsTest` (+3: every target system is reported by a
  probe, parsed platforms match targets, the Linux platform block in a real `sh` with stand-in
  tools), and the existing Fleet broadcast tests pass. With batching removed all four rolling tests
  fail.
- API 35 against the repository fixture (the provisioned host plus a copy of it):
  `E2eRollingFleetTest` with `-e omniterm_e2e_rolling_fleet yes` passed — one at a time, the first
  host exits 3 and the second is not run, Retry runs both and they succeed, Share starts the share
  sheet with the run as message text and as an attached file readable through the provider. With
  batching removed it fails.

## Known exclusions

- Tunnels need a userspace WireGuard/TCP stack; every maintained one is Go (wireguard-go, tsnet).
- ChatGPT's local MCP support could not be verified (its docs returned 404); not claimed.
