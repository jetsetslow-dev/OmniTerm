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

## Decision pivot — 2026-11-08

The Flutter migration (PR #92, `migration-to-flutter`) is cancelled. Flutter never shipped; the
Kotlin app is the only one that went live. OmniTerm stays one Kotlin codebase and gains iOS through
Compose Multiplatform, so nothing from this round is ported to Flutter. #92 is closed once Kotlin
Multiplatform works for iOS: the shared module builds for Android and iOS, the iOS app builds and
passes its tests on macOS CI, and a host connects with a working terminal on a simulator. iOS need
not match Android feature for feature (user, Nov 8); it can start as a subset. The Flutter branches
are kept.

## Remaining, in order

1. Alerts (checkpoint C):
   - C1 host checks: host offline (with a guard for when the phone itself has no network), failed
     services, containers in trouble, storage health (ZFS, md, SMART), ZFS scrub age, UPS on
     battery, reboot required.
   - C2: phone-side ping, TCP and DNS checks.
   - C3: opt-in forwarding to ntfy, Gotify or a webhook.
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
6. Compose Multiplatform: a shared module from the Aug 1 groundwork, pure logic first, then UI,
   then the iOS pieces (SSH engine, Keychain, notifications), with iOS CI on macOS runners.

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
