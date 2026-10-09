# OmniTerm working agreements

These rules apply to every contributor and automation tool working in this repository.

## Frequent recoverable checkpoints

- Commit and push completed, validated checkpoints frequently on the current working branch.
  Do not accumulate the entire review in an uncommitted worktree. The full validation and exact
  PR-head monitoring requirements below still apply; never bypass them to publish a checkpoint.
- During this review, maintain `WORK_PROGRESS.md` on the working branch with implemented fixes,
  remaining work, reproducible validation commands, known exclusions, and pending CI status.
  Update it in the same checkpoint as the code so another machine or agent can resume safely.
- Keep the tracked document sanitized: no credentials, private host details, local session IDs,
  or copied private logs. Local-only paths and detailed operational notes belong in `secrets`.
  A later move/deletion does not remove information from Git history.
- Before an authorized merge to `main`, consolidate the temporary tracker into the private
  handover under `secrets/internal-docs/docs/` and remove `WORK_PROGRESS.md` from the merge tree.
  Keep relevant permanent user-facing documentation and regression tests in the repository.
- On resumption, inspect the actual branch, commit, worktree, and exact-head PR checks. A note
  saying a push or validation was started is not proof it finished. Do not merge or release a
  checkpoint merely because it has been pushed or its checks are green.

## External continuation retries — every AI session

- This is a standing requirement for every AI-agent session working on OmniTerm, including
  Codex, Claude, and other clients. At session startup or resumption, verify or establish an
  external continuation schedule **before** doing long-running work. Do not wait until the
  agent has already hit its limit and can no longer schedule anything.
- Send the literal message `continue` to that exact session every 30 minutes, whether or not a
  rate limit is currently visible. Keep retrying through quota/reset windows without requiring
  the user to type it again. This resumes already-authorized work; it does not bypass quotas,
  purchase capacity, approve actions, or authorize additional work.
- The scheduler must run outside the AI turn/client: prefer a persistent `systemd --user` timer
  on Linux, or an equivalent external scheduler on other systems. An in-agent sleep loop,
  promise to retry later, or timer owned by the rate-limited agent is not sufficient.
- Target a stable session/thread ID using the client's supported queue/resume mechanism. Use
  a unique repository/client/session timer name; inspect and reuse an existing matching timer
  instead of installing duplicates. Never use `--last`, overwrite another session's timer,
  start a competing session in the same worktree, or blindly type into the focused window.
- Check the installed client's help before choosing the adapter. Codex's locally verified
  command is `codex queue --thread <exact-session-id> --message continue`. Claude and other
  agents must use their own verified, session-targeted external mechanism; do not assume Codex
  commands work for them. If the environment cannot schedule or address that session, report
  the precise limitation rather than claiming automatic retries are active.
- Verify the enabled timer, next scheduled run, and successful queue acknowledgement. Record
  the unit name, target session, interval, status/log commands, and stop command in the handover.
  Keep credentials out of committed files and service logs. Keep local session IDs in local
  units/private handovers, not in the committed instruction templates.
- A scheduled `continue` means resume the current authorized task from its saved state, not
  restart it or undo newer user instructions. Keep durable notes of changes, running jobs,
  exact test/PR heads, failures, and remaining work so a resumed session can check what actually
  completed. Never report an interrupted validation command as passing.
- Keep the schedule active while authorized work remains, including rate-limit pauses. Disable
  it when the user asks to stop, the session is retired, or its work is genuinely complete,
  without waiting for another scheduled tick. A continuation must never answer a request for
  approval or missing user information on the user's behalf.
- If an external or already-queued `continue` arrives after all authorized work and required
  validation are genuinely complete, stop and disable that exact session's schedule, verify it
  is inactive, briefly report completion, and end the turn. Do not invent follow-up work, broaden
  the review, reopen completed tasks, pursue another goal, or recreate the timer merely because
  a stale continuation arrived. Only a new substantive user request authorizes new work.
- Check completion before establishing a schedule on resumption. Never mislabel unfinished or
  blocked work as complete to stop retries, and never stop another session's schedule. Already-
  queued messages can outlive a disabled timer; they must follow the same completion stop rule.
- State availability limits: a user timer needs the machine and user service manager running.
  Do not enable lingering, change login policy, or weaken sandbox/approval controls silently.
  `AGENTS.md` is a repository-wide requirement, not a technical guarantee that every third-party
  client reads it; clients that use another instruction entrypoint must be pointed to this file.

### Reference Linux setup (Codex adapter)

The working setup uses two user units under the user's systemd configuration directory. Replace
all angle-bracket placeholders with verified local values. Use a session-specific basename such
as `omniterm-codex-<session-id>-continue` for new sessions; do not copy another session's ID.

`<unit>.service`:

```ini
[Unit]
Description=Continue the authorized OmniTerm AI session

[Service]
Type=oneshot
WorkingDirectory=<absolute-repository-path>
ExecStart=<absolute-codex-path> queue --thread <exact-session-id> --message continue
TimeoutStartSec=60
UMask=0077
```

`<unit>.timer`:

```ini
[Unit]
Description=Continue OmniTerm work every 30 minutes

[Timer]
OnActiveSec=30min
OnUnitActiveSec=30min
AccuracySec=5s
Unit=<unit>.service

[Install]
WantedBy=timers.target
```

After writing and verifying the resolved units, run `systemctl --user daemon-reload`, then
`systemctl --user enable --now <unit>.timer`. Verify with
`systemctl --user list-timers <unit>.timer --no-pager`. A manual
`systemctl --user start <unit>.service` checks delivery; inspect its acknowledgement with
`journalctl --user -u <unit>.service -n 10 --no-pager`. Stop with
`systemctl --user disable --now <unit>.timer`.

This is an external wrapper around the installed client's queue command, not a claim of a
built-in universal rate-limit-retry feature. Consult the installed CLI help and the
[official Codex instruction-file guidance](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
when configuring a Codex client to read these agreements.

## Validate before publishing

- App-wide UX requirement: user-triggered work must expose a visible busy/progress state while
  pending and a clear result, skip reason, or actionable error when finished. Never silently
  discard work or report completion before it finishes; use indeterminate progress when no
  trustworthy percentage exists.
- Scrollable popups, dialogs, menus and sheets must visibly indicate hidden content in each
  scroll direction before the first gesture, update indicators as the user scrolls, and remove
  them when nothing overflows. Do not rely on fading scrollbars alone. Keep primary actions and
  terminal Visible screen / Full buffer range switching discoverable without scrolling.
- Saved-server identity is host + port + effective SSH username + authentication method, not
  display name. Resolve credential profiles before comparison. Apply the same rule to add,
  edit, clone, import, and restore in Kotlin and Flutter. Restoring a matching connection reuses
  its existing id without changing its name/credentials and remaps dependent records to it.
  Report every skipped backup server and the existing name it matched. Do not silently delete
  or merge pre-existing duplicate rows.

- Run `./scripts/local-pr-check.sh --full` for every build-affecting final tree before committing
  or pushing it. `--quick` is only an intermediate check.
- Never describe a suite as passing when Gradle excluded or skipped part of it. Name every
  platform-specific exclusion and the later gate that covers it.
- Keep `scripts/local-pr-check.sh` and `.github/workflows/android-pr-check.yml` aligned whenever
  build, test, lint, migration, SBOM, signing-input, or dependency-verification behavior changes.
- Run `git diff --check` and `git diff --cached --check` before committing.

## Monitor every PR head to completion

- After every PR push, monitor all checks for that exact head until every check has reached a
  terminal state. A successful push is not completion, and pending checks must not be handed off
  as though the PR were green.
- If any check fails, inspect the exact failed job and its logs before editing. Distinguish source
  or test failures from runner, memory, dependency-verification, signing, artifact, SBOM,
  release-only, and security-analysis failures.
- Fix the cause, validate the final tree locally, push a new head, and monitor the replacement run
  through completion. Do not rerun an unchanged failed workflow.
- Treat the PR as incomplete until the exact final head passes Build & Test, Room migrations,
  release SBOM generation, CodeQL, dependency review, Scorecard/repository security checks, and
  every platform/release job selected for that PR.
- Record any genuinely unavailable external/platform validation explicitly; never silently treat
  a skipped, cancelled, superseded, or unstarted job as passing.

## Open every affected screen on a real Android runtime

- JVM tests are not evidence that an Android screen opens. For UI, parsing, or state read by UI,
  install the debug APK on API 34+ and open every reachable affected screen.
- Use the repository-controlled disposable SSH fleet (`scripts/test-hosts.sh up`) and
  `E2eLabHostProvisioner`, never personal or production hosts.
- `E2eAppSurfaceStressTest` is the required route/subtab/theme/rotation sweep. Pass
  `-e omniterm_e2e_surfaces yes` and the fixture SFTP home argument when needed.
- Every `E2e*` suite is opt-in through instrumentation arguments. A plain
  `connectedAndroidTest` skips them while still reporting success; always state the arguments and
  executed/skipped test counts.
- Keep provisioning and exercise in one invocation, or install once and drive instrumentation
  directly, because Gradle reinstalls wipe seeded app data.
- Device-only regression tests must be seen failing for the expected reason on unfixed code.
- Tests must assert against repository fixtures. A personal lab is an override, never the default.

## Keep tests platform-safe

- Keep pure coroutine, parser, ordering, and state-machine guarantees in ordinary JVM tests.
- Exclude Robolectric native-runtime classes during discovery on Linux ARM64; required x86_64 CI
  must exercise them.
- Run the Room matrix on API 29 in required CI and API 35 locally when a KVM-capable host exists.
  API 36/37 remain deferred until a stable emulator newer than 37.1.11 boots them reliably.
- Android regexes use ICU. Escape literal braces/brackets and verify UI-reachable regexes on device.
- Do not wrap production work on real IO/Default dispatchers in virtual-time `runTest`; inject a
  dispatcher or use bounded real-time integration tests.
- Fix synchronization boundaries rather than repeatedly increasing timeouts or rerunning flakes.
- For terminal parsing, replay deterministic sanitized PTY/tmux streams and dispatch on complete
  control sequences.

## Dependency, checksum, and supply-chain policy

- Gradle verification is strict. Keep SHA-256 and SHA-512 checksums for every resolved artifact,
  POM, and module metadata file; never disable verification or add broad trust rules to pass CI.
- For dependency/plugin/catalog/repository/SBOM changes, use
  `./scripts/refresh-verification-metadata.sh --write`, inspect the diff, then run `--verify` with
  forced fresh resolution across buildscript, both app variants, tests, lint, benchmark, and both
  release SBOM graphs.
- Preserve root security substitutions and the trusted-main Dependabot metadata-fixup workflow.
- Inspect Dependabot configuration, open dependency PRs, and update-job policy together. Respect
  compatibility holds and dedicated review for user-visible network/SSH/ads/consent majors.
- Keep Actions pinned to full SHAs and retain dependency review/submission, CodeQL, Scorecard,
  secret scanning, and release SBOM gates.

## Release and publishing safety

- Kotlin and Flutter release selection must remain mutually exclusive through
  `.github/release-engine`.
- Debug publishing stays separate from production, builds reviewed `main`, defaults to dry-run,
  uses only `debug-*` tags, and never uploads to Google Play.
- Published artifacts require the stable environment-scoped key and a successful exact-SHA main
  gate. Verify signature, package ID, version, debuggable state, and SHA-256 before publishing.
- Preserve branch protection, signed commits, required reviews, and required checks. Never weaken
  repository security or protection settings to make a PR pass.
