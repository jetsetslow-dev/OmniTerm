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

## Active

- Terminal scrollback investigation (user report: running the Claude CLI in a session, pasting a
  large prompt, then unable to scroll back through history — both tmux and plain sessions).
  Code-level findings so far: `resyncTmuxScrollbackFor` intentionally no-ops while the pane is in
  the alternate screen; a scrolled-up viewport can also slide when the scrollback cap trims rows
  under heavy streaming (fixed `firstVisibleRow` over a shifting buffer). Needs an on-device
  reproduction with an Ink-style redraw workload before any fix.
- Differential gap audit against the canonical ledger.
- Play Store evidence review (full video re-review, screenshot set, manifest).

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

Next actions in order: (1) reproduce the terminal scrollback report with an Ink-style workload
on the disposable lab; (2) differential gap audit of the stress matrix vs the canonical ledger;
(3) Play Store video/screenshot re-review and manifest; (4) batch push + PR #31 update after the
pre-push audits.
