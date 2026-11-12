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

Continuation (user, Nov 11): Claude Code sessions no longer run the 30-minute `continue` loop,
because Claude Code resumes by itself when a usage limit resets. This is for Claude Code only.
Codex has no such resume and keeps its schedule, as `AGENTS.md` requires.

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

## Checkpoint B — rolling Fleet runs, retry, share, targets (783db95)

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

## Checkpoint D1 — Tasker and other apps run a saved script (d1c5483)

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
- Dependabot #139 (AGP 9.5.1, UI Automator 2.4.1), #140 (biometric 1.4.0-beta01) and #143
  (setup-java 6.2.0, codeql-action 4.39.3), and the bot's metadata PRs #141 and #142, were opened
  against main for updates checkpoint A already made here, at the same pins. Checked line by line,
  then closed on Nov 9 at the user's request, each pointing to #138.

## Checkpoint D2 — `ssh://` links and sharing to OmniTerm (1d64aa1)

- `incoming/IncomingActivity` (exported, no UI, `noHistory`, empty task affinity) takes `ssh://`
  VIEW links and SEND / SEND_MULTIPLE shares and passes what it can use to `MainActivity` with
  NEW_TASK | SINGLE_TOP, so a share opens the app the user already has instead of a second copy in
  the sender's task. `MainActivity` is exported too, so it reads the intent again with the same
  `Incoming.read` rules, and `Incoming.consume` clears it so a rotation does not hand it over twice.
- Shared files keep their read grant: the forward carries them in ClipData with
  FLAG_GRANT_READ_URI_PERMISSION, so `MainActivity` holds its own grant after the forwarding
  activity (and the grant Android gave it) is gone. Only `content:` URIs from other apps are read:
  never `file:` paths or OmniTerm's own providers (read from its package info; all refused if that
  fails). Refused files are counted and the user told.
- `data/SshLink`: `ssh://[user[;params][:password]@]host[:port][/…]`. The password and parameters
  (a fingerprint too) are dropped; the path, query and fragment are ignored, not read as the
  address (electerm#4357). The host and port use `EndpointChecks.hostAndPort` and `pingHost` (now
  shared). `uri` writes a link back with the user escaped, for the forward. A link opens
  `SshLinkDialog`: the saved hosts with that address, port and user (`HostCredentials.loginName`,
  so a profile's user counts) to connect to, or Add as new host with the address, port and user in
  `NewServerPrefill`. Nothing connects or saves without a tap.
- Shared text opens Scripts' new-script editor with it as the command (65,536 characters at most;
  longer is refused); text that is an `ssh://` link opens as one. Shared files wait in `sharedUploads`:
  `SharedFilesBar` in Files → SFTP offers Upload here into the folder the user opened, through the
  same overwrite question as the picker. Elsewhere in Files the bar says where to go.
- One copy each: `confirmUploadOverwrites` (the picker's overwrite question, which the SFTP and
  Shares tabs had each copied, and now the share bar too), `UploadName` (a device file's name on
  the host: last part only, `\` too, never `.` or `..`, no control characters; the picker had kept
  everything after the last `/`), `DeviceShell` in the device tests (eleven private copies of the
  shell helper moved onto it), `keepLaunchIntent` in the device tests (onNewIntent replaces
  MainActivity's intent and ActivityScenario then cannot close it; `E2eScriptCheckTest`'s own copy
  moved onto it).
- Credit (README): electerm (#4357) and Material Files (#976).
- Tests: `SshLinkTest` (8), `UploadNameTest` (3), `IncomingRobolectricTest` (6). Device:
  `IncomingTest` (no host needed, runs in the gate's matrix) and `E2eIncomingTest`
  (`-e omniterm_e2e_incoming yes`, lab host).
- Results, API 35 emulator, repository fixture only (lab host provisioned by
  `E2eLabHostProvisioner` on 127.0.0.1:2205):
  - `IncomingTest`: 4 tests, 0 failed. `E2eIncomingTest` (`-e omniterm_e2e_incoming yes -e host
    127.0.0.1 -e port 2205`): 1 test, 0 failed, status 0 (ran, not skipped): the link connected;
    the contact card OmniTerm could not read alone uploaded to `/tmp` after the forwarding screen
    had gone; shared again, it waited for the overwrite answer, replaced the first copy and left no
    staged or previous copy. `E2eScriptCheckTest` (`-e omniterm_e2e_script_check yes`) on the
    shared `keepLaunchIntent`: 1 test, 0 failed.
  - Seen failing on the device: dropping FLAG_GRANT_READ_URI_PERMISSION from the forward (the upload
    never succeeds), and sending files past the overwrite question (no question appears).
  - Unit-level mutations: 12 of 13 caught (path read as address, password kept, user not escaped,
    backslash kept, `..` allowed, `file://localhost` path accepted, own provider accepted, grant not
    passed on, sender's task, not consumed, long text allowed, refused not counted). One is
    equivalent: a signed `%` escape always decodes to a control character or invalid UTF-8, which
    are refused anyway; the hex-digit check stays.
  - Checked by hand (the accessibility tree, as screenshot protection blanks screen captures): the
    link dialog shows `admin@nas.example.lan:2222` and no password; Add as new host fills the name,
    address, port 2222 and user `admin`, with the password empty; a shared file shows "1 shared
    file to upload into this folder." with Upload here and Cancel on Files → SFTP, and Cancel clears
    it. No crash in logcat.
  - Two test mistakes found and fixed on the way: the user field is on Add host's Credentials tab,
    and the transfer list is newest first.
- `./scripts/local-pr-check.sh --full` passed on this tree: both unit variants, five repeats of the
  changed test classes, both lint gates, strict dependency verification, no advisories, no
  outstanding updates, secret scan, no new duplicate code, the API 35 device suite (90 tests, 0
  failed) and CodeQL with no alerts (83,578 lines). Afterwards `NOTICE.md` gained the three
  missing credits (Termux:Tasker from D1, electerm and Material Files); for that text-only change
  `git diff --check` and both secret scans were run again and passed.

## Checkpoint D3 — install a key on hosts (a3cf999)

- What it does: puts a key's public half on one host or many, as `ssh-copy-id` does
  (ConnectBot#428, #666). It is reached from a key's card, from a newly generated key, or from a
  host's ⋮ menu.
  - The line goes on stdin and is added once to `~/.ssh/authorized_keys`. A new `.ssh` or file
    is made private (umask 077), a missing final line break is fixed first, and existing files
    keep their permissions.
  - Then a key-only sign-in checks it. `SshCredentials.keyOnly` makes JSch offer only
    `publickey`, so the password cannot hide a refused key. This field is in the Go engine's
    contract.
  - With the switch on, each host where it worked moves to the key. Profile hosts are kept.
    Security keys are added but not tried. Windows is refused for now (its administrators'
    keys live in another file).
  - It goes through `SensitiveActionDialog`.
- Tests:
  - `KeyInstallTest`, 12 tests:
    - the line;
    - the answer;
    - `preferredAuthentications`;
    - the command in sh, dash, bash and busybox, and behind each login shell present;
    - add once and private;
    - found with options;
    - line break;
    - empty input;
    - read-only folder.
  - `KeyInstallRobolectricTest`, 2 tests, eight hosts: works and switches, present but refused,
    Windows, profile, read-only, unreachable, already using the key, and the switch off; plus a
    security key and a key with no public half. It uses the new `TestAndroidKeyStore` rule, an
    in-memory AndroidKeyStore, so passwords are really saved.
  - `SshSignInLiveTest.aKeyOnlySignInOffersTheKeyAndNothingElse`: against `direct` the password
    works but key-only is refused; `keyauth` accepts key-only. All 7 live tests pass.
  - Device `E2eKeyInstallTest` (`-e omniterm_e2e_key_install yes`, lab host) passed: it makes an
    RSA key in the app, installs it from the key card, signs in, switches, reinstalls from the
    host ("already there"), and restores the host. Afterwards the host has no `.ssh` folder
    again. One finding, a test fix and not an app bug: the fixture's home folder is setgid, so a
    new `.ssh` is 2700, which sshd accepts.
  - Mutations: 16 of 16 caught (`scratchpad/d3mut`), covering the command, the line, the answer,
    `keyOnly` (unit and live), and the key-only credentials, switch, profile, security-key,
    Windows and toggle paths.
- Write once: 13 shell tests moved onto `TestShell` (one runner; its timeout now holds while
  output is read). All 110 of their tests pass with none skipped.
- Flake found by the gate's device suite: `IncomingTest` failed once with "No compose hierarchies
  found". The logs show the main screen only paused while the forwarding screen handed the link
  over, which is the design, and `waitUntil` does not retry after an exception. Now
  `ComposeNodes.showsNode` reads "no screen yet" as not yet, inside waits only; checks that
  something is absent stay strict. IncomingTest then passed 10 runs in a row (40 of 40), and both
  end-to-end tests passed. The new "no keys" text also named "Tools → Keys", which the Tools-path
  guard caught; it now says "Tools → Auth & keys".
- Gate: `./scripts/local-pr-check.sh --full` passed on the pushed tree: five repeats of the changed test classes, the API 35 device suite (91 tests, 0 failed), and CodeQL with no alerts (84,420 lines).
- CI: D2's PR Check failed. Room migrations and SBOM both hit a 10 s Gradle wrapper download
  timeout; Build & Test passed. The failed jobs were rerun once, and the wrapper now waits 60 s
  with 3 retries. `secrets/internal-docs/tools/ci-watch.sh` watches runs and reruns network
  flakes once.

## Checkpoint E — opt-in MCP server for AI assistants (#145, merged Nov 9 as 179c0b6)

Its own PR, after #138.

- Protocol: `data/mcp/McpProtocol.kt`, pure Kotlin on kotlinx-serialization-json's tree API (the
  jar was already verified at 1.12.0), so it can move to the shared module as is.
  - Spec 2026-07-28, read from modelcontextprotocol.io on Nov 9:
    - stateless, with no handshake;
    - `params._meta` carries the version and the client's capabilities;
    - `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` must match the body (-32020);
    - an unsupported version gets -32022 with the supported list;
    - `server/discover`; `resultType`, `ttlMs` and `cacheScope` on results;
    - a notification gets 202; batches are refused.
  - 2025-11-25, 06-18 and 03-26 clients: `initialize`, then plain requests, with no session id.
- HTTP: `McpHttpServer`, one POST per connection on 127.0.0.1 only. Checked in this order:
  - Host must be a loopback name, against DNS rebinding;
  - Origin, if sent, must be loopback;
  - the path, then POST only (GET answers 405, electerm#4431);
  - the bearer token, compared against its SHA-256;
  - JSON only, at most 256 KiB, chunked bodies accepted.
  It drains unread input before closing, so a refusal is not reset.
- Tools (`McpTools`, fixed names and descriptions, ssh-mcp#214; hints, ssh-mcp#36):
  - `list_hosts`, `host_status` (OmniTerm's own last metrics and alerts), `list_containers` (live,
    read-only) and `list_scripts` (names and `{{values}}`, never commands);
  - `run_script`, and `run_command` only while "Allow any command" is on. Each run is approved on
    the phone (`McpApprovals`: notification → dialog → `SensitiveActionDialog`; deny needs no
    lock; no answer in 2 min is a no).
  - Never shared: an address, a user name, passwords, keys or notes.
  - Runs go through `AutomationRunner.runScript` (extracted so Tasker and MCP share one runner) into
    Fleet history as "AI assistant". A typed command runs exactly as typed (no `{{}}` filling).
- App: `McpService` (foreground, connectedDevice) listens while the switch is on and keeps a
  reverse tunnel (`SshTunnelManager` remote, id -47821) to the picked host, bound to that host's
  loopback. Tools → AI assistants has:
  - the switch (lock plus a token shown once) and the privacy warning;
  - make, replace and revoke the token;
  - which hosts are shared (none by default);
  - "Allow any command";
  - the host and ports to reach it through;
  - setup lines for Claude Code, Gemini CLI and Codex;
  - recent calls, which come from the new `mcp_calls` table (DB 28, `MIGRATION_27_28`, newest 200
    kept, not in backups).
  All MCP settings are device-local (`DEVICE_LOCAL_SETTINGS`).
- Found on device: Android's `InetAddress.getLoopbackAddress()` is `::1`, so the server first
  listened where neither the tunnel nor clients (both name 127.0.0.1) could reach it. On the JVM it
  is 127.0.0.1, so the unit test passed. It now binds 127.0.0.1 by number, and the unit test
  asserts that address.
- Tests:
  - `McpProtocolTest` (12), `McpHttpServerTest` (10, real loopback socket), `McpToolsTest` (10, a
    fake app that checks no secret ever leaves) and `AppMcpBackendRobolectricTest` (3): 35, all
    passing.
  - The migration test covers 27→28.
  - Device `E2eMcpTest` (`-e omniterm_e2e_mcp yes`, lab host) passed. The switch, lock and token
    were done on the screen. Through a real reverse tunnel, curl on the host:
    - discovered the server and initialized as a 2025 client;
    - listed hosts, by name only;
    - got 401 with a wrong token and 403 with a web origin;
    - asked to run a command: denied on the phone, its marker file was not made; approved, it was.
    The calls were recorded, and turning the server off closed the host's port.
  - Mutations: 24 of 24 caught (`scratchpad/mcpmut`). They cover the Host, Origin, token,
    revoked-token, size, method, bind-address (all and `::1`) and repeated-header checks;
    `Mcp-Name`, the version, capabilities, leaked exception text and notifications; approval,
    `run_command`'s gate (listed and stale), typed-command filling, address and command leaks,
    unknown values and the host cap; the shared-host filter; and the SSH-error leak.
- Docs: README section, privacy bullet, backup note, feature bullet and credits (Haven, electerm,
  ssh-mcp, the MCP spec); `PRIVACY.md` "AI Assistants Over MCP (Opt-In)" and the data list;
  NOTICE.
- Gate: `local-pr-check.sh --full` passed (exit 0): 93 device tests, 0 failed; CodeQL no alerts (87,053 lines)
- Go engine contract: remote port forwarding, used by the MCP tunnel, joins `keyOnly` in item 6.

## Checkpoint T1 — per-host WireGuard tunnels (this commit, branch `kotlin-tunnels`)

Its own PR against main, after #145.

- Go library `tunnel/omnitunnel` (module `github.com/jetsetslow-dev/omniterm/tunnel`):
  - wireguard-go plus gVisor's netstack, in userspace: no VpnService, no system VPN slot, no root,
    and other apps never see the tunnel.
  - A wg-quick configuration parser that says which line is wrong and never repeats a key.
  - `DialFd` connects inside the tunnel and hands Kotlin one end of a socketpair, so no port is ever
    listened on. Names go to the tunnel's DNS first; addresses outside AllowedIPs are refused.
  - Built with gomobile into an AAR by `scripts/build-tunnel.sh` (Gradle task `buildGoTunnel`),
    with the repo-local, checksum-verified Go 1.27.3 from `scripts/go-toolchain.sh` (approved
    Nov 8). About 6.5 MB per ABI.
  - Go tests (`scripts/test-tunnel.sh`: gofmt, vet, tests): real handshakes over loopback against an
    in-process peer; a 3 MiB echo; refusals; closing; a wrong peer key; an unknown endpoint.
- Routing (user, Nov 9: "if tunnel is confirmed and selected for a host it should never go
  direct"):
  - A host has an optional tunnel and an optional address inside it (`tunnelHost`); the same machine
    can be saved twice, once direct and once through a tunnel.
  - With a tunnel, every first hop goes through it: SSH (`HostRoute` → `TunnelSocketFactory`, the
    only JSch-specific piece), the jump host or proxy, the connection test, and TCP and certificate
    checks. There is no fallback: a tunnel that is down, refused or deleted fails closed.
  - The direct reachability probe is skipped; ping, DNS and web checks of the host's own address
    are not run ("Not checked: … through its VPN tunnel"), because they would go direct.
  - Changing a host's route closes its terminals (they reconnect over the new route) and stops its
    SSH tunnels (port forwards); the pool keys on the route, so no old session is reused.
  - A tunnel that hosts use cannot be deleted. A restored host whose tunnel is not in the backup
    points at a missing one and fails until the user picks one.
- Data: `tunnels` table (config encrypted), `servers.tunnelId` and `servers.tunnelHost` (DB 29,
  `MIGRATION_28_29`). Backups carry tunnels with their hosts; restore reuses an identical one.
- `TunnelManager` starts a tunnel on first use, restarts it when its configuration changes, and
  stops it after 5 idle minutes.
- UI: Tools → VPN tunnels (named so because "SSH Tunnels" already means port forwards), with paste
  or import, a live check, status (handshake, connections, traffic), stop and delete; the host
  editor's VPN tunnel picker and its never-direct note.
- Fixture: `wireguard` service in `scripts/test-hosts` (wireguard-go, a forward to internal-a's SSH,
  dnsmasq for `lab.vpn`); its keys are generated into `.env`.
- CI: `tunnel/` counts as code in both change detectors (tested), Go tests in PR Check and the
  gate, a CodeQL Go job, Dependabot `gomod`, and the gate's update check covers Go modules and the
  Go toolchain's patch releases. CI installs the pinned NDK when it is missing.
- Credits: wireguard-go (MIT), gVisor (Apache-2.0), gomobile and x/* (BSD-3), Haven (reference
  only, AGPL, no code).
- Later (T2+): SMB/FTP/WebDAV/Kubernetes through tunnels, ping and DNS through netstack,
  Tailscale/Headscale, NetBird, Nebula, Cloudflare Access, QR import.
- Results (Nov 9):
  - Go: `scripts/test-tunnel.sh` passes (gofmt, `go mod verify`, vet, tests).
  - Mutations, each seen failing a test:
    - a factory that ignores the tunnel;
    - the tunnel address ignored;
    - no restart on a new configuration;
    - an idle stop with connections open;
    - endpoint checks that skip the tunnel;
    - a probe that goes direct;
    - terminals kept over a changed route;
    - a missing tunnel restored as direct;
    - an identical tunnel not reused;
    - the tunnel address left out of backups;
    - an in-use tunnel deleted;
    - pooled sessions shared across routes.
  - Device (API 35, repo `wireguard` fixture): `E2eVpnTunnelTest` reaches `internal-a.lab.vpn`
    through the tunnel. With the tunnel route bypassed it fails, unable to resolve the name directly.
  - The device run found a real bug. The same machine through a different tunnel was refused as a
    duplicate. A host's identity is now address + port + login + route (user, Nov 9: "the dup ip
    should be in combination with cred and tunnel"), in the editor, in `addServer` and on restore.
  - `./scripts/local-pr-check.sh --full` passed: unit tests for both variants, lint, dependency
    verification, no advisories or updates (Gradle, Actions, Go), the secret scan, the API 35
    device tests, and local CodeQL with no alerts (88,639 lines). Go's module cache is kept out
    of the Java/XML extraction with `LGTM_INDEX_FILTERS`, locally and in CI.
- PR #147's first CI run failed three ways the local gate could not see (user, Nov 9: "why are so
  many pr runs failing, we should catch those before"). Each is fixed, and the gate now catches it:
  - Dependency review rejected the `PATENTS` file of Go's x/ libraries
    (`LicenseRef-scancode-google-patent-license-golang`, Google's extra patent grant). It is now
    allowed, with a note, and `scripts/check-licenses.py` checks every Go module's licence files
    against the same `allow-licenses` list in every gate. With main's list it fails on the same 8
    modules. Go modules also go to the advisory check (an old `x/net` fails it).
  - CodeQL Go "could not process any code written in Go": the build step put the pinned go in
    front of CodeQL's wrapper after init. `go-toolchain.sh --github` now sets it up before init,
    with `source-root: tunnel`. `scripts/test-workflow-guards.sh` keeps that order and fails on
    #147's workflow. `scripts/local-codeql.sh` analyses Go too, as the workflow does, with the
    checksum-pinned Go bundle fetched into `.go-toolchain/`.
  - `TunnelRoutingTest` read the direct echo server's accept count before its thread had run. The
    test now waits for the count, and the no-connection checks wait 300 ms so a queued one is counted.
    The gate repeats changed tests on one processor (`repeat-changed-tests.sh --cpus 1`). #147's
    version of the test failed 3 of 13 runs on one processor ("expected: 1 but was: 0", as in CI),
    and none of 5 on two, so two would not have caught it. The fixed
    test passed 13 of 13 runs on one processor, and still passes with the server's accept slowed by
    200 ms (#147's version fails that every time).
- Two security findings the gate could not see (user, Nov 9: "there's a security comment from git
  hub bot"):
  - Scorecard alert 40 on #147: the WireGuard fixture's `FROM alpine:3.22` had no digest. It now
    uses the digest the other fixtures already pin. `scripts/check-pinned-images.py` applies
    Scorecard's Dockerfile rule in the gate and PR Check, and also requires one digest per image
    and tag. It fails on #147's fixture, and on the digest Scorecard suggested, which differs from
    the other fixtures'.
  - CodeQL alert 39, open on main since Nov 3 (#136): `SshSignInLiveTest` ran `ssh-keygen` by
    relative path. Pull request runs compile no tests, so only main's run saw it. The test now uses
    `TestShell.find`'s absolute path. `scripts/local-codeql.sh` also compiles the unit and device
    test sources, as main's run does. On the old test it reports the same alert, at
    `SshSignInLiveTest.kt:190`.
  - Checked: the live sign-in test passes 7 of 7 against the repo's fixtures, and with the rebuilt
    fixture `E2eVpnTunnelTest` passes on the API 35 emulator.

## Checkpoint B1 — backups carry everything (in PR #147, after T1)

User, Nov 9: "but shouldn't a back up be everything not excluding things". Built on T1 (backups
changed there). The user then asked for it in the same PR: "merge that into the same 147 pr B1".

- New backup sections, ticked by default and each one sensitive (an encrypted backup):
  - **Fleet history**: the 50 runs with each host's output. A host not on the restoring phone keeps
    its name under a negative id, so "Use again" never picks another host.
  - **Monitoring history**: one point a minute per host, coarser (5, 15, 60 minutes) when a minute
    would pass about 160,000 points. Averaged in SQL, saved per host and day, so no array reaches
    the 50,000 items an older app refuses. A host with history on the phone keeps its span.
  - **AI assistant log**: the last 200 calls.
- With the hosts: tmux sessions (offered to attach again, never connected) and Compose stacks.
- The restore preview counts VPN tunnels, Telnet hosts, Kubernetes clusters, tmux sessions,
  Compose stacks and the new sections. Every restore adds only what the phone lacks (run key,
  session, stack, call, time span), so restoring twice changes nothing.
- An export a restore could not read (input, plain or compressed limit) is refused with the size
  and what to untick; before, it was written and failed only at restore.
- Selection v3. A saved v1/v2 selection gains Fleet and Monitoring history with Servers, and the
  assistant log with Settings. Monitoring history ticks Servers, as unticking Servers unticks it.
- `sftp_last_path_*` is a leftover: nothing writes it, so nothing is lost there.
- Access, decided by the user on Nov 9 (both as proposed):
  - **Automation & AI assistants** (new section, ticked, sensitive; brings Scripts and Servers):
    each grant with its script by category and name and its hosts, and the assistant's settings
    and token fingerprint, with hosts and tunnel host remapped. A restore sets the Automation
    switch and the assistant off, stops a running assistant server after the restore commits,
    replaces the phone's assistant token, and says what is off. Grants dedupe by token.
  - **App Lock** with Settings: the PIN (PBKDF2, salted, portable), the lock and its re-lock time.
    It comes back only to lock: a backup made with the lock off leaves the phone's lock. Biometric
    unlock and failed attempts stay per phone. The restore says the backup's PIN is now asked for.
  - README and PRIVACY.md say so; `DEVICE_LOCAL_SETTINGS` keeps biometrics, lockout, the switches
    and the assistant's settings out of the settings object (older apps skip the PIN too).
- `BackupSelection.NONE` is the one "nothing ticked" selection. Tests built their own, and each new
  section defaulted to ticked there: it ticked Servers, so a "nothing" export needed a password.
- Results:
  - 10 backup, automation, assistant and App Lock test classes pass (57 tests).
  - 11 mutations, each caught:
    - the Automation switch or the assistant left on;
    - grants on the old host ids;
    - biometrics restored;
    - App Lock never restored, or a lock-off backup bringing its PIN;
    - the settings loop restoring App Lock as stored;
    - a missing host given id 0;
    - the phone's own monitoring span overwritten;
    - a Fleet run restored twice;
    - an export too large to restore written anyway.
    The App Lock test's "lock off" backup first had no PIN at all, so two of these mutations
    passed. It now keeps a PIN with the lock off, as the switch leaves it.
  - Device (API 35): `BackupCompatibilityInstrumentedTest`, `E2eBackupSelectionFeedbackTest` and
    the settings-backup case of `E2eSettingsStateStressTest` pass.
  - Unrelated and already broken: that class's opt-in battery-saver case fails without B1 too. It
    waits for the saver without accepting the prompt that #98 added, and it needs a lab host
    ("E2E Foreground Demo") that the fixtures do not have. Left for later.

## Bundle after #147 — more tunnels, homelab, Fleet (branch `kotlin-homelab-bundle`)

User, Nov 9: "bundle 1,2 and 3with small items and keep rest two as separate prs". After #147, one
PR carries items 3–5 of "Remaining", plus the small items. The Go engine and iOS stay separate PRs.
Also Nov 9: "we should start bundling things to reduce the number of times we run the gates". So
there is one full gate when the bundle is complete, and targeted tests per piece until then.

- Branched from #147's head after main was merged in (e64e1f0). Retarget to main once #147 merges.
- Contents:
  - tunnels T2+: Tailscale/Headscale, NetBird, Nebula, Cloudflare Access;
  - homelab F: Proxmox VE API, SNMP, container image updates, backup freshness presets;
  - the five Fleet enhancements approved on Nov 9;
  - small items: the bundling rule in AGENTS.md, and `E2eSettingsStateStressTest`'s opt-in
    battery-saver case. That case waits for the saver without accepting #98's prompt, and needs
    a lab host ("E2E Foreground Demo").
- Seeing runs that other apps start (user, Nov 9: "if tasker triggers a command, where can I see
  what is happening in omniterm ... same with MCP"). Today they reach Fleet's History only when they
  finish, and Tasker runs carry no label there, although the README says they do. In the bundle:
  - the Automation label in History;
  - a run saved when it starts and updated as each host finishes;
  - a notification per run, chosen per token (user, Nov 9: "Choose per token"). Each automation
    token and the AI assistant get off, failures only or always. New ones start at failures only:
    progress while running, gone when every host succeeds, kept naming the failed hosts when one
    fails, and a tap opens the run. The setting is backed up with its grant;
  - Recent calls entries open the run they started;
  - a History filter by source.
  Alert-triggered runs use the same notification and History path.
- Token usage history (user, Nov 9: "also add token usage history for automation and MCP with
  success and failure status of each run"):
  - Each automation token, and the AI assistant's token, lists every use: when, script or tool,
    hosts, and succeeded, failed or refused. Refused covers the switch being off, the danger list,
    a missing value and an unknown host.
  - A use that made a Fleet run opens it.
  - The newest few hundred per token are kept, and backed up with Automation & AI assistants.
  - "Token" means OmniTerm's access tokens; the app never sees an AI model's token counts.
- The other Fleet candidates are in too (user, Nov 9: "also bundle this etc the rest"):
  - identical output grouped;
  - a failure threshold;
  - saved target sets;
  - output filtering;
  - sudo in Fleet, asking as every sudo action does (App Lock, then device lock, then a plain
    confirm);
  - broadcast typing, last.
- Build order, so nothing is redone:
  1. Run visibility and token usage history. This is the run-recording and notification path that
     scheduled and alert-triggered runs reuse.
  2. Fleet: the five approved enhancements, then the other six.
  3. Homelab F.
  4. Tunnels T2+, the largest piece and Go-only.
  5. The small items.
  Targeted tests and device runs per piece; one full gate at the end.
- #147 merged as 7a50379. Main's publish failed twice without a code fault: first a GitHub
  "Internal server error" before any job ran, then sum.golang.org dropping an HTTP/2 stream inside
  gomobile's own `go mod tidy`. The third attempt published v0.9.296-main.1, and every other main
  workflow passed. In this bundle, `scripts/retry-network.sh` (tested by
  `scripts/test-retry-network.sh`, run by the gate and PR Check) retries those Go downloads twice
  on network errors only.
- Piece 1, run visibility and token usage history: done (commit "See what other apps and
  assistants run").
  - A run from Tasker, another app or the AI assistant is saved when it starts, with every host
    running, and each host is saved as it finishes. A host cut off when the run stops is saved as
    stopped. A run left running when OmniTerm died is ended the next time a run starts or History
    opens, if it began more than 11 minutes before (the 9-minute run limit plus 2).
  - History shows the Automation label, a running state that follows the run live, and filter
    chips by kind when there is more than one.
  - Notifications per token, on channel `external_runs`: off, running and failures (the default),
    or always. A tap opens the run (`omniterm://notification/fleet-run/<key>`; MainActivity reads
    only a key of a run's shape, since anything can send it).
  - Each token's uses (newest 300; revoking deletes them) and the assistant's Recent calls: when,
    succeeded, failed or refused, a detail, and a link to the run. A denied assistant run is now
    refused, not failed, since nothing ran.
  - Backups carry each token's notification choice and uses, the assistant's notification choice,
    and each call's run link. A restore adds only uses it lacks, so restoring twice adds nothing.
    Room schema 30 (migration 29→30).
  - Validation: unit tests `AutomationRunnerRobolectricTest` 16, `McpToolsTest` 11,
    `AutomationBackupRobolectricTest` 3, `HistoryBackupRobolectricTest` 7,
    `NotificationLinksTest` 4, `AppMcpBackendRobolectricTest`, all 0 failed. Guards seen failing:
    no save at start, stopped hosts not saved, a result never kept, stale cleanup ignoring the
    source, uses dropped on restore, uses restored twice.
  - Devices (API 35 emulator, repository fixture on 127.0.0.1:2205):
    - `E2eAutomationTest` (`-e omniterm_e2e_automation yes -e host 127.0.0.1`): 1 test, 0 failed.
      It checks that a new token's notification is gone after a success. With "Always" picked on
      the card, the result stays as "E2E Tasker ran E2E automation / Succeeded on its host.", and
      tapping it opens the run's details, marked Automation. The card's uses show Succeeded and
      open their runs.
    - `E2eMcpTest` (`-e omniterm_e2e_mcp yes -e host 127.0.0.1`): 1 test, 0 failed. The denied
      run is refused and the approved one links an AI-assistant run. Its kept notification names
      the client, and Recent calls opens the run.
    - Guard: with MainActivity ignoring run links, `E2eAutomationTest` failed waiting for the run
      to open (line 153).
    - The notification tap goes to the test's own activity. The test therefore uses
      `keepLaunchIntent()`, or the rule cannot close the activity (seen: "never becomes DESTROYED",
      last state PAUSED).
  - `TestNotifications` (androidTest) is now the one copy of the permission grant and the posted
    notification lookups that three alert suites each had. `alertNotificationId` moved out of
    AppViewModel so tests use the app's own id. Those three suites (`E2eAlertLifecycleStressTest`,
    `E2eHostChecksTest`, `E2ePhoneChecksTest`) compile but have not run on a device since. They
    are in the bundle's device sweep.
- Piece 2, Fleet (in progress):
  - Each host's own details: done (commit "Let a script use each host's own details").
    `{{host.name}}`, `{{host.address}}`, `{{host.user}}`, `{{host.port}}`, `{{host.group}}` and
    `{{host.os}}` are filled in per host, in one pass with the asked values, everywhere a saved
    script runs. A command the assistant types is sent as written. Tests: `ScriptParamsTest` 13,
    `AutomationRunnerRobolectricTest` 17, `FleetBroadcastOutcomeRobolectricTest` 6; guards seen
    failing.
  - Host tags, a Tags target mode and saved target sets: done (commit "Pick Fleet hosts by tag,
    and save the targets").
    - A host takes up to 20 tags of up to 32 characters (`servers.tags`, "db, prod"), compared
      without case. The host editor offers existing tags, cards show three, and host search
      matches `#tag` or `tag`.
    - Broadcast picks hosts, groups or tags. With several tags, Any or Every.
    - Saved sets (`fleet_target_sets`) keep only the current mode's picks. Saving a name again
      replaces that set.
    - Backups carry tags and sets with the hosts. A set of picked hosts keeps only the hosts in the
      backup and is re-pointed to the restored hosts; the phone's own set of a name wins.
    - Room schema 30 again (still unreleased), so the next device install needs `adb uninstall`.
    - MCP `list_hosts` does not report tags: nothing asked for it, and it would widen what
      PRIVACY.md says the assistant sees.
    - Tests: `HostTagsTest` 8, `FleetTargetBackupRobolectricTest` 3, `VpnTunnelBackupRobolectricTest`
      1, `BackupSafetyTest` 4, all 0 failed. The migration test gains
      `migrationToThirtyGivesHostsNoTagsAndAddsNoSavedTargets`. Guards seen failing: tags not
      restored, set hosts not re-pointed, Every read as Any.
    - Devices (API 35 emulator, fresh install, repository fixture on 127.0.0.1:2205):
      `AppDatabaseMigrationTest` 13, `E2eScriptParamsFleetTest` 1, and the new `E2eFleetTagsTest`
      (`-e omniterm_e2e_fleet_tags yes -e host 127.0.0.1`) 1, all 0 failed. The new test tags the
      host in its editor, runs Broadcast on Every of two tags, saves the targets, clears them,
      picks them again from Saved, and deletes the set. Guard: with the editor not saving tags, it
      failed waiting for them.
    - The saved-sets dialog now scrolls, and each host card's menu button has a test tag.
  - Push a file to many hosts: done (commit "Push a file to many hosts from Fleet").
    - Broadcast's **Push a file** picks a file and a destination per run. A path ending in `/`
      (or `~/`, or nothing) is a folder; a path that is a folder on the host gets the file inside.
    - The phone copies the file once (cacheDir/fleet-push, 100 MB at most), so every host and a
      retry read the same bytes. The copy goes when the cards are cleared or the model ends.
    - A push is a Fleet run: same targets, rolling batches, Stop, Retry, Share, notification and
      History. Each host gets a hidden staged file whose size is checked before it replaces the
      destination (the Files screen's commit, reused).
    - History marks a push (`fleet_runs.pushedFile`, folded into schema 30) and offers no Use
      again. Backups carry it.
    - `AppViewModel` takes an optional file-client factory, the seam the tests use and the Go
      engine can fill later.
    - Sudo for protected paths comes with "sudo in Fleet"; until then a push there fails, naming
      the cause.
    - Tests: `FleetPushTest` 4, `FleetPushRobolectricTest` 1 (in-memory hosts),
      `HistoryBackupRobolectricTest` 7, `FleetRunHistoryRobolectricTest` 6,
      `FleetBroadcastOutcomeRobolectricTest` 6, all 0 failed. Guards seen failing: no size check,
      folder not detected, Use again on a push, retry without the file, backup dropping the push.
    - Devices: the new `E2eFleetPushTest` (`-e omniterm_e2e_fleet_push yes -e host 127.0.0.1`) 1,
      `AppDatabaseMigrationTest` 13, `E2eFleetTagsTest` 1, `E2eScriptParamsFleetTest` 1, all 0
      failed. The push test replaces an older copy on the lab host through the dialog, checks
      that no part file is left, and sees a missing folder fail. Guard: without the commit step it
      failed ("old copy").
  - Scheduled runs: done (commit "Run a saved script on a schedule from Fleet").
    - Fleet → Schedules: name, script, hosts (Broadcast's picks or a saved set), Every 15 min to
      12 h, Daily at a time, or Weekly on a day at a time, and the token-style notification
      choice. Each card shows the next run and the last one (it opens the run in History), a
      pause switch, Run now and Delete.
    - Each schedule waits as one persisted JobScheduler job (ids 0x4F4E_xxxx; Run now 0x4F4F_xxxx;
      automation keeps 0x4F4D_xxxx), with a network. The next run counts from when the last one
      started, so a phone asleep through several runs makes up one. The app start reconciles the
      jobs (a force-stop drops them). `RECEIVE_BOOT_COMPLETED` is new in the manifest and
      PRIVACY.md. WorkManager was not used: it is only transitive here, and the job engine is
      the one automation already uses.
    - A run goes through `AutomationRunner.runScript` with source `schedule` ("Scheduled" in
      History) and refuses what automation refuses (`UnattendedScripts.Runner.SCHEDULE`). Groups
      and tags resolve when it runs; offline hosts fail. A refusal posts "could not run" and opens
      the Schedules tab. One schedule never overlaps itself. Notifications use a new "Scheduled
      Fleet runs" channel.
    - Backups carry schedules in the Automation & AI assistants section, by script and host, and
      restore them paused. `fleet_schedules` is folded into schema 30.
    - iOS has no background scheduler of this kind; the iOS PR shows a notice instead.
    - Tests: `FleetScheduleTimingTest` 5 (intervals, daily, weekly, London's clock changes, typed
      times), `FleetScheduleRobolectricTest` 5 (tag targets and History, refusals and their
      notification link, no overlap, paused timer, persisted job and next run, app-start
      reconcile), `AutomationBackupRobolectricTest` 3 (schedules round-trip paused, once),
      `AutomationRunnerRobolectricTest` 17, `FleetTargetBackupRobolectricTest` 3,
      `HistoryBackupRobolectricTest` 7, `BackupSafetyTest` 4, `FleetRunHistoryRobolectricTest` 6,
      `FleetPushRobolectricTest` 1, all 0 failed. Nine guards seen failing: overlap, refusal,
      target matching, orphan jobs, counting from the start, persistence, strictly-after times,
      restored switched on, a paused timer running.
    - Devices (API 35, fresh install, repository fixture on 127.0.0.1:2205): the new
      `E2eFleetScheduleTest` (`-e omniterm_e2e_fleet_schedule yes -e host 127.0.0.1`) 1,
      `AppDatabaseMigrationTest` 13, `E2eAutomationTest` 1, `E2eMcpTest` 1, `E2eFleetPushTest` 1,
      `E2eFleetTagsTest` 1, all 0 failed. The new test makes a schedule in the editor from
      Broadcast's picks, sees its persisted job, runs it now over SSH, finds the run in History as
      Scheduled, opens it from the card, and pauses it. Guard: a job service that never runs made
      it time out waiting for the run.
  - Alert-triggered runs: done (commit "Let an alert run its runbook on its own").
    - An alert rule with a runbook gains **Run it on its own when an incident opens** (off by
      default) and the token-style notification choice. The editor shows why a script cannot run
      unattended and will not save the switch on until it can.
    - When an incident opens, the runbook starts on that one host as an expedited job (ids
      0x4F50_xxxx; a deadline-0 job when expedited is refused). Each rule and host starts at most
      once every 30 minutes, so a service that keeps falling over is not restarted in a loop. The
      cooldown is in memory: a restarted app may run it once more.
    - The job runs only while the rule still runs it on its own and the incident is still open. It
      goes through `AutomationRunner.runScript` with source `alert` ("Runbook, on its own" in
      History, grouped with runbooks) and refuses what automation refuses
      (`UnattendedScripts.Runner.ALERT`). A refusal posts "could not run" and opens the alerts. The
      incident keeps the run's key (`active_alerts.runbookRunKey`) and links to it in Fleet's
      history. Notifications use a new "Runbooks alerts ran" channel.
    - `alert_rules.runbookAuto`/`runbookNotify` and `active_alerts.runbookRunKey` are folded into
      schema 30. Backups carry the notification choice; the switch is always restored off.
    - The three job services now share one `RunJobService` (scope, running jobs, failures logged,
      cancellation passed on).
    - Tests: `AlertRunbookRobolectricTest` 4 (the incident's host only and its link, nothing once
      the incident closed or the rule only offers it, refusals and their link, the cooldown),
      `HostCheckAlertsRobolectricTest` 8 (an incident starts the runbook only for a rule set to),
      `ScriptRefsBackupRobolectricTest` 1, `FleetScheduleRobolectricTest` 5,
      `AutomationRunnerRobolectricTest` 17, `AutomationRobolectricTest` 11,
      `AutomationBackupRobolectricTest` 3, all 0 failed. Seven guards seen failing: an incident not
      starting it, the switch ignored, no cooldown, a closed incident, no refusal, no link,
      restored switched on.
    - Devices (API 35, fresh install, repository fixture on 127.0.0.1:2205): `E2eAlertRunbookTest`
      1, `E2eFleetScheduleTest` 1, `AppDatabaseMigrationTest` 13, `E2eAutomationTest` 1,
      `E2eMcpTest` 1, `E2eHostChecksTest` 1, `E2eFleetPushTest` 1, `E2eFleetTagsTest` 1, all 0
      failed. The new `E2eAlertRunbookTest`
      (`-e omniterm_e2e_alert_runbook yes -e host 127.0.0.1`) makes a script check fail on the lab
      host, sees the runbook run on its own over SSH and fix it, opens the run from the incident,
      and waits for the next checks to close it. Guard: a job service that never runs made it time
      out waiting for the run.
  - Identical output grouped: done (commit "Show hosts that ended the same way as one card").
    - Hosts with the same status, output, note and truncation share one card ("12 hosts, same
      result"), which lists each name in its host colour and takes no host's colour itself. Only
      hosts whose card has no actions group (Success, Failure, Waiting, Not run); Running,
      Reconnecting, Detached and Needs tmux keep their own. Groups keep their first host's place.
    - `FleetOutputGroups.group` is the one rule for Broadcast's cards, History's cards and the
      shared report ("== nas, pi · complete"). No setting: a group only merges cards that would
      read the same.
    - Credit: ClusterShell `clush -b` and pdsh `dshbak -c` (README, NOTICE, audit; the audit's
      earlier pssh/Ansible credit was wrong).
    - Tests: `FleetOutputGroupsTest` 3, `FleetRunHistoryRobolectricTest` 7 (live and history
      reports share a section, and split when one host differs), `FleetRollingRunRobolectricTest`
      4, `FleetPushRobolectricTest` 1, `FleetBroadcastOutcomeRobolectricTest` 6, all 0 failed. Four
      guards seen failing: the note ignored, every status grouped, groups reordered, the report
      not grouped.
    - Devices (API 35, repository fixture on 127.0.0.1:2205): `E2eRollingFleetTest` 1 (after the
      retry the two hosts share one "2 hosts, same result" card that names both, in Broadcast and
      in History, and the shared report has one section for them), `E2eFleetTagsTest` 1,
      `E2eFleetScheduleTest` 1 (twice), `E2eScriptCheckTest` 1, `E2eAlertRunbookTest` 1,
      `E2eFleetPushTest` 1, `E2eScriptParamsFleetTest` 1, all 0 failed. Guard: with Broadcast's
      cards not grouped, the rolling test failed ("2 hosts, same result" not displayed).
    - That guard first failed with a `NullPointerException` from the test's own cleanup: removing
      the share monitor before one was added. The cleanup stopped there and left its host copy,
      which then broke `E2eFleetTagsTest`. The test now removes the monitor only once added, and
      deletes a copy an earlier run left before it starts.
  - Fix found by that sweep (commit "Keep a schedule's job when it is saved as the app starts"):
    `E2eFleetScheduleTest` failed once with "it waits as a job". The app start's `reconcile` read
    the schedules, the editor then saved one and armed its job, and `reconcile` dropped that job as
    having no schedule. A schedule switched back on in that window lost its job and its next run
    the same way. `apply`, `armNext` and `reconcile` now take turns on one lock, and Delete goes
    through `apply`. `FleetScheduleRobolectricTest` 6 (a schedule saved while the app starts keeps
    its job, through a seam between the read and the matching); guards seen failing with either
    `reconcile` or `apply` unlocked. `E2eFleetScheduleTest` also waited for the job only as long
    as its next run took to appear, though the job is armed just after; it now waits for the job.
    Devices: `E2eFleetScheduleTest` 1, twice, with the sweep above.
  - A failure threshold: done (commit "Let a rolling run allow a share of its hosts to fail").
    - Under **Stop if a host fails**, **Failures allowed**: None (as before), 10%, 25% or 50%.
      The run stops once more than that share of all its hosts has failed, counted over the whole
      run rather than per batch as Ansible's `max_fail_percentage` is, so it works one host at a
      time. The hosts left say so ("Not run: 2 of 4 hosts did not succeed, more than the 25% the
      run allows."), and the confirmation names the share.
    - The choice is a setting (`broadcast_failure_percent`), so backups carry it with the others.
    - Credit: Ansible (README, NOTICE, audit).
    - Tests: `FleetRollingRunRobolectricTest` 6 (the boundaries, and a run that goes on past the
      allowed failure and stops at the next), `FleetRunHistoryRobolectricTest` 7, all 0 failed.
      Three guards seen failing: counted per batch, the share itself counted as over it, the
      share ignored.
    - Devices (API 35, repository fixture): `E2eRollingFleetTest` 1 (now also picks 50% in the
      editor, sees the confirmation name it, and the second host runs after the first fails),
      `E2eFleetTagsTest` 1, `E2eFleetPushTest` 1, `E2eScriptParamsFleetTest` 1,
      `E2eFleetScheduleTest` 1, `E2eScriptCheckTest` 1, all 0 failed. Guard: with the share
      ignored, the second host was left not run and the test failed.
  - An output filter and search: done (commit "Narrow a Fleet run's cards to a text or the failed
    hosts").
    - Above the cards of a run with more than one host: **Find in outputs** (name, output or
      note, any case) and **Failed only** (failed or not run: what Retry runs again, now one
      shared test, `didNotSucceed`). A line says how many hosts show. `FleetOutputFilter` runs
      before the grouping, in Broadcast and in History. It clears when a run starts; the shared
      report always has every host.
    - Tests: `FleetOutputFilterTest` 4, `FleetOutputGroupsTest` 3, `FleetRollingRunRobolectricTest`
      6, `FleetRunHistoryRobolectricTest` 7, all 0 failed. Four guards seen failing: running
      hosts counted as failed, a text matched by case only, notes not searched, spaces searched.
    - Devices (API 35, repository fixtures): `E2eRollingFleetTest` 1 (in its last run, where
      one host fails and one does not, "Failed only" leaves the failed host's card and says
      "Showing 1 of 2 hosts", a text from the other's output in other capitals leaves that one,
      and both show again once cleared), `E2eScriptCheckTest` 1, `E2eFleetScheduleTest` 1,
      `E2eFleetTagsTest` 1, `E2eFleetPushTest` 1, `E2eAlertRunbookTest` 1, all 0 failed. Guard:
      with the cards ignoring the filter, the rolling test failed at its count of cards.
  - Sudo in Fleet: done (commit "Run a Fleet command, or write a pushed file, with sudo").
    - **Run with sudo** in Broadcast, and **Write with sudo** in the push dialog, are one switch
      (`broadcastSudo`, never saved: off again when the app starts). A run with it on waits in
      the app's existing sudo question (`pendingSudoAction`: App Lock, else the screen lock, else
      a plain question), once for the run's hosts; Retry and Use again keep sudo and ask again.
    - A command runs whole as root (`sudoShWrap`, in `sh`), with each host's own saved sudo
      password on the command's input (`sudoStdin`), never in the command; a host with none
      saved uses `sudo -n`. sudo's own refusal is what the card says (`sudoRefusal`: only sudo's
      words in the first lines, so a command's own "Permission denied" is not taken for one).
      Windows hosts fail with "Windows hosts have no sudo." Run in tmux is not used with it: a
      password cannot be handed to a command in tmux without leaving it on the host.
    - A push with sudo uploads to the login's home under a hidden name, checks the size, and
      root finishes the file beside its destination and moves it over it in one step, with the
      owner and permissions of a file it replaces (`sudoInstallFile`); what was uploaded is
      removed either way. This closes "a push to a protected path fails" from the push entry.
    - `fleet_runs.sudo` (folded into schema 30) marks the run: History says "with sudo" and
      shows root's `#`, the shared report too. Backups carry it.
    - Schedules, automation and MCP never use sudo: nobody is there to answer.
    - Tests: `FleetSudoRobolectricTest` 6, `FleetPushRobolectricTest` 1 (its in-memory host is
      now the shared `MemoryHost`), `HistoryBackupRobolectricTest` 7. Eight guards seen failing:
      no question asked, the password not sent, tmux used, a retry without sudo, the refusal
      not named, a Windows host run anyway, the upload left behind, the history forgetting sudo.
    - Devices (API 35, clean install, repository fixtures): `E2eFleetSudoTest` 1 (turned on in
      Broadcast, the confirmation shows root's `#` and the sudo question follows; `id -u` is 0 with
      no sudo password saved and with one saved, the login without sudo, and History marks the
      run; a file pushed into `/etc` belongs to root and nothing is left in the login's home),
      `E2eRollingFleetTest` 1, `E2eFleetPushTest` 1, `E2eScriptCheckTest` 1,
      `E2eFleetScheduleTest` 1, `E2eAlertRunbookTest` 1, `E2eAutomationTest` 1, `E2eMcpTest` 1,
      `E2eFleetTagsTest` 1, `E2eScriptParamsFleetTest` 1, `E2eHostChecksTest` 1,
      `AppDatabaseMigrationTest` 13, all 0 failed. Guard: with the sudo question skipped,
      `E2eFleetSudoTest` failed waiting for it.
    - The new switch pushes Broadcast's rolling controls below the fold, so `E2eRollingFleetTest`
      now scrolls to the batch chips and "Stop if a host fails" before tapping them, as a user does.
  - Next: broadcast typing, last of the Fleet items.
- Piece 4, Tunnels (in progress):
  - Tunnels follow the network (user, Nov 11): done (commit "Let a tunnel be skipped on the Wi-Fi
    networks it is not needed on").
    - A tunnel takes up to 10 Wi-Fi names (`tunnels.directWifi`, one per line, folded into schema
      30). On one of them its hosts dial their own address; on any other network, on mobile data,
      behind another app's VPN, or when the name is not known, they go through the tunnel.
    - `HostRoute.tunnelNow` is the one decision, asked by everything that dials a host:
      `HostCredentials.build` (SSH, SFTP, Fleet, checks, automation, MCP), the direct reachability
      probe, the endpoint checks and the editor's Test. No engine knows about it, so Tailscale and
      the other kinds get it as they land. A tunnel that is gone still fails closed.
    - `CurrentWifi` follows Android's default network. The name needs `ACCESS_FINE_LOCATION`
      (with `ACCESS_COARSE_LOCATION` and `ACCESS_WIFI_STATE`, all new in the manifest and
      PRIVACY.md), asked for in the tunnel editor only. Android gives the name only while the app
      is on screen, so `WifiMemory` keeps it per connection (Android's network handle, with the
      boot count) for background checks, schedules and automation. Background location is not
      requested: on a Wi-Fi joined while the app was closed, background runs use the tunnel.
    - When the phone joins or leaves a named Wi-Fi, or the list changes, the hosts' kept
      connections over the old route are dropped, terminals reconnect, SSH forwards stop, and a
      tunnel no host goes through any more comes down.
    - Editor: type a name or **Add the Wi-Fi this phone is on**; the card says when its hosts are
      going direct; the host editor names the exception. Backups carry the list; a tunnel the
      phone already has keeps its own.
    - iOS needs Apple's "Access Wi-Fi Information" entitlement, which needs a paid developer
      account, so the iOS PR shows a notice instead.
    - Tests: `TunnelNetworksTest` 5, `TunnelNetworkRouteRobolectricTest` 4,
      `VpnTunnelBackupRobolectricTest` 1, `TunnelRoutingTest` 8, all 0 failed. Seven guards seen
      failing: an unknown network going direct, names matched without case, a name kept for
      another connection, credentials ignoring the rule, a deleted tunnel going direct, the
      network not followed, the backup dropping the list.
    - Devices (API 35, clean install, repository fixtures with the WireGuard one):
      `E2eVpnTunnelTest` 1 (`-e omniterm_e2e_vpn yes` and the keys from `scripts/test-hosts/.env`)
      now also allows location, adds the emulator's own Wi-Fi in the tunnel's editor, sees the
      card say its hosts connect directly, reaches the host behind a tunnel that cannot connect,
      then takes the Wi-Fi off the list and sees that host fail closed again.
      `AppDatabaseMigrationTest` 13 (an upgraded tunnel names no Wi-Fi), `E2eRollingFleetTest` 1,
      `E2eFleetScheduleTest` 1, `E2eAlertRunbookTest` 1, `E2eAutomationTest` 1, `E2eMcpTest` 1,
      `E2eHostChecksTest` 1, `E2eFleetTagsTest` 1, `E2eFleetPushTest` 1,
      `E2eScriptParamsFleetTest` 1, `E2eScriptCheckTest` 1, all 0 failed. Guard: with the rule
      ignored, the host went into the broken tunnel and the test failed there.
    - The test leaves the location permission granted to the installed test build: taking a
      permission away kills the app under test.
  - Next: Tailscale/Headscale, NetBird, Nebula and Cloudflare Access, with the `check-licenses.py`
    fixes the feasibility run found.
- Tailscale feasibility (Nov 9, in a scratch copy of `tunnel/`):
  - `tailscale.com` v1.104.5 targets Go 1.27.3, the repo's toolchain.
  - It needs gVisor 2026-09-15; WireGuard's netstack pins 2025-05-03. With the newer gVisor,
    `omnitunnel` still builds and its tests pass, and an Android arm64 build without cgo works.
  - tsnet brings 568 packages, against 206 today. Size is still to measure.
  - Licences (`check-licenses.py --module` on the copy): 41 modules, 3 problems.
    - Tailscale's `PATENTS` is a patent grant shaped like Google's Go grant: it only gives rights.
      ScanCode has no Tailscale entry, so Dependency review's name for it is unknown before it runs.
      It may match `google-patent-license(-golang)`, which is already allowed, or come out unknown.
    - `coder/websocket` is ISC, worded "modify, and distribute" instead of "and/or". The script's
      ISC signature needs that wording.
    - `tailscale.com/license_test.go` was read as a licence file. The script should skip source files.
  - Still open: Android blocks netlink, so interfaces must come from Kotlin, as tailscale-android
    does.
- Tailscale/Headscale tunnels (Nov 12, `kotlin-homelab-bundle`):
  - A second tunnel kind: the phone joins the tailnet inside the app with tsnet (`tailscale.com`
    v1.104.5), against Tailscale's control server or a Headscale one. The node's keys live in the
    app database, encrypted, for that tunnel alone, and are never backed up: a restored tunnel signs
    in again as a new device. An auth key signs in by itself; without one the card shows **Sign
    in**, which opens the control server's page. A host on the tunnel never goes direct: addresses
    the tailnet does not cover are refused ("is not in this tailnet"), and so is everything while
    the tunnel is not signed in.
  - Interfaces come from Kotlin (`TailscaleNetwork`), as tailscale-android does: Android blocks
    netlink. `TS_LOGS_DIR` is set before start; without it Android panicked ("no safe place found
    to store log state", from `logpolicy.LogsDir` via `ipnlocal`'s sockstatlog). Found on device.
  - Routes: `RouteAll` is set explicitly, so subnet routes other nodes offer are used on every
    platform. Names the tailnet's DNS covers (MagicDNS, split DNS) are asked of the tailnet's DNS
    only, never the phone's; other names use tsdial's dial plan.
  - Errors: only the control server's refusal fails a start. "rate limited" is a note and the
    tunnel retries; "IPN bus consumer fell behind" re-watches. A state the app cannot save is
    reported to the node; a saved state that cannot be read signs in again and says why.
  - Lifecycle as WireGuard: starts on the first dial or **Connect**, stops after 5 idle minutes.
    `SetNetwork` before the first start, `NetworkChanged` on every default-network change.
    Counters are read on demand, cached 2 s; status is polled every second only until running.
    A key that expires mid-run needs Stop and Connect; an in-run re-login ask was left out
    untested.
  - The library leans on tsdial internals: `UserDialPlan`, `UseNetstackForIP`, `NetstackDialTCP`
    and `DNSManager.Query`. A Tailscale upgrade must keep
    `TestOnlyTheTailnetIsDialledNeverTheDirectAddress` passing unchanged, and dependency updates
    must not auto-accept `tailscale.com` bumps.
  - Plain-HTTP control servers are warned about (not on loopback): the node key is fetched from
    `/key` on every start, so a path attacker could pose as the control server. The warning is one
    shared `PlainHttpWarning`, also used by the WebDAV warning.
  - Fixture (`scripts/test-hosts`): `headscale` (0.27.1, digest-pinned, 127.0.0.1:8085) and, in
    the `tailnet` profile, `tailnet-router` (tailscale v1.104.4, digest-pinned), a subnet router
    for the internal network. `./scripts/test-hosts.sh tailnet` writes a relay map naming
    headscale's own STUN server (`.tailnet/`, ignored); without STUN both ends looped "Rebinding"
    and no path formed. It mints a reusable router key and an ephemeral phone key into `.env`.
  - Tests: Go `tailscale_test.go` 16 (`scripts/test-tunnel.sh`, build tags minus
    `ts_omit_tailnetlock` and `ts_omit_advertiseroutes`). In-process, the subnet router accepted
    the TCP handshake but passed no data, so the Go test asserts the routing decision; data through
    a subnet route is proven on device. JVM: `TunnelRoutingTest` 10, `TailscaleSettingsTest` 3,
    `VpnTunnelBackupRobolectricTest` 2, `TunnelNetworksTest` 5,
    `TunnelNetworkRouteRobolectricTest` 4, all 0 failed.
  - Guards seen failing: Go 13 (dials direct, dials while signed out, state not loaded or not
    saved, no sign-in page, refusal ignored, interface-up ignored, routes refused, "busy" taken as
    refusal, tailnet DNS skipped, save error swallowed, unreadable state unsaid, no place for logs);
    Kotlin 4 (signed-out tunnel dials, node state leaks into the entity, node save dropped, loopback
    warned); device 1 (a signed-out tunnel reported running never showed the sign-in).
  - Devices (API 35, clean install): `E2eTailscaleTunnelTest` 1 (`-e omniterm_e2e_tailscale yes`
    with `ts_key`, `ts_behind`, `user`, `pass` from `.env`): editor checks, a host behind the subnet
    router reached, keys stored encrypted, a direct-only host refused, an unsigned tunnel waiting
    with **Sign in** and its host refused. `E2eVpnTunnelTest` 1, `AppDatabaseMigrationTest` 13,
    all 0 failed.
  - Size: the AAR grew from 10.5 MB to 30.0 MB. `libgojni.so` (stored uncompressed) per ABI:
    arm64 18.97 MB, armv7 18.17 MB, x86 18.27 MB, x86_64 20.35 MB, from about 6.1-7.0 MB. The
    universal debug APK is 137.9 MB, about +49.9 MB. Options for the user: ABI splits, dropping
    x86, compressed native libraries.
  - Licences: `check-licenses.py` passes, 54 Go modules. Tailscale's `PATENTS` naming in
    Dependency review is still to be seen on the PR.

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

On Nov 9 the user added:

- `kotlin-multiplatform` is a development branch only, so Kotlin fixes ship from main without
  waiting for iOS; in the end everything, iOS included, builds from `main`.
- There is no Apple Developer account. iOS work goes as far as it can without one (shared code, the
  simulator, GitHub's macOS CI); signing, TestFlight, the App Store and installs on a real iPhone
  are left out.
- The move from JSch to the Go engine stays. New SSH behaviour goes through `SshTransport` and
  `SshCredentials` only, and each new `SshCredentials` field is part of the contract the Go engine
  must honour.
- The Go engine and every swap the shared code needs come after the features (item 5 below). Only
  iOS-specific work stays on `kotlin-multiplatform`.
- Each feature set gets its own PR once it is complete, so it can be tested and shipped: this PR
  ends with D3 (scripts, Fleet, alerts, automation) and then goes to review. MCP, tunnels, the
  homelab additions and the Go engine with its swaps each follow in their own PR from main (built
  on the previous one, and retargeted, if that is not merged yet). Review and merge stay the user's.

## Remaining, in order

1. Automation: D1 (the Tasker plug-in and broadcast), D2 (`ssh://` links, the share target) and
   D3 (key install) are done. This PR (#138) ends here; items 2–6 are
   each their own PR.
2. MCP: done in checkpoint E (its own PR).
3. Per-host tunnels: WireGuard is checkpoint T1 (its own PR); then Tailscale/Headscale, NetBird, Nebula and Cloudflare Access from one
   Go library, built with a repo-local, checksum-verified Go toolchain (approved Nov 8). ZeroTier,
   OpenVPN and Pangolin's Olm are left out for their licences; Pangolin raw TCP resources work as a
   plain host and port.

   User, Nov 11: "also make tunnels network specific, i.e. when on home network bypass tunnel
   (wifi ssid), when outside that network use tunnels", then "what about tailscake" (Tailscale).
   So, for every tunnel kind, Tailscale included:
   - A tunnel takes a list of Wi-Fi names. On one of them its hosts dial their direct address; on
     any other network, or when the network cannot be identified, they use the tunnel.
   - It is a rule the user sets, not a fallback, so "a host with a tunnel never goes direct" still
     holds everywhere else.
   - Android gives a Wi-Fi name only with the location permission, asked for when the user turns
     this on; background location is not asked for. PRIVACY.md says so.
   - It is built in the shared routing (not in one engine), first, on WireGuard, in the bundle PR.
4. Homelab additions (user, Nov 8): Proxmox VE API, SNMP, container image updates, backup freshness
   presets.
5. Fleet enhancements (user, Nov 9: "investigate other enhancements there as well"), its own PR.
   The candidates and their sources are in the internal audit, under "Fleet uniqueness check".
   User, Nov 9: "include tags, variables and file pushes, and Automations adds schedules and alert
   triggers". So these five are in:
   - multi-tag targets;
   - per-host variables;
   - pushing a file to many hosts;
   - scheduled runs (Android WorkManager; iOS skipped with a notice);
   - alert-triggered runs. These are opt-in per alert rule and off by default. They get the same
     refusals as Tasker automation (danger list, placeholders with no default), a notification
     per run, and a Fleet history entry. Today's runbooks still ask on the phone first.

   Then: "i meant in general as a new PT works as well … i meant pr only". That is, a new PR for
   this set is fine. No wider scope is meant: these are Fleet features.

   The rest of the candidates:
   - per-host variables;
   - identical output grouped;
   - a failure threshold;
   - multi-tag targets and saved target sets;
   - pushing a file to many hosts;
   - filtering outputs;
   - sudo in Fleet;
   - scheduled runs on Android;
   - broadcast typing, last.
6. Portability, last (user, Nov 9), about 2–3 weeks for the engine:
   - The Go engine for SSH (commands, sign-in, terminal, port forwarding, agent, certificates,
     security-key signing through Kotlin), SFTP, SMB and FTP, built on the library and toolchain
     the tunnels bring. It goes in behind `SshTransport` and `RemoteFsClient` beside JSch, must pass
     every device suite, then becomes the default; JSch, smbj and commons-net are removed. Go's SSH
     library has no compression, so the per-host compression option goes.
   - `SshCredentials` fields the Go engine must honour beyond today's: `keyOnly` (D3). Remote
     (`-R`) port forwarding must work too: the MCP tunnel relies on it (E).
   - Swaps for shared code: Room → Room KMP (same schema and migrations), Moshi →
     kotlinx.serialization, OkHttp/Retrofit → Ktor, `R.string` → Compose resources.
7. On `kotlin-multiplatform` (draft PR #144), iOS-specific work only: the shared-module layout,
   the iOS app, and the iOS adapters (Keychain, Face ID, notifications, file picker, widgets,
   Shortcuts, background limits). Its first step (shared module with pure logic in `commonMain`,
   the iOS app shell, iOS CI on macOS runners) is up and green; it merges main as work lands.

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
