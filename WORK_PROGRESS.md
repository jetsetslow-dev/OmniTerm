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

## Checkpoint C3 — opt-in alert forwarding (dd92901)

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

## Checkpoint C4 — script checks and runbooks (b169d75)

- `HostChecks.SCRIPT_CHECK`: a rule whose `target` holds a saved script's id. `runHostChecks` now
  runs the probe for the probed checks and each Script Check's script on its own, at the same pace
  (at most once a minute per host). `data/ScriptChecks` reads the transport's result: exit 0
  passes, any other status is the reading, the first line printed is the reason (at most 160
  characters, never the transport's "Command exited with status" filler); a result that never ran
  (no connection, sign-in failed) leaves any incident as it is. 60 s without finishing counts as
  exit 124.
- Refused as a check, shown in the editor and as "Not checked: …" in the rule list: no script, a
  blank command, anything `commandDangerHits` flags, and a `{{value}}` with no default. A script
  limited to another OS or system reads as not checked on that host (`fleetHostsScriptSkips`).
  Placeholders take their defaults; the command runs exactly as Fleet runs that script
  (`savedScriptRun`, now shared with `broadcastHostPlain`).
- Runbooks: `AlertRuleEntity.runbookScriptId` (schema v25, `MIGRATION_24_25`). The alert
  notification gets a "Run <script>" action (`omniterm://notification/runbook/<rule>/<host>`), the
  Active tab's incident a Run link (`NotificationLinks` builds and reads the link, so the two
  cannot drift); both call `openRunbook`, which fills in Broadcast with that
  script and host only, and Fleet then shows the Run button's own confirmation. Nothing runs before
  it. The deep link goes through the external-launch queue, so App Lock still comes first. A host
  that is offline stays picked with the command filled in, without asking later. Deleting a script
  clears it from every rule (one transaction).
- Backups name a rule's check script (`targetScript`) and runbook (`runbookScript`) by category and
  name, the key restores already match scripts by; a Script Check no longer exports its raw id.
- UI: one `ScriptPickerDialog` (search, command preview, target tag) now serves Fleet's preset
  picker, the Script Check picker and the runbook picker (with None). Rule rows name the script and
  runbook.
- PRIVACY.md: a forwarded Script Check alert carries the script's name and first output line.
- Tests: `ScriptChecksTest` (exit status and first line, the filler and never-ran results, the
  refusals, the rule's script id, the texts). `HostCheckAlertsRobolectricTest`: a failing check
  opens an incident with "exit 2: …" that six metrics polls leave open, the script running once
  and the probe not at all, its placeholder filled with the default; a destructive script never
  reaches the host; a runbook fills in Broadcast for that host only and runs nothing, and
  deleting its script clears it. `ScriptRefsBackupRobolectricTest`: an encrypted backup restored
  where the scripts get other ids keeps both references. `AppDatabaseMigrationTest`: 24 → 25.
  Device `E2eScriptCheckTest` (`omniterm_e2e_script_check=yes`): the editor refuses a destructive
  script and saves a check plus runbook; the fixture's exit 3 opens an incident and a notification
  with "Run <runbook>"; that action's link opens the confirmation, and the runbook's output comes
  back only after Run. Passed on API 35. (The test delivers the link to its own activity: sent as
  is, the action starts a second activity, because ActivityScenario hosts this one in the test
  package's task; it also puts the launch intent back, since `onNewIntent` replaces it.)
  `NotificationLinksTest`: the link reads back as its rule and host, and other links do not.
- Guards seen failing: dropping the danger refusal fails the destructive-script test; exporting the
  raw script id fails the backup test; not clearing the runbook on delete fails the runbook test.
- `./scripts/local-pr-check.sh --full` passed: unit tests, five repeats of the 18 changed test
  classes, lint, strict dependency verification, no advisories or outstanding updates, secret scan,
  no new duplicates, the API 35 device matrix, and CodeQL 2.27.4 with no alerts (80,155 lines).

## Checkpoint C5 — Fleet run history (35ec118)

- Schema v26 (`MIGRATION_25_26`): `fleet_runs` (one row per run, unique on the run's own id) and
  `fleet_run_hosts` (one row per host in it). A run keeps its command as written, the saved script
  it came from when the command still matched it, its source (Run, Retry, or an alert's runbook),
  when it started and ended, and per host the name, status, note and the last 16,000 characters
  of output. The newest 50 runs are kept; older ones go with their hosts. Not in backups.
- Saved when nothing runs any more (`updateBroadcastExecuting` going from running to idle), so a
  tmux run that reconnects or a host that installs tmux and runs later updates its own run rather
  than adding one. Each card remembers the run it belongs to: a retry is a run of its own with
  only the hosts it ran, and the run it retried keeps their first results (`recordFleetRun`
  updates the hosts it is given and leaves the rest). Leaving the app ends a plain run, so a save
  then goes to the process scope.
- The values typed for `{{placeholders}}` are not stored; the details say so. PRIVACY.md lists the
  history, and that a host's output can still show those values.
- UI: Broadcast's output header has History. The list shows each run's script or first command
  line, when, "N of M succeeded" and Retry/Runbook; a run opens to the same host cards as the live
  output (`BroadcastResultCard`, now shared), with Share (one `fleetReport` builds both texts),
  Use again (command, matching saved script and the hosts that still exist; runs nothing),
  Delete, and Clear history behind confirmations. "Clear outputs" clears the cards, not the
  history.
- Tests: `FleetRunHistoryRobolectricTest`: a run is kept with each host's status, output and note,
  and survives clearing the cards; a retry is its own run and the first run still says the host
  failed; a host that finishes later (Run without tmux) updates the same run; long output keeps its
  end and the placeholder value never reaches the history; Use again restores the script and the
  hosts that still exist and runs nothing; the repository keeps the newest runs and deletes whole
  runs. `AppDatabaseMigrationTest`: 25 → 26. Device `E2eScriptCheckTest` now continues after the
  runbook runs: History lists it as "1 of 1 succeeded · Runbook", the run opens to the host's
  output, Use again fills in Broadcast without running, Delete removes it. Ten runs in a row
  passed on API 35.
- That device test also no longer hides its own failure: the launch intent is put back first and
  cleanup errors are attached to the test's error rather than replacing it; rules are read from
  the repository (the `alertRules` flow only follows the database while collected); the alert's
  notification is cancelled once checked, so its heads-up is not over the screen; and it waits for
  Use again to be enabled (it is disabled while the run's hosts load) rather than tapping a frame
  early, which failed about one run in seven.
- Guards seen failing: deleting a run's hosts when it is saved again, not pruning, not marking a
  later host's run, saving every card into every run, storing the filled-in command, a retry saved
  as a plain run, and Use again not restoring the script each fail a `FleetRunHistoryRobolectricTest`
  case; a runbook run saved as a plain run fails the device test (`expected:<runbook> but
  was:<fleet>`).
- `./scripts/local-pr-check.sh --full` passed: unit tests, five repeats of the 19 changed test
  classes, lint, strict dependency verification, no advisories or outstanding updates, secret scan,
  no new duplicates (its first run caught the Share code copied into the history; both now use
  one helper), the API 35 device matrix, and CodeQL 2.27.4 with no alerts (80,960 lines).

## Checkpoint D1 — Tasker and other apps run a saved script (this commit)

- Tools → Automation, off by default (`automation_enabled`). A token runs one saved script on the
  hosts picked for it: `omt_` plus 128 random bits, shown once, stored only as its SHA-256 in
  `automation_grants` (schema v27, `MIGRATION_26_27`), revoked from the list. Making one asks for
  App Lock, else the phone's screen lock, else a plain confirmation (`SensitiveActionDialog`, now
  shared with sudo; `AppLockAuthDialog` is the one App Lock dialog, also used by Settings' Save).
  The token is copied as sensitive text and cleared from the clipboard after a minute on the app's
  scope. The switch joins `DEVICE_LOCAL_SETTINGS` (one list, used by export and restore), so a
  backup never carries it either way; grants are never in a backup.
- Ways in, both exported, both deciding only by the token: the Locale/Tasker plug-in
  (`TaskerEditActivity` for EDIT_SETTING, `TaskerFireReceiver` for FIRE_SETTING) and the
  `com.jetsetslow.omniterm.action.RUN_SCRIPT` broadcast (`AutomationReceiver`) with an optional
  reply to one named package and action. The edit screen makes nothing: it checks a pasted token,
  shows the script, hosts and the calling app, and saves only for an app waiting for a result
  (with REQUESTED_TIMEOUT and the relevant variables when the host supports them). An unknown
  token gets no answer; a known one always goes to the job, which answers "automation is off" too.
  Tasker gets result code 3 (pending), then its completion intent (which must name an app; its
  selector is dropped) with `%output`, `%exit`, `%failed_hosts` and `%errmsg` on failure.
- The run is a JobScheduler job (expedited on Android 12+, where a broadcast may not start a
  foreground service; a plain job when Android refuses that). `AutomationRunner` probes each
  host's OS, skips hosts whose script names another OS, fills `{{value}}` defaults for the host's
  shell, runs built-in presets in the app's own form and anything else in the login shell, runs 8
  hosts at once, gives up after 9 minutes (exit 124; unreachable is 255), and records the run in
  Fleet's history as `automation`. Unknown host keys are refused (no one to approve them). Shared
  rather than copied: `HostCredentials` (credentials for screens and jobs), `UnattendedScripts`
  (Script Check's refusals, worded for each), `builtInPresetCommandFor`, `sshCommandExit` /
  `sshCommandOutput`, `FleetRunHistory.host`.
- Protocol facts are from Tasker's plug-in page and the Locale spec (Apache-2.0); Tasker's own
  TaskerPlugin.java states no licence, so nothing is copied. Departure: Locale says not to put
  credentials in the bundle; the token is the credential, scoped to one script and revocable, and
  the README says Tasker's exports contain it. The `<queries>` entry makes Tasker visible so its
  completion intent is delivered.
- Credit (README): Termux:Tasker and Home Assistant for Android; Tasker's docs and the Locale spec.
- Tests: `AutomationRobolectricTest` (11: token shape and hash, ids, OS skip, result, variables,
  bundle, completion intent, reply, job extras), `AutomationRunnerRobolectricTest` (10: runs and
  records, switch off, revoked or wrong token, refusals, defaults per shell and login shell, preset
  form, OS skip, unreachable, timeout, gate), `AutomationBackupRobolectricTest` (2),
  `ToolsPathTextRobolectricTest` (now 8 strings), `AppDatabaseMigrationTest` 26 → 27. Device:
  `AutomationBroadcastTest` and `TaskerEditActivityTest` (no host needed, run in the gate's
  matrix) and `E2eAutomationTest` (`-e omniterm_e2e_automation yes`, lab host).
- Guards seen failing on unfixed code. Unit (15): the switch ignored; the token hash not compared;
  the unattended rules skipped; a user script sent to `sh`; a preset not run in its own form; no
  OS skip; no time limit; the run not recorded; a completion intent naming no app accepted; its
  selector kept; a reply to any app; `%errmsg` set on success; any token shape accepted; a skipped
  host failing the run; the switch carried in a backup. Device: answering OK instead of "pending"
  fails `aKnownTokenIsToldAutomationIsOff`.
- API 35: `AutomationBroadcastTest` (3) and `TaskerEditActivityTest` (2) passed, and
  `E2eAutomationTest` against the repository fixture passed; then all six passed five times in a
  row.
- Package visibility, checked on API 35: a broadcast from the app reached a manifest receiver of a
  package `dumpsys package queries` says it cannot see, both by package and by component. So the
  `<queries>` entry is not what delivers Tasker's result there; it stays, for builds that filter.
  The manifest comment claims more than that and is reworded in the next commit.
- `./scripts/local-pr-check.sh --full` passed on the final tree: both unit variants, five repeats of
  the changed test classes, lint, dependency and SBOM verification, the API 35 device suite (85
  tests, the automation classes among them), and CodeQL 2.27.4 with no alerts (82,851 lines).

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

1. Automation, the rest: `ssh://` links, share target, one-tap public-key install (D1, the Tasker
   plug-in and broadcast, is done).
2. MCP: opt-in, loopback only, reached through an SSH reverse tunnel, read-only by default,
   on-phone approval for writes, audit log, `PRIVACY.md` section.
3. Per-host tunnels: WireGuard, Tailscale/Headscale, NetBird, Nebula and Cloudflare Access from one
   Go library, built with a repo-local, checksum-verified Go toolchain (approved Nov 8). ZeroTier,
   OpenVPN and Pangolin's Olm are left out for their licences; Pangolin raw TCP resources work as a
   plain host and port.
4. Homelab additions (user, Nov 8): Proxmox VE API, SNMP, container image updates, backup freshness
   presets.
5. On `kotlin-multiplatform` (draft PR #144): its first step, the shared module with the pure
   logic and its tests in `commonMain`, the iOS app shell and iOS CI on macOS runners, is up and
   green. Next there: merge main as these features land, more logic into `commonMain`, the Go
   engine behind `SshTransport` on Android and iOS, then the iOS pieces (Keychain, notifications,
   background limits).

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
