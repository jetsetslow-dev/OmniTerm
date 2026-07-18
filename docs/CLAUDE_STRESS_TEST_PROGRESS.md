# Claude independent stress-test progress

Last updated: 2026-07-18

Independent, sanitized checklist for the Claude validation/hardening handoff. The canonical
prior-evidence ledger is `docs/E2E_STRESS_TEST_PROGRESS.md`; green work recorded there is not
rerun unless the relevant code changed. No endpoints, usernames, credentials, SSIDs, or device
identifiers appear in this document.

## Completed with evidence

- 2026-07-18: Handoff reconciliation. `AGENTS.md` does not exist in this repository (noted as a
  handoff-prompt discrepancy; the canonical ledger's checkpoint discipline and safety boundaries
  are followed instead). Branch `agent/biometric-cancel-pin-e2e` was clean and current with its
  remote; PR #31 is the open draft follow-up, PR #30 merged as `9f9b276`. Physical test device
  attached over ADB; required PR checks green on the head except "Validate Room migrations"
  pending at reconciliation time.
- 2026-07-18: Biometric race audit (bytecode-level, androidx.biometric 1.4.0-alpha05).
  `BiometricFragment.showPromptForAuthentication` refuses a second dialog while one is showing,
  so two visible prompts cannot race. However `BiometricPrompt` construction rebinds the
  activity-scoped client callback and `authenticate()` unconditionally replaces the retained
  PromptInfo and CryptoObject mid-session — and the app's gate creates a fresh cipher per call,
  so a successful authentication could hand back a never-authorized cipher and be reported as an
  error. Fixed with a single-flight guard in `BiometricCryptoGate` (atomic in-flight claim,
  released on every terminal callback, on synchronous failure, and on finishing-activity destroy
  via `MainActivity.onDestroy`).
- 2026-07-18: Combined app-lock path is deterministically covered by the new opt-in device test
  `E2eAppLockBiometricCancelPinTest` (runner arg `omniterm_e2e_applock_bio=yes`):
  cold start with a generated PIN + app lock + biometrics + zero grace persisted before launch →
  real system crypto prompt (verified via `dumpsys biometric` non-null crypto CurrentSession and
  `dumpsys fingerprint` AuthenticationClient owned by the app package, exactly one operation) →
  three single-flight re-triggers ignored (same requestId, one operation) → Back-key cancel
  (documented as AuthenticationError/user-cancel; the negative button is not reachable by
  accessibility automation on the secure dialog) → still locked → wrong PIN via the real field +
  Unlock button → prompt re-open via the real "Use biometrics" button → cancel → recreation with
  auto-prompt re-fire and cancel → cold relaunch (fresh Activity/ViewModel re-lock from settings)
  → lockout after repeated wrong PINs, correct PIN refused while throttled, deterministic
  throttle reset through persisted settings → typed PIN + IME action unlock → zero-grace
  background/foreground relock → cancel → typed PIN + Unlock button unlock. All original
  settings restored in `finally`; the suite asserts no biometric session remains active.
  Passed 3/3 consecutive runs (95.7 s, 100.5 s, 91.7 s); `CurrentSession: null` after each.
  - Determinism notes: button activations use the OnClick semantics action (gesture taps raced
    the IME-driven layout animation); every phase serializes on authoritative state (biometric
    service session, single-flight release, window focus) — no timing-only passes. Phases that
    immediately follow a cancel plus lifecycle churn converge through the real "Use biometrics"
    button because the fingerprint service can transiently refuse an auto-prompt right after a
    cancellation (observed as silently dropped sessions in BiometricService logs).
- 2026-07-18: Files screen subtab order changed to Bookmarks, SFTP, Shares, Transfers (indices
  0-3). Pull-to-refresh scoping, bookmark navigation targets, the no-online-host fallback (now
  lands on Bookmarks), the server-row SFTP shortcut (now pins the SFTP subtab), and the two
  device suites that referenced the old Shares index were updated. Verified on device: tab row
  renders in the new order and the screen lands on Bookmarks.
- 2026-07-18: Editor cursor-follow fix in `CodeEditor`'s Compose body: the field fills the whole
  scroll content, so Compose's own bring-into-view never moved the ancestor scroll state and the
  cursor could walk off-screen while typing (and hide behind the IME on focus). A viewport-aware
  effect now follows the collapsed cursor vertically (and horizontally when wrap is off) and
  re-runs when the IME resizes the viewport. The native large-file EditText path already followed
  the cursor via `bringPointIntoView`. Regression: `E2eCodeEditorCursorVisibilityTest`
  (arg `omniterm_e2e_editor_cursor=yes`) types past the fold and asserts the cursor rect from the
  field's real TextLayoutResult lands inside the root viewport — passed on device in 8.5 s.
- 2026-07-18: Focused unit regressions green: `CodeEditorTest`, `ColdStartRobolectricTest`,
  `TerminalNavigationRobolectricTest`.

- 2026-07-18: Terminal field reports (Claude CLI in a session: history unscrollable, input dead
  after a few idle seconds) reproduced and fixed via the new opt-in device suite
  `E2eTerminalScrollHistoryReproTest` (arg `omniterm_e2e_scroll_repro=yes`, VM-level against the
  disposable lab, Ink-style cursor-up/erase redraw workload):
  - Root cause of the "idle" input death: `pasteText` wrapped the ENTIRE payload — including the
    trailing Enter — in bracketed-paste markers. Readline treats everything inside
    `ESC[200~…ESC[201~` as literal, so the pasted command was echoed but never executed. It only
    ever worked in the first seconds after connect, before the prompt's `?2004h` had been
    processed — which users perceive as "input breaks after idling", in and out of tmux. The
    IME's multi-line commit path funnels through the same paste. Fixed by sending trailing CRs
    after the closing marker (`bracketedPastePayload`, unit-tested in
    `BracketedPastePayloadTest`); interior newlines stay literal as the mode intends.
  - History integrity under an Ink-style workload verified at the emulator level for plain and
    tmux sessions (early history + transcript retained live and across the capture-pane resync;
    scrollback populated). The repro also covers typing after 7 s and 10 s idles with a resync
    between. Passed 2/2 after the fixes (47.1 s, 47.2 s).
  - Residual scroll defect found by analysis and fixed: with the scrollback cap reached, every
    streamed line trims a head row, so a scrolled-up viewport's absolute anchor slid toward the
    tail ("can't scroll up while output floods"). The emulator now counts linear head evictions
    (`trimmedRowCount`, excluded during reflow/adoption which re-anchor on their own), snapshots
    carry the counter, and ShellScreen shifts the anchor by the trim delta while scrolled up.
    Unit coverage in `TerminalEmulatorTest.trimmedRowCountTracksOnlyLinearHeadEvictions` and
    `TerminalViewportStateTest.capTrimDriftShiftsAnchorSoContentStaysStationary`.

- 2026-07-18: Differential device reruns for every suite my changes touched, all green after two
  environment/harness fixes: E2eTerminalStressTest (112.7 s), E2eTerminalNavigationMatrixTest
  (52.2 s), E2eFilesUiStressTest (69.0 s — first attempt failed only because earlier rotation
  churn had left the physical device in landscape, pushing the created row below the LazyColumn
  fold; portrait restored via settings), E2eFileTransferLifecycleStressTest (81.7 s),
  E2eAppSurfaceStressTest (61.7 s — its loader start-edge await polled at 100 ms and missed the
  sub-poll loading pulse of warm pooled-SSH lab loads; the start edge now polls at 1 ms and the
  SFTP phase awaits the applied listing outcome). Unchanged-code suites keep their canonical
  ledger evidence.
- 2026-07-18: Play Store evidence complete. The sanitized foreground-service video was
  re-reviewed end to end (ffprobe metadata: encoder tag only; SHA-256 matches the ledger entry;
  all 16 per-second frames plus both transitions inspected at full resolution — disclosure,
  system permission dialog, and OmniTerm-only notification shade; nothing sensitive). The three
  existing policy screenshots re-reviewed at original resolution. Five new store screenshots
  (dashboard, split terminal, Compose builder, alerts, remote files) generated by the new opt-in
  `E2ePlayStoreScreenshotFixture` using only synthetic identities (RFC 5737 addresses, demo
  container `demo@atlas-prod` on the disposable lab, fictional stack/alerts); every asset passed
  two privacy reviews; 24-bit PNG at 1080×1920 per current Play requirements (verified
  2026-07-18). Manifest with SHA-256, dimensions, slots, and review results at ignored
  `artifacts/play-store/MANIFEST.md`. Fixture cleanup restores server rows, alerts, settings,
  and removes the demo container; device DB verified clean afterwards.

## Active

- (none)

## Blocked / limitations

- The biometric prompt's negative ("Cancel") button cannot be activated by any accessibility or
  screenshot automation because the system dialog is deliberately shielded; Back-key cancellation
  is used and delivers the same AuthenticationError terminal callback. Recorded as the closest
  authoritative substitute, per the platform-security note in the canonical ledger.

## Cleanup / release handoff

- App-lock/biometric settings are snapshot-and-restored inside the new suite itself; after each
  run the device has its original lock state and no active biometric session.
- Disposable-lab namespaces created during this campaign must be removed once their evidence is
  no longer needed; the public production host remains read-only and untouched.
- Batch all pushes; audit `origin/main...HEAD` plus history and run pinned Gitleaks before each
  push.
- Supervisor: `secrets/claude-stress-resume.sh` (ignored) resumes the campaign from the saved
  prompt, parses usage-limit resets or backs off 5/15/30/60 min, caps identical non-limit
  failures, and terminates on `secrets/CLAUDE_STRESS_TEST_COMPLETE`.

## Resume point

Remaining: pre-push gate (full unit suites, both lints, `git diff --check`, signature
verification, pinned Gitleaks, `origin/main...HEAD` secret/privacy audit), one batched push, and
the PR #31 body update; then confirm required checks on the final head. Campaign-teardown items
that stay open until the user closes the campaign: restore `flag_secure` to its secure default
(it remains "false" from the lab seed for capture evidence) and sweep any remaining disposable
lab fixtures (the screenshot fixture already removes its own `omniterm-demo` container).
