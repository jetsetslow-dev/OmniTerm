# Kotlin / Flutter reliability review — temporary branch tracker

## October 7: Smart IME input parity — local/runtime validation complete; replacement CI pending

- Ordinary guards reproduced dropped sticky Ctrl/Alt/Shift, Unicode suffix replay, stale composition after on-screen Enter/Tab/arrows, read-only and split focus changes, and delayed old-pane input reaching the newly focused host. Twelve guards failed on the original production code for the expected reasons; the unrelated-output preservation guard passed. A focused API 35 test also proved that Ctrl+C actually sent byte 99 to the disposable SSH fixture instead of byte 3.
- Flutter now routes modifier commits through the existing typed-text encoder, extracts only the inserted fragment using Kotlin's Unicode-safe UTF-16 growth policy, and consumes modifiers once. The focused input owns a synchronous reset callback for shell-owned keys/typing. Focus/read-only changes clear composition, delayed focus effects are rejected, and inactive/disconnected/read-only input cannot redirect a commit. Unrelated output keeps the composing word. Kotlin already implements these input rules; its validated branch is unchanged by this batch.
- All 200 focused ordinary screen, view-model and input cases passed, zero skips. The same focused native test passed one case, zero skips, verifying eight actual SSH byte captures for modifiers, Unicode, special keys and read-only transitions. It uses the existing repository fixture and bounded raw-byte collector; `smart-ime` selects this case within the terminal lifecycle suite. Normal host coverage selects both lifecycle cases. No personal host or credentials are part of the tracked evidence.
- Reproduce ordinary coverage with `cd flutter_app && flutter test test/shell_screen_test.dart test/shell_view_model_test.dart test/terminal_input_test.dart`. Runtime coverage uses repository fixtures from `./scripts/test-hosts.sh up` and `./scripts/flutter-device-test.sh --device <API35-device> --profile host`, followed by `--profile surface`.
- Final `./scripts/local-pr-check.sh --full` passed: 2,870 Flutter host cases with seven optional fixture skips, clean analyzer and formatting of 410 files, release APK/AAB/runtime SBOMs, all-ref secret scanning and strict fresh project/release/compile verification. Unchanged companion unit/lint tasks reused existing results; each variant reports 570 passing cases with two optional external-capture skips. Fresh API 35 instrumentation executed 24 passing cases with 36 opt-in E2E assumptions unexecuted and actual runner exit zero.
- The subsequent host test stopped at the runtime probe because the disposable fixture retained stale Docker/Podman state after a machine reboot; that attempt is not counted as passing. Only fixture temporary runtime state was repaired, preserving persistent data. After fixture recovery, the final API 35 host profile passed one plain case plus both native terminal lifecycle/Smart IME cases, zero skips, with six known upstream warning lines and no unexpected warnings. Android logs verify all eight expected byte captures and no fatal exception. Final API 35 surface coverage also passed both cases, zero skips, including the route/subtab/theme/text-scale/rotation sweep; four known upstream warning lines and zero unexpected warnings.
- The normal `lib/main.dart` debug APK is archived at `artifacts/flutter-builds/20261007-smart-ime/OmniTerm-Flutter-debug.apk`, SHA-256 `e3e943a5d09070888468a1bd60adba8e8d4009e5719b633becfe2542ac100b47`. Package/version, expected debug certificate, debuggable state and absence of native test entrypoints were verified. It installed and opened on the disposable API 35 device; installed hash matched the archive and no fatal exception was recorded. The existing ordinary device data was preserved. All five frozen production/test fingerprints still match the completed full gate. This batch's replacement CI remains pending; broader parity remains open and no merge or release is authorized.

## October 7: native navigation fixture isolation — both checkpoints complete

- The exact failed PR #92 native job and uploaded unit results were inspected before editing: the empty-host navigation test expected SFTP but stayed on Infra. It constructed an AppViewModel against shared Room data without clearing prior hosts or cancelling its scope in teardown. A persisted offline host makes Infra subtabs available as soon as the host flow publishes and selects it.
- A controlled before run seeded a synthetic offline host and reproduced the exact SFTP/Infra failure. The fixture now clears Room before constructing its ViewModel, owns that model through a ViewModelStore and drains Main while waiting for cancelled IO continuations to finish. Navigation assertions and production behavior are unchanged. All thirteen navigation cases passed in each variant, zero skips; the contaminated-data after case passed with zero skips.
- Final `./scripts/local-pr-check.sh --full` passed: each companion native variant executed 570 passing cases with two optional external-capture replay cases skipped; both lints, 410-file formatting, analyzer, 2,857 Flutter host cases with seven optional fixture skips, release APK/AAB/runtime SBOMs, all-ref secret scanning and fresh strict project/release/compile verification succeeded. Fresh API 35 instrumentation executed 24 passing cases, with 36 opt-in E2E assumptions unexecuted and actual runner exit zero. Both previously verified normal APKs were restored, opened and checked against their archived hashes without a fatal exception.
- The matching test-only fix is signed/pushed on `kotlin-bug-fixes` as `dd9f1a6`. All fifteen exact-head PR #112 contexts are terminal: ten successes, four unselected companion skips and one neutral annotation. Native build/test, API 29 Room migrations, release SBOMs, actual CodeQL and selected security checks succeeded.
- Flutter `feec539` finished all twenty-five hosted contexts: twelve successes, ten skips, two failures and one neutral annotation. The native navigation failure is repaired by this checkpoint; the selected Room/SBOM successors of that failed build did not execute. Its emulator ran all 27 plain core cases successfully, then failed all three native picker cases, zero skips. Later native entrypoints did not execute. Android logs show the notification prompt and restore picker opened, while native automation could not find either window. Export stayed pending on the unanswered permission prompt. This head is not green.
- The same unchanged three-case picker suite passed on fresh API 35 fixtures under both emulator 37.2.12 and 37.1.11, zero skips each. A controlled replay of the complete hosted core sequence also passed all 27 plain and eight native cases, zero skips, with 26 known upstream warning lines and no unexpected warnings. Android's permission-window snapshot confirmed that the native automation could observe the opened prompt. Neither a version-only nor preceding-test failure reproduced locally. Production picker behavior, native assertions, deadlines and workflow selection remain unchanged. No unchanged failed workflow rerun.
- Signed Flutter checkpoint `f1b9be6` completed all twenty-five exact-head PR #92 contexts: sixteen successes, eight unselected companion skips and one neutral annotation. All selected native build/test, API 29 Room, release SBOM, CodeQL/security, Flutter host/release/iOS and hosted Android end-to-end checks passed. The earlier native-window failure did not reproduce in either focused local comparison, the full local sequence or the replacement hosted run. No speculative emulator/workflow change was made.
- Reproduce navigation coverage with `./gradlew testOpenSourceDebugUnitTest testPlayStoreDebugUnitTest --tests com.jetsetslow.omniterm.TerminalNavigationRobolectricTest`; final verification uses `./scripts/local-pr-check.sh --full`. This navigation checkpoint and the preceding reboot/container fixes are complete on both branches. Broader authorized parity remains open. No merge or release is authorized.

## October 4: native backup-picker test synchronization — signed checkpoint; hosted native fixture repair pending

- All 25 exact-head contexts on Flutter `03f81b4` reached terminal states: 15 succeeded, eight unselected companion jobs skipped, one neutral Scorecard annotation and one failed Android emulator job. Native build/test, API 29 Room, release SBOMs, CodeQL, Flutter host/release/iOS and selected security checks succeeded. The existing alert-deletion repair passed its hosted five-case suite; the required surface sweep also passed. The emulator later failed the first native backup save/cancel case after notification denial, while the filename and restore/cancel cases passed. Later native entrypoints did not execute and are not counted as passing.
- The exact failed job and its retained runtime evidence were inspected before editing. During the 20-second Android visibility wait, the document picker never launched. Animation settling can return before the permission result and subsequent database reads finish; polling only Android cannot establish that Dart has completed those reads. The save tests now pump Flutter while awaiting the export's actual start/completion, reject export errors, then inspect the real native picker using the remainder of the same 20-second budget. Native cancellation, filename and usable-button assertions remain. Production backup code and workflow selection are unchanged; no unchanged workflow rerun.
- The original three-case native picker suite passed locally, which does not erase the hosted failure. The corrected focused picker suite passed three cases, zero skips. The final `./scripts/local-pr-check.sh --full` passed: 2,857 Flutter host cases with seven optional fixture skips (six setup/latency cases and one compression case), clean analyzer/formatting of 410 files, release APK/AAB/runtime SBOMs, fresh strict project/release/compile verification and all-ref secret scanning. Unchanged companion native unit/lint tasks reused their existing results; fresh API 35 instrumentation executed 24 passing cases, with 36 opt-in assumptions not executed and actual runner exit zero.
- The complete API 35 `./scripts/flutter-device-test.sh --device <device> --platform android --profile core --no-fixtures` passed all 27 plain cases and eight native Patrol cases, zero skips. All ten plain and five native core entrypoints executed, including the required route/subtab/theme/text-scale/orientation sweep, native save/cancel/filename/restore picker, enrolled biometric prompt, notification permission denial/grant and both Settings suites. There were 26 known upstream warning lines and no unexpected warnings. Docker/Podman fixture evidence remains recorded for the unchanged production code above; host-dependent entrypoints are selected by the separate host profile.
- The normal `lib/main.dart` debug APK was checked for package/version, debuggable state, expected development signature and absence of integration/Patrol entrypoints, archived at `artifacts/flutter-builds/20261004-picker-sync/OmniTerm-Flutter-debug.apk`, installed and opened on API 35 without a fatal exception. SHA-256: `66b14fcb0b7c3c041ffe82d1cbfe04cd026b27206a4f0a63c098f1627b26a859`. Both normal Kotlin and Flutter APKs were restored after testing and their installed hashes matched their archives. Twenty frozen source/test hashes still matched when rechecked on October 7.
- Publishing access was restored on October 7. The completed local/runtime/artifact gates and twenty frozen source/test hashes were reverified, final staged diff/secret checks passed, and signed checkpoint `feec539` was pushed to PR #92. Hosted Flutter analysis/test, release artifacts, iOS, actual CodeQL and security checks succeeded. Native Build & Test failed an existing shared-database navigation fixture; its selected Room/SBOM successors did not execute. The emulator later failed native window discovery; all contexts and the retained runtime evidence were inspected as recorded above. No unchanged workflow rerun.
- Broader authorized Kotlin/Flutter parity remains open. No merge or release is authorized.

## October 4: container actions without Compose — signed checkpoints; Flutter emulator repair pending

- Expanded stack rows now expose actions for each exact container ID on its own Docker/Podman runtime. Start, Stop, Restart, Pause, Unpause and Remove bypass Compose; Logs, Follow logs and Shell also target the container directly. Service Stop/Restart/Remove act on only the current replicas for that runtime/project/service, with explicit “all containers” wording. Stack lifecycle and Scale still use Compose and report missing definitions.
- Per-container confirmation names its target, preserves other replicas/volumes and rejects a changed selected host or missing container. Actions keep the existing pending/output/error panel and refresh actual runtime state. Container identity survives service grouping; missing Compose metadata no longer hides individual controls. Large-text menu overflow cues and pinned confirmation actions are covered in ordinary Flutter widgets.
- Before fixes, ordinary Flutter Docker/Podman service-stop checks and a shared per-container widget contract failed on the previous command/menu routes. Kotlin's ordinary streaming regression and the actual unfixed API 35 app also failed: deleting the test-owned Compose file left both replicas running after Stop. Kotlin final Docker API 35 coverage passed four selected cases including the required surface sweep; Podman passed three selected cases. Both had zero skips. Kotlin full verification, normal APK validation and signed checkpoint publishing are complete as `e99bb3d`; all 15 exact-head PR #112 contexts finished: ten success, four unselected skips and one neutral annotation. Build & Test, API 29 Room migrations, release SBOMs, CodeQL and the selected security checks succeeded. Flutter affected host coverage passed 155 cases, zero skips. The final Flutter full gate passed 2,857 host cases with seven optional fixture cases skipped (six setup/latency checks and one compression check), analyzer/formatting (410 files, zero changes), release APK/AAB/SBOM generation and fresh strict project/release/compile verification. Fresh companion API 35 instrumentation ran 24 passing cases with 36 opt-in assumptions not executed and actual runner exit zero. Final API 35 host and surface profiles, five explicit action cases and the normal debug APK checks passed. Signed/pushed Flutter head `03f81b4` completed all 25 hosted contexts: 15 success, eight unselected skips, one neutral and one failed emulator job; see the picker repair above.
- The first native full gate failed an existing tmux reboot regression in the Play Store variant. Its fake presence check reported an unreachable host while background authentication/reconnect still claimed success, contradicting the fresh-SSH rule under load. The fake transport now consistently refuses all SSH paths once that scenario marks the host unavailable; production reboot logic is unchanged. All five focused tmux cases passed in each Kotlin variant with zero skips. The replacement native full gate passed both variants (578 passing cases and two optional capture diagnostics skipped each), both lints and fresh strict verification. Fresh plain API 35 instrumentation ran 24 passes with 35 opt-in assumptions not executed; the selected runtime/surface invocations separately covered the container UI.
- Podman's disposable fixture runs without cgroups and explicitly refuses pause. That capability was confirmed with a test-owned diagnostic container. Pause/unpause remain covered by pure command checks and Docker runtime; the Podman runtime case requires Stop/Start/Restart/Remove and does not claim pause coverage. The first Podman exercise failed at the extra pause assertion; final Kotlin Podman isolation/lifecycle validation passed three selected cases, zero skips. Final Flutter Podman Stop/Start/Restart/Remove, direct logs and replica isolation passed after deleting the owned Compose file; no Podman pause coverage is claimed. All runtime actions use repository fixtures and exact test-created IDs for cleanup.
- The first Flutter host profile failed with an actual Android `ForegroundServiceDidNotStartInTimeException`: `stopService` cancelled a pending foreground start before its acknowledgment. A real-bridge stop/restart burst reproduced the same crash on unfixed code. Stops now queue behind starts, and `stopSelfResult(startId)` prevents an older stop from cancelling a newer queued sync. Corrected API 35 host validation passed the deleted-file Docker/Podman isolation and real-bridge stop/restart regression; the native Patrol case passed Home/background, activity recreation and notification lifecycle coverage. Both selected cases passed, zero skips, with only six known upstream warning lines and no unexpected warnings. The replacement full gate and final selected host/surface/actions/normal APK stages passed; the earlier failed run is not counted as passing.
- Terminal checkpoint `414c99f` was signed and pushed. All 25 PR #92 contexts finished: 15 success, eight unselected skips, one neutral, one failed Android emulator job. The exact failed log showed the existing alert-deletion case checking its empty state before SQLite published deletion. Its test now identifies only the newly created rule and waits for that exact row to disappear; the result assertions remain. Remaining device suites after the failed case did not execute and are not counted as passing. A locally validated replacement head and all its selected checks are required; no unchanged workflow rerun.
- Final API 35 host profile passed one plain fixture case and one native Patrol lifecycle case, zero skips, with nine known upstream warning lines and no unexpected warnings. It exercised deleted-file Docker/Podman individual controls, Cancel, sibling preservation, direct logs, whole-stack missing-file errors, real foreground-service stop/restart bursts, all four share protocols and SSH/tmux activity/background/notification lifecycle. Docker pause/unpause executed; Podman pause/unpause was not selected because the fixture has no cgroups.
- Required final API 35 surface profile passed both cases, zero skips, with four known upstream warning lines and no unexpected warnings: short-viewport recovery, every route/subtab, five color schemes, text scales 80/100/150/200% and both orientations. The separate `app_actions_test.dart` invocation passed all five cases, including exact alert-row deletion and subsequent empty-state verification.
- The normal `lib/main.dart` debug APK was verified for package/version, debuggable state, expected development signature and absence of the Patrol/integration entrypoint; it was archived at `artifacts/flutter-builds/20261004-container-actions/OmniTerm-Flutter-debug.apk`, installed and opened on API 35 without a fatal exception. SHA-256: `414ca89e51ebc795e33884f491f9dac18271a437080d08951e2b80226dc0495d`.
- Reproduce the final tree with `./scripts/local-pr-check.sh --full`, then repository-fixture API 35 `./scripts/flutter-device-test.sh --device <device> --profile host` and `--profile surface`, plus `flutter test integration_test/app_actions_test.dart -d <device> --reporter expanded`. Use the configured SDK/JDK/Flutter environment; do not use personal hosts. A physical Samsung and local iOS runtime are unavailable here; selected hosted platform checks remain required.
- Flutter container head `03f81b4` is signed/pushed; its emulator failure requires a validated replacement head and every selected check on that head. Kotlin container head `e99bb3d` is signed/pushed with all 15 exact-head contexts terminal (ten success, four unselected skips, one neutral). Broad Flutter parity remains open; no merge or release is authorized.

## October 3: terminal runtime options — local validation passed; signed checkpoint requires Android CI repair

- Flutter OPT and terminal long press now open the same centered options dialog. Paste and both Visible screen / Full buffer actions stay outside its scrolling runtime controls; overflow cues show hidden content before a gesture. Range choices open the existing selectable transcript at the chosen range, retaining its copy/export/clear controls and focus restoration.
- Runtime Swipe-typing changes the terminal keyboard and edit path without saving Settings. It follows a genuinely changed saved default, preserves overrides through unrelated app updates and clears stale composition only when the runtime mode changes. Keep screen on uses the acknowledged platform helper with pending/error/retry feedback and bypasses the separate battery warning, matching the explicit runtime opt-in.
- Clipboard reading, large-paste confirmation and transport writing remain visibly pending. Empty clipboard, cancellation, changed pane/channel, unresolved tmux pane and failed writes produce explicit results. A targeted paste cannot redirect to another session or replacement channel; completion waits for the transport write. Read-only mode disables menu paste. Software-keyboard paste also exposes preparation and cancellation feedback.
- Ordinary regression evidence captured the missing runtime menu and premature success on a failed transport write. All 214 affected host cases passed across Shell widgets, view model, session and transcript suites, including large text in portrait/short landscape, overflow cues, copy ranges, clear confirmation, saved/runtime independence and focus/keyboard restoration. The first full gate passed analyzer, formatting of 409 tracked Dart files with zero changes, 2,847 Flutter host cases with seven optional fixture skips (six setup/latency checks and one compression check), release APK/AAB/SBOM, strict fresh verification and all-ref secret scanning. Unchanged native unit/lint reused their existing results; fresh native API 35 XML showed 24 executed cases and 36 opt-in assumptions, no real failures and runner exit code zero. After the device-test synchronization edit below, the replacement final full gate passed all required local checks, including strict fresh verification and fresh native API 35 XML with the same 24 executed / 36 opt-in assumption counts. Native unit/lint were UP-TO-DATE; their unchanged results were reused, not rerun.
- The first API 35 host run reached the menu and enabled Swipe-typing, then failed restoring it because the test tapped again after the synchronous model change but before the controlled switch rebuilt. The test now waits for the rendered switch value (and an enabled awake callback) before its next tap. The replacement full gate and both Android profiles passed on the final tree. `./scripts/flutter-device-test.sh --device <API35-device> --profile host` executed one plain SSH/runtime/share case and one native Patrol lifecycle case, zero skips and no unexpected warnings (six known upstream lines). It exercised plain SSH, tmux/control mode, runtime switches and actual clipboard bytes using repository fixtures. `--profile surface` executed two plain cases including the required route/subtab/theme/text-scale/rotation sweep, zero skips and no unexpected warnings (one known upstream line). Other Flutter core suites await selected exact-head CI.
- A supplementary API 35 exercise also opened large-paste and clear confirmations in physical portrait and landscape at 200% text size, checked reachable actions/overflow cues and cleared local history. One case passed with zero skips. Its temporary validation entrypoint was removed from the final tree. The test explicitly hides the IME before rotation: the compact terminal header is intentionally hidden while the keyboard occupies landscape height. Earlier exercise failures were harness surface/gesture synchronization; they did not alter production code.
- The normal Flutter debug APK was verified for signature, package/version/debuggable state and absence of a test entrypoint, archived at `artifacts/flutter-builds/20261003-terminal-runtime-options/OmniTerm-Flutter-debug.apk` with SHA-256 `6c5cd9e9b8d824a08e82a59799a67968ddc4d2f8e85062d3efa7404488110c92`, installed and opened on API 35 without a crash-buffer fatal error. Eleven production/test file fingerprints matched the validated tree. Signed checkpoint `414c99f` was pushed; its failed Android action test and required replacement validation are recorded above.
- Kotlin's existing options layout still needs the matching pinned-action placement review. Dialog sizing/fonts/close behavior and selectable-transcript shape also need comparison. Smart IME sticky-modifier handling and composition reset across pane focus/read-only changes remain audit items; this checkpoint does not claim complete keyboard parity. Empty split panes, two-host selection and the broader exact visual/functionality audit remain open. The subsequent Docker container fix and its completed local/runtime validation are recorded in the October 4 section above; Flutter exact-head hosted checks remain pending. No merge or release is authorized.

## October 3: Keep screen on platform feedback — signed checkpoint and exact-head CI complete

- Flutter's global toggle now waits for the platform setter before changing the acknowledged enabled state. Writes from saved defaults or battery saver serialize behind pending work, so the most recent requested state is applied last. Duplicate user taps are disabled while pending; a completion after disposal cannot notify or start another write.
- Portrait, landscape and compact terminal layouts show indeterminate progress during the platform write. Failure preserves the last acknowledged state and exposes Retry/Dismiss actions. The enabled bulb is the completed result. This helper supports the terminal runtime menu implementation under validation above.
- Two ordinary host regression guards failed on the prior implementation: enabling and disabling both advertised completion before platform acknowledgment. A third ordinary guard caught a long-error overflow in a short landscape viewport. The compact error row now keeps details, retry and dismiss reachable; the full error opens a scrollable dialog with visible overflow cues and a pinned Close action. All 23 affected state, feedback-widget and battery-saver cases pass with zero skips. The same error-dialog contract joins the real-engine surface sweep.
- Required corrected final-tree `FLUTTER_BIN=<flutter> ./scripts/local-pr-check.sh --full` passed: 2,834 Flutter host cases with seven optional fixture skips (six setup/latency and one compression), analyzer, 407 tracked Dart files formatted without changes, release APK/AAB, both SBOMs, all-ref secret scanning and strict fresh project/release/compile verification. Unchanged native companion unit/lint results were up to date (570 JVM cases passed per variant; two optional external terminal-capture diagnostics skipped). Fresh API 35 companion instrumentation executed 24 cases and skipped 36 opt-in assumptions, with zero real failures and runner exit code zero.
- Final API 35 `./scripts/flutter-device-test.sh --device <API35-device> --profile surface` passed two plain cases: the same portable short-viewport error-dialog contract and the route/subtab/theme/text-scale/rotation sweep. Zero skips and no unexpected warnings (one known upstream line). The profile opened the full error dialog on the real Flutter engine, verified the initial overflow cue and kept Close discoverable. Other Flutter core suites were not repeated locally for this change; selected replacement CI covers them. All work used repository fixtures.
- Ordinary `lib/main.dart` debug APK: `artifacts/flutter-builds/20261003-keep-screen-on-runtime/OmniTerm-Flutter-debug.apk`, SHA-256 `90c434dc0ab2a20489741e159f65ced48e2e1c761f4520bcdcc2d23a7ab15156`. Package/version, expected debug certificate, debuggable state and absence of the Patrol entrypoint were verified. It was restored and opened on API 35 with no recorded fatal error. Actual UI actions enabled it in portrait and disabled it through the scrolled landscape navigation rail; Android Activity `FLAG_KEEP_SCREEN_ON` matched off → on → off, and the portrait toggle showed the final disabled result after returning. Code/test fingerprints still match the validated tree.
- The terminal runtime menu is under validation above. Empty split panes, the two-host picker and broader parity work remain open. No merge or release is authorized.

- Signed/pushed helper head `d29a1e6` completed all 25 exact-head contexts: 16 SUCCESS, eight unselected SKIPPED and one NEUTRAL. Actual hosted logs show 2,834 host cases with seven optional skips and 27 plain plus eight Patrol emulator cases, zero skips and no unexpected warnings (31 known upstream lines). No pre-test NoTestsRan event occurred. Selected native Build & Test, API 29 Room execution, release SBOM generation, iOS archive and actual CodeQL analysis/SARIF upload passed.

## October 3: terminal read-only parity — signed checkpoint and CI complete

- Kotlin applies its runtime read-only mode to all panes and later connections. Flutter's header now updates every session, clears armed Ctrl/Alt/Shift state, and permits enabling View mode before connecting. New sessions inherit the mode before becoming visible; held session input is cancelled through the existing session guard. Turning Input mode back on restores all sessions together. This is runtime state, not a saved preference.
- Two ordinary widget guards failed before the repair: the other split pane stayed writable, and View mode could not be enabled from the connection prompt. All 183 affected shell/view-model/service/host-selector tests passed after the repair.
- Final `FLUTTER_BIN=<flutter> ./scripts/local-pr-check.sh --full` passed: 2,823 Flutter host cases, analyzer/format, native companion unit/lint, release APK/AAB and both SBOMs, all-ref secret scanning and strict fresh project/release/compile verification. Seven optional Flutter cases were skipped: six setup/latency fixture checks and one compression fixture check. Each native companion variant executed 570 JVM cases with two optional external terminal-capture diagnostics skipped. API 35 companion instrumentation executed 24 cases and skipped 36 opt-in assumptions, with no real failures and runner exit code zero.
- Final API 35 `./scripts/flutter-device-test.sh --device <API35-device> --profile host` passed one plain SSH/runtime/share case and one native Patrol terminal layout/Home/background/tmux retention case, zero skips and no unexpected warnings (six known upstream lines). Separate `--profile surface` passed its eight-minute route/subtab/theme/text-scale/rotation sweep, one plain case, zero skips and no unexpected warnings (one known upstream line). Other Flutter core suites were not repeated locally for this change; selected replacement CI must cover them. All runtime work used repository fixtures.
- The normal `lib/main.dart` APK is archived at `artifacts/flutter-builds/20261003-terminal-global-readonly/OmniTerm-Flutter-debug.apk`, SHA-256 `5de276bb9ec5c71002f2fe8123f4fc4b0d7b54bc27713228bb92886c90d28256`. Package/version, expected debug signature, debuggable state and absence of the Patrol entrypoint were verified. After the surface suite, this immutable APK was restored and opened on API 35 with no recorded fatal error. Validated source/test fingerprints still match.
- Signed read-only checkpoint `fa29b53` has all 25 PR #92 contexts terminal: 16 success, eight unselected companion skips and one neutral result. Hosted host tests passed 2,823 cases with seven optional skips. Hosted Android core coverage passed 26 plain and eight native Patrol cases, zero skips and no unexpected warnings (32 known upstream lines). The walkthrough initially failed to start before any tests ran; the existing runner rebooted its disposable emulator and the completed retry executed all seven walkthrough cases. This was a pre-test transport recovery, not a workflow rerun. Native Build & Test, selected API 29 Room migration execution, release SBOMs, iOS build and actual CodeQL analysis/SARIF upload also passed. Full parity still requires the runtime options menu, empty split-pane editor and two-host picker, plus the broader work recorded below. No merge or release is authorized.

## October 3: terminal header parity — signed checkpoint and CI complete

- Kotlin's two-row header is the reference: TERM/P1/P2, host identity, CURRENT/FOCUSED, OPEN, BG/LEAVE, SPLIT or layout/SINGLE, INPUT/VIEW, OPT, RECON and DISC. Flutter now uses these controls with the existing SSH, tmux recovery and transcript actions. Header surface colors and action sizing follow the app theme independently of the terminal palette.
- OPEN groups current, background and resumable sessions, then New and entitled Quick Connect. Session ages update while the menu is mounted. Host changes confirm detaching/backgrounding first. Plain BG retains its channel and awaits foreground-service protection, including startup already in flight; tmux LEAVE preserves transactional recovery. Busy states and errors remain visible.
- Three ordinary regression guards failed before the fixes: absent header actions, split-pane movement when focus changed, and premature completion during foreground-service startup. Stable pane order now follows a separate first-pane identity. A saved-session landing overflow scrolls its description and responsive actions together. All 182 affected tests passed, including large phone text and popup overflow cues.
- Final `FLUTTER_BIN=<flutter> ./scripts/local-pr-check.sh --full` passed: 2,822 Flutter host cases, analyzer/formatting, native companion unit/lint, release APK/AAB and both Flutter SBOMs, all-ref secret scanning and strict fresh project/release/compile verification. Seven optional Flutter cases were skipped: six setup/latency fixture checks and one compression fixture check. Each native companion variant executed 570 JVM cases with two optional external terminal-capture diagnostics skipped. API 35 companion instrumentation executed 24 cases and skipped 36 opt-in assumptions, with no real failures and runner exit code zero.
- Final Flutter API 35 `./scripts/flutter-device-test.sh --device <API35-device> --profile all` passed 27 plain integration cases and nine native Patrol cases, zero skips and no unexpected warnings. Coverage included the eight-minute route/subtab/theme/text-scale/rotation sweep, repository SSH/runtime/share fixtures, terminal Home/background/tmux retention and enrolled biometric lifecycle flows. The first device attempt found an outdated single-host-label assertion; it now checks the keyed header identity and retains error/Retry checks. The complete full gate and device suite passed after that repair. Only 26 known upstream warning lines remained.
- The ordinary `lib/main.dart` debug APK is archived at `artifacts/flutter-builds/20261003-terminal-header/OmniTerm-Flutter-debug.apk`, SHA-256 `54121b56b6a08578568b5b06ddfab4a2e3ab8dcbe0d4b5077fa767e63dd3e487`. Package/version, expected debug signature, debuggable state and absence of the Patrol entrypoint were verified. It installed and opened on API 35 with no recorded fatal error. The reported Samsung Android 16 device is not locally connected.
- Signed/pushed head `3b3bfc3` completed all 25 PR #92 contexts: 16 successful, eight unselected companion jobs skipped and one neutral annotation. Hosted emulator coverage passed 26 plain integration cases and eight native Patrol cases, zero skips and no unexpected warnings (31 known upstream warning lines). Native Build & Test, API 29 Room migrations, native release SBOMs, actual CodeQL analysis/upload, Flutter host/release/iOS and selected security gates succeeded. This checkpoint does not establish full UI parity: empty split-pane editing, two-host selection in the host picker, additional runtime terminal options remain. No merge or release is authorized.

## October 3: server reboot, tmux selection and trustworthy health

- Kotlin fixes are signed and pushed as `83c616f` on `kotlin-bug-fixes`, draft PR #112. All 15 exact-head check contexts are terminal: ten successful, four unselected companion jobs skipped and one neutral Scorecard annotation. Build & Test, API 29 Room migrations, release SBOMs, CodeQL and selected security gates succeeded.
- Flutter fixes use `migration-to-flutter`, draft PR #92. Prior checkpoint `829c907` completed all 25 check contexts: 16 successful, eight unselected companion jobs skipped and one neutral annotation. Signed Flutter head `42abc67` also completed all 25 check contexts: 16 successful, eight unselected companion jobs skipped and one neutral annotation. Hosted emulator coverage passed 26 plain integration cases and eight native Patrol cases, zero skips and no unexpected warnings. No merge or release is authorized.
- Health requires complete CPU, memory and root-disk metrics. Failed/incomplete readings invalidate current health without deleting history; old samples expire after three poll intervals (minimum 30 seconds). Reachability alone cannot assign perfect health. Current Servers, Fleet and Monitor indicators show unknown until fresh metrics are available.
- Open-session records no longer bypass current reachability probes. Selecting open/saved tmux sessions shows progress and verifies the exact remote name. Unreachable hosts keep recovery records and offer actionable Retry/Dismiss errors. Confirmed missing sessions remove only their pointer and never create an empty replacement. Fresh metrics supersede older failed reachability checks; old tmux checks cannot close a replacement channel.
- Ordinary regression guards reproduced the previous perfect-health defaults, skipped reachability check and hidden resume progress before the fixes. Kotlin's final `./scripts/local-pr-check.sh --full` passed unit/lint, release SBOM and strict fresh verification: each variant executed 575 JVM cases, with two optional external terminal-capture diagnostics skipped. API 35 plain instrumentation executed 24 cases and skipped 34 opt-in assumptions, with no real failures. A separate provision/trust/surface/tmux-retention invocation passed four cases, zero skips, using repository SSH fixtures and `omniterm_e2e_provision_host`, `omniterm_e2e_trust_host`, `omniterm_e2e_surfaces` and `omniterm_e2e_tmux_retention` set to `yes` (fixture SFTP home `/config`). Required x86_64 CI covers native-runtime tests; API 29 CI covers the Room matrix.
- Flutter's final `FLUTTER_BIN=<flutter> ./scripts/local-pr-check.sh --full` passed analyzer/formatting, 2,816 host cases, native companion unit/lint, release APK/AAB/SBOM generation and strict fresh project/release/compile verification. Seven optional Flutter cases were skipped: six setup/latency fixture checks and one compression fixture check. The initial companion Android installation failed because the disposable Kotlin fixture package used a different certificate; that platform step is not counted as passing. After removing only the conflicting disposable fixture installs, separate API 35 instrumentation executed 24 cases and skipped 36 opt-in assumptions, with no real failures and runner exit code zero.
- Flutter API 35 validation retained 20 successful plain cases, including the required route/subtab/theme/text-scale/rotation sweep. The first host-backed case failed because the disposable Podman fixture rejected a stale boot ID; only that container's temporary runtime cache was cleared. On unchanged source the host-backed Docker/Podman/SFTP/SMB/FTP/WebDAV case, key generation/import and startup recovery passed (seven additional plain cases). The remaining nine native Patrol cases also passed, zero skips and no unexpected warnings. Combined final-source coverage is 27 plain integration cases and nine native cases; the original interrupted profile is not called passing.
- Reproduce Flutter runtime coverage with `JAVA_HOME=<jdk21> ANDROID_HOME=<sdk> FLUTTER_BIN=<flutter> ./scripts/flutter-device-test.sh --device <API35-device> --profile all` and repository fixtures from `./scripts/test-hosts.sh up`. Required companion Android completion uses `./gradlew connectedOpenSourceDebugAndroidTest` on the same final tree after removing only conflicting disposable fixture installs.
- The normal `lib/main.dart` debug APK is archived at `artifacts/flutter-builds/20261003-server-health/OmniTerm-Flutter-debug.apk` (SHA-256 `a1b019df1b5017b3d1a12728c4f534dfda700d2b1b8e80bb217888e967a5a400`). Package, version, expected debug signature, debuggable state and absence of the Patrol entrypoint were verified. It installed and opened on API 35 without a recorded fatal error.
- This reboot/health checkpoint is complete on both branches. Broad Flutter parity remains open.


Updated: 2026-10-07. Working branch: `migration-to-flutter`; PR: #92.
Independent return review implemented and locally validated; **not** a parity-complete or release-ready declaration.

This sanitized tracker is intentionally committed so work can resume on another machine.
Before an authorized merge to `main`, consolidate it into the private handover under
`secrets/internal-docs/docs/` and remove this temporary file from the merge tree. Never put
secrets here: moving it later does not erase Git history.

## September 20 — exact Kotlin UI parity (active)

The user has explicitly requested the existing Kotlin UI throughout Flutter: every screen,
submenu, popup and option, including the SSH terminal, Settings, sizing and navigation. Kotlin is
the reference, not an invitation to redesign. The previous return-review checkpoint is complete;
its passing checks do not establish visual parity. The latest archived normal Flutter debug APK is
`artifacts/flutter-builds/20261003-keep-screen-on-runtime/OmniTerm-Flutter-debug.apk` (SHA-256
`90c434dc0ab2a20489741e159f65ced48e2e1c761f4520bcdcc2d23a7ab15156`). It is package
`com.jetsetslow.omniterm.app.flutter`, version `1.0.0-flutter` (code 1), signed by the expected
debug certificate; it installed and opened on API 35 without a recorded fatal error. Broader
terminal and app-wide visual/behavior parity remain in progress.

Clarifications: this includes every login/lock/biometric element and all functionality, including
long press, swipe, selection, keyboard shortcuts, Back, drag/reorder and contextual actions. Visual
similarity alone is not acceptance. The reported phone is a Samsung S23 Ultra on Android 16:
biometric unlock never opens its prompt, briefly refreshes when tapped and falls back to PIN.

Initial confirmed source discrepancies: the biometric plugin requires a FragmentActivity but the
app hosts it in FlutterActivity; authentication errors are silently collapsed into cancellation.
Flutter replaces the platform text scale whereas Kotlin composes it with the app preference.
Settings uses different sections, control types, order and labels. The first fixes and focused device validation are recorded below; broader parity work remains open.

Current checkpoint status (October 2):

- Signed/pushed Flutter head `c8ec131` fixed the alert-rule save race seen on hosted emulator job
  `109752301087` at the previous `7fcc3cf` head. The editor shows indeterminate saving progress,
  blocks concurrent edits and keeps actionable failures visible; its device test waits for both
  editor dismissal and the persisted row. The focused API 35 case passed (one, zero skips). The
  full local gate passed: 2,767 Flutter host cases with seven optional live-fixture skips,
  analyzer/format, release APK/AAB and both SBOMs, strict fresh verification, native unit/lint and
  all-ref secret scanning. Plain native API 35 instrumentation discovered 60 cases: 24 passed,
  36 opt-in assumptions, zero real failures. Flutter API 35 core passed 34 cases (26 plain, eight
  Patrol), zero skips, including route sweep, picker, enrolled biometrics, permissions and Settings.
  Its exact-head PR checks finished terminal green: native Build & Test, Room, release SBOM, CodeQL,
  Flutter host/emulator, iOS, release artifacts and security checks all succeeded. Selected-out
  alternatives were skipped; Scorecard was neutral. This does not establish full UI parity.
- Signed/pushed Flutter head `6f5d954` adds the next terminal checkpoint. Kotlin focuses an
  inactive split pane before a
  long-press copy action; Flutter opened that pane's transcript but kept the other pane focused.
  A focused `shell_screen_test` failed on the unfixed code for that exact mismatch and passes after
  the source change. The first API 35 host fixture run exposed a test synchronization error: after
  tapping Show full buffer, its existing scroll-indicator wait could pass while the sheet still
  showed Visible screen. The test now waits for the sheet's keyed Full buffer title. The corrected
  device host profile passed one SSH/runtime/share fixture case and one native lifecycle case with
  zero skips, covering the shell and transcript on Android. A normal debug APK was built, checked
  for its package, signature and entrypoint, installed and opened without a recorded fatal error.
  The final-tree `./scripts/local-pr-check.sh --full` passed after the test correction: 2,768
  Flutter host cases with seven optional fixture skips, analyzer/format, release APK/AAB and both
  SBOMs, strict fresh project/release/compile verification, native unit/lint and secret scanning.
  Android was explicitly excluded from that memory-heavy gate; the separate API 35 host profile
  above covered the affected shell/transcript surfaces. On this exact head, native Build & Test,
  Room, release SBOM, CodeQL, Flutter host, iOS, release artifacts and security checks passed, but
  the hosted emulator job `109962117822` failed before executing its Settings action: the test
  called asynchronous `app.main()` without awaiting it, then looked up `screen.servers` before
  `runApp` could build that screen. The same launch race exists in 14 integration-test files. The
  signed/pushed test repair `9bc76c1` awaits `app.main()` at all 15 call sites; analyzer passed. The
  exact failed Settings Patrol case passed on API 35 (one, zero skips), followed by the full Flutter
  core profile: 26 plain plus eight Patrol cases passed, zero skipped, including the route sweep,
  enrolled biometrics, picker and Settings. The separate API 35 SSH host profile also passed one
  fixture integration case and one native terminal lifecycle case with zero skips, covering the
  plain/tmux/control shell, Docker/Podman and SFTP/SMB/FTP/WebDAV fixtures. The final `--full`
  local preflight passed with 2,768 Flutter host cases and seven optional fixture skips, release
  APK/AAB and SBOM generation, native unit/lint, strict fresh dependency verification and secret
  scanning. Its Android device matrix was explicitly deferred because the emulator was stopped;
  the separate API 35 runs above covered this change. The replacement exact-head checks finished:
  Build & Test, Room, release SBOM, CodeQL, Flutter host, iOS, release artifacts and security passed,
  but hosted emulator job `110089554224` failed in the Settings action test. Its `scrollTo` stopped
  with the SFTP field built but not hit-testable after the default fifteen 64-pixel drags. The same
  case passed locally, so this is a reach/timing-sensitive test step; the next checkpoint targets
  the Settings list explicitly with short drags that can reach the full list. TUI gestures, terminal
  grid/font metrics and broad visual parity remained open at that head.
- Signed/pushed checkpoint `cbec344` routes a live terminal drag to PageUp or
  PageDown when its touched pane owns an alternate-screen TUI, while a plain shell still scrolls
  local history. Regular tmux attach asks the pane through a short cached side query; raw and
  control-mode sessions use their own emulator state. A swipe continues with native-style fling
  momentum, and the route stays with the touched split pane. Ten pure router tests, five widget
  gesture tests and two view-model transport tests pass. In an isolated source tree, the full Flutter
  host suite passed 2,785 cases with seven optional fixture skips; its API 35 host profile passed
  one SSH/runtime/share fixture case and one native lifecycle case, zero skips. The Flutter lock
  screen also defers its automatic or early tapped biometric request until the Android host resumes.
  If a system cancellation arrives only after resume, it preserves the offer until that request
  finishes. The initial inactive-host regression failed before the guard and passed after; a late
  cancellation regression likewise failed before its repair and passed after. The isolated lock
  suite passed 69 cases. On the combined tree, 161 focused Flutter host cases passed and the API 35
  core sweep passed 26 plain plus eight Patrol cases, zero skips, including Settings and biometric
  Activity recreation; this device pass preceded the final late-cancellation source edit. The
  repaired Settings Patrol case and final biometric Activity-recreation case then each passed on API
  35, one case and zero skips. Combined analyzer passed. The archived TUI/biometric debug APK was built from
  the final code, signature/package/version/debuggable state were verified, and it opened on API 35.
  The combined final-tree `./scripts/local-pr-check.sh --full` passed: native unit/lint, all-ref
  secret scan, Flutter formatting/analyzer and 2,789 host cases with seven optional fixture skips,
  release APK/AAB and both Flutter SBOMs, and strict fresh verification of project, release and
  compile graphs. Its Android device matrix was explicitly deferred because no emulator was
  connected; the separate API 35 runs above cover the affected shell, Settings and lock screens.
  Its exact-head PR #92 checks finished terminal: native Build & Test, API 29 Room migrations,
  release SBOM, Flutter host/release/iOS, dependency review, secret scans, Scorecard analysis and
  real CodeQL all succeeded. The hosted emulator passed 26 plain plus eight Patrol cases, zero
  skips, including the repaired Settings action and biometric lifecycle. Eight unused companion
  jobs were skipped and the separate Scorecard annotation was neutral; neither is counted as a
  passing test. The user's S23 Ultra on Android 16 is not locally connected, so its prompt
  behavior remains to be confirmed.
- Signed/pushed terminal metrics checkpoint `bbfed74` aligns font scaling and grid spacing.
  Kotlin sizes and paints cells using Android's system monospace at the terminal font's system-scaled sp size, with 6dp horizontal and
  4dp vertical insets and a four-percent right-column reserve. Flutter had used JetBrains Mono,
  fixed 1.2 line height, no system scaling or insets, and the whole width for remote columns.
  Flutter now applies those Android font, scale and spacing choices while preserving iOS's
  existing JetBrains line height.
  A widget regression failed on the old code because Android text scale 1.5 left columns 40 versus
  40, then passed after the change; 70 focused terminal/shell tests and analyzer passed. A fresh
  API 35 host profile passed one live SSH/runtime/share case and one native terminal lifecycle
  case, zero skips. The Flutter core profile passed 26 plain plus eight Patrol cases, zero skips,
  including the route/subtab/theme/rotation sweep and Settings actions. A separate live SSH fixture
  passed at Android system font scale 1.5 (one case, zero skips), and the system setting was
  restored. The first device attempt failed before test load when a broken disposable emulator
  refused to launch both this APK and a previously validated APK despite successful installs;
  wiping only that AVD restored normal launch before the successful runs. The final-tree full local
  gate passed: 2,790 Flutter host cases with seven optional fixture skips, formatting/analyzer,
  release APK/AAB and both Flutter SBOMs, strict fresh project/release/compile verification and
  all-ref secret scanning. Native unit/lint tasks reused their up-to-date results. The device
  matrix was deferred because the emulator was stopped; the separate API 35 runs above cover
  the affected screens. A normal `lib/main.dart` debug APK was built, verified for package,
  version, debug signature, debuggable state and absence of the Patrol entrypoint, archived in
  the terminal-metrics checkpoint folder,
  and installed/opened on API 35 without a recorded fatal error. All 25 PR check contexts for
  `bbfed74` are terminal: 16 succeeded, eight unused companions were skipped and the Scorecard
  annotation was neutral. Native Build & Test, API 29 Room, release SBOMs, Flutter host/release/iOS,
  real CodeQL, dependency review and security checks succeeded. Hosted emulator coverage passed
  26 plain plus eight Patrol cases, zero skips and no unexpected warnings. One walkthrough launch
  ran no tests before the runner recovered its transport by rebooting the disposable emulator;
  the successful attempt executed the case. Pixel-level terminal acceptance is still open.
- Signed/pushed renderer checkpoint `0675931` aligns glyph placement, cursor painting and native font bounds. Kotlin pins each glyph to its cell
  center and paints an opaque cursor block with a readable regular glyph on top. Flutter had
  allowed ordinary runs to follow font advances, left-aligned wide glyphs and overlaid a translucent
  cursor. Five raster regressions failed on those old behaviors and pass with centered glyphs and
  clipped cursor repaint at the original wide-glyph origin. Layouts for repeated glyphs/styles are
  shared within a frame and disposed afterward. The focused terminal/shell suite passed
  75 cases before the final font geometry refinement; final validation is recorded below. The early
  API 35 host validation passed one live SSH/runtime/share case and one native terminal lifecycle
  case, zero failures/skips, with only known upstream warnings.
  The API 35 core run passed 26 plain and six Patrol cases, including the required
  route/theme/rotation sweep, then failed at Settings actions teardown because Android accessibility
  enabled a framework semantics handle after the test baseline was recorded. Behavior assertions
  had passed. The fixture now owns/disposes a stable suite semantics handle, following the other
  native fixtures; the repaired case passed on device (one, zero skips). The final Settings parity
  case, not reached by the interrupted core profile, also passed separately (one, zero skips).
  Actual Android Paint and Flutter measurements then confirmed that Flutter rounded line height
  and used fractional glyph advances, while Kotlin retained font bounds and hinted widths to
  physical pixels. Flutter now uses those native width/height/baseline choices. On the same API 35
  runtime, width, height and baseline match native monospace measurements at 8, 10, 13, 18 and 28sp.
  A geometry widget guard failed before the correction and passes after. The final focused suite
  passes 78 cases, including six painter guards and a fixture-byte round-trip across 8–80 columns.
  The refined live SSH/runtime/share case passed (one, zero skips), but its lifecycle guard exposed
  whitespace-separated byte reports fusing adjacent values at trimmed wrap boundaries. Replaying
  the repository fixture report reproduces that at 62 columns. The fixture now encodes commas,
  preserving every byte delimiter. That run completed its behavior assertions but hit the same
  late accessibility semantics-handle teardown race, so the lifecycle fixture now also owns and
  disposes its suite handle. The repaired lifecycle case passed (one, zero skips). Both Settings
  follow-ups and the final lifecycle log have no unexpected warnings. The final geometry screen
  sweep also passed on API 35 (one case, zero skips), reopening every route/subtab/theme/rotation
  after the font bounds correction. The normal `lib/main.dart` debug APK was built, verified for
  package/version/debuggable state, the expected debug signature and absence of the Patrol
  entrypoint, archived in the terminal-renderer checkpoint folder and installed/opened on API 35
  with no recorded fatal error.
  The final-tree `./scripts/local-pr-check.sh --full` passed: formatting/analyzer, 2,798 Flutter
  host cases with seven optional fixture skips, release APK/AAB and both Flutter SBOMs,
  development-code exclusion, all-ref secret scanning and strict fresh project/release/compile
  verification. Native unit/lint tasks reused their up-to-date results. Its Android device matrix
  was deferred because the emulator was stopped; the separate API 35 runs above cover the affected
  screens. All 25 exact-head PR contexts are now terminal: 16 successes, eight unused companion
  skips and one neutral Scorecard annotation, with no failure/cancellation. Native Build & Test,
  API 29 Room, release SBOM, Flutter host/release/iOS, real CodeQL and repository security passed.
  The hosted emulator passed 26 plain plus eight Patrol cases, zero skips and no unexpected
  warnings. Its first app-actions launch lost the VM service before any case executed; the bounded
  runner recovery rebooted the disposable emulator and the successful attempt ran all five cases.
  Whole-terminal pixel and app-wide visual parity remain open, including the shared/session header
  and keyboard details.
- Signed/pushed resize checkpoint `358eec9` caps the remote grid at Kotlin's 500 columns/300 rows and
  waits 120ms for the layout to settle before reflowing or notifying the SSH channel. New layouts
  replace the pending request; removing the pane or switching sessions cancels it. Visible rows
  and TUI page distance still follow the shown layout immediately. Painting is clipped to the pane
  so stale columns cannot spill into a neighbor during the wait. Four grid/timing/lifecycle guards
  failed before the change, then separate raster-clipping and immediate-visible-range guards
  failed before their corresponding repairs. The final focused suite passes 84 cases. Final-source
  API 35 host coverage passed one live SSH/runtime/share case and one native terminal lifecycle
  case, zero skips and no unexpected warnings. The final API 35 route/subtab/theme/rotation
  sweep also passed one case, zero skips and no unexpected warnings. The ordinary `lib/main.dart`
  debug APK was checked for package/version/debuggable state, expected debug signature and absence
  of the Patrol entrypoint, archived in the terminal-resize checkpoint folder, then installed/opened
  on API 35 with no recorded fatal
  error. The final-tree `./scripts/local-pr-check.sh --full` passed: formatting/analyzer,
  2,804 Flutter host cases with seven optional skips (six setup fixture cases and one compression
  fixture), release APK/AAB, both Flutter SBOMs, development-code exclusion, all-ref secret scanning
  and strict fresh project/release/compile verification. Native unit/lint reused their up-to-date
  results. The in-script Android matrix was deferred because the emulator was stopped; the three
  separate API 35 cases above cover the affected surfaces, and exact-head PR CI covers API 29 Room.
  Exact-head PR checks are complete: 16 succeeded, eight unused companion jobs were skipped and
  Scorecard was neutral, with no failure/cancellation. Native Build & Test, API 29 Room, release
  SBOM, Flutter host/release/iOS, CodeQL and repository security passed. The hosted emulator passed
  26 plain plus eight Patrol cases, zero skips and no unexpected warnings or recovery reboot.
  Broad parity is still open.
- The next shared host-picker checkpoint replaces the bare dropdown on Monitor and Containers
  with Kotlin's outlined control, padding, 16sp host name, 12sp detail and HOST label. The popup
  spans its anchor, and selecting the current host closes it without restarting work. That
  behavior guard failed on the old source and passes after. Nine focused cases pass, including
  address privacy, changed-host selection and visible overflow cues before scrolling/at the
  bottom of a long menu. Native bodyLarge line height and letter spacing are scaled separately,
  because Flutter scales only font size. The Android route sweep now opens/closes both menus
  across its themes, text sizes and rotations. The picker-only API 35 sweep passed one case,
  zero skips and no unexpected warnings. The resolved Material3 1.4.0 library confirms popup labels
  use labelLarge (14sp/20sp line height) and a 24dp icon slot; the picker matches those as well.
  The first full local gate exposed two Infra regressions: the raw-editor test had to reach its
  lazily built field, and the larger picker plus tab row overflowed a 150dp viewport at 200% text.
  Closed picker labels now explicitly stay on one line, matching Kotlin. Infra makes its contents
  scroll when the viewport cannot accommodate its header, tabs and resource actions. The raw-editor
  test verifies the toggle and scrolls to the field before asserting it. All 51 focused picker/Infra
  cases pass, and formatting plus both Git whitespace checks pass. An intervening full-gate
  attempt stopped before native tests while temporary environment restrictions blocked caches
  and GitHub. Access was restored. The final-source API 35 sweep passed one case, zero skips and
  no unexpected warnings, including both host menus, every route/subtab/theme/text size and
  rotation. The rebuilt ordinary `lib/main.dart` debug APK was verified for package/version,
  debuggable state, expected debug signature and absence of the Patrol entrypoint, archived above
  and installed/opened on API 35 without a recorded fatal error. The final-tree full local gate
  passed: formatting/analyzer, 2,806 Flutter host cases with seven optional skips (six setup fixture
  cases and one compression fixture), release APK/AAB, both Flutter SBOMs, development-code
  exclusion, all-ref secret scanning and strict fresh project/release/compile verification. Native
  unit/lint reused their up-to-date results. The in-script Android matrix was deferred because the
  emulator was stopped; the separate final API 35 sweep above covers the changed surfaces, and PR
  CI supplies the API 29 Room gate. Signed publication and exact-head CI remain pending.
  Surrounding Monitor/Containers headers
  and the terminal's host/action header still differ; this is not whole-screen pixel acceptance.
- October 2 priority: fix stale open/saved tmux selection after a server reboot, missing pending/
  error feedback, and Hosts falsely showing online/100 without reliable metrics. Implement Kotlin
  on `kotlin-bug-fixes` and Flutter on `migration-to-flutter`. The initial Kotlin regressions fail
  on unfixed code: both empty metrics and a failed refresh after a valid sample leave health at
  100. Investigation is active; these fixes are not yet implemented or device-validated. Broader
  parity and the split-pane focus investigation remain open.
- Kotlin Dependabot #109 now has signed/pushed head `298467c` with strict metadata for the Gradle,
  Android Gradle Plugin, Navigation, Roborazzi, Bouncy Castle and Develocity updates. A standalone
  `--write` and separate `--verify` passed; 111 added records and three completed SHA-512 records
  all have dual checksums. Its full local gate passed both native unit/lint variants and strict
  fresh resolution. The emulator was OOM-killed during that gate, so Android instrumentation was
  run separately on restarted API 35: plain 58 discovered/24 passed/34 opt-in assumptions, then
  fixture provision, trust and screen sweep each passed one case with zero skips. The first screen
  sweep invocation used another lab's SFTP home and failed; the corrected repository fixture path
  passed without a source change or reinstall. #109 exact-head hosted checks finished green,
  including Build & Test, Room migrations, release SBOM, CodeQL and security. #110's unsigned
  metadata commit was never merged; its superseded PR was closed and remote branch deleted. #111
  has terminal checks without failures but still requires review. Nothing was merged to `main`.

Earlier checkpoint history (superseded by the current status above):

- Signed recovery checkpoint `352b72c` reached terminal hosted results. Native Build & Test,
  Room migrations, release SBOM, CodeQL, dependency review and security checks passed. Flutter's
  emulator job failed in the existing host-action device test: after tapping `SSH ANYWAY`, the
  expected offline confirmation was absent. The test had already observed the completed host
  probe and visible action. The host card awaited two launcher-shortcut platform calls before
  asking `ShellViewModel` to connect; those calls delayed the prompt on the hosted emulator.
  The current tree starts the SSH decision before shortcut bookkeeping. A controlled API 35 device
  regression held the shortcut channel open: it failed on the unfixed host card with the expected
  missing dialog, then passed on this tree. `./scripts/local-pr-check.sh --full` passed, including
  2,767 Flutter host tests with seven optional fixture skips, release APK/AAB and both Flutter
  SBOMs, native unit/lint, strict fresh dependency verification and secret scanning. Plain native
  API 35 instrumentation discovered 60 cases: 24 passed and 36 opt-in assumptions, with no actual
  failures. Flutter's complete API 35 core device profile passed all 34 cases with zero skips and
  no unexpected warnings: 26 plain integration cases and eight Patrol cases, including the route
  sweep, native document picker, enrolled biometric prompt, notification permission and phone-size
  Settings flows. A signed replacement checkpoint and hosted checks remain pending.
- New Kotlin Dependabot PRs #109 and #110 are open: #109 raises Gradle, Android Gradle Plugin,
  Navigation, Roborazzi, Bouncy Castle and Develocity; #110 supplies strict verification metadata.
  #109's native Build & Test and CodeQL failed on the uncombined head. Review and validation in
  an isolated Kotlin worktree remain pending. Its metadata fixup commit is unsigned, so its file
  changes are staged for a signed review commit without introducing that commit into protected
  history. The 106 new artifact records each include SHA-256 and SHA-512; Gradle's published
  distribution and wrapper JAR checksums match. GitHub Actions PR #111 is also open with terminal
  checks and no failures, pending required review.

- Signed Settings checkpoint `d840e92` is pushed. Its normal debug APK was installed and opened
  on API 35; package, version, stable signing certificate, debuggable state, ordinary app entrypoint
  and SHA-256 were checked. Secure-window screenshots are black; the UI hierarchy confirms that
  the app opened. This build is not a complete Kotlin-parity or release-ready declaration.
- All checks for that exact head have finished. Native Build & Test failed in
  `TerminalLeavePersistenceRobolectricTest.navigationAndLiveChannelWaitForDurableRecovery`; Room
  migrations and native release SBOM were consequently skipped, not passed. The console reported
  only the coroutine entry line and no unit report artifact was retained, so the exact inner
  assertion cannot be established from the hosted evidence. An unchanged local class rerun passed.
- Inspection found that the asynchronous startup recovery read could publish an old snapshot after
  a newer leave/save transaction. Startup now uses the same mutex as recovery mutations, with the
  mutex initialized before the constructor launches work. The regression reports explicit state
  and durable-storage assertions. Hosted failures now retain unit XML/HTML; local reports remain
  in the same Gradle output directories.
- Flutter emulator CI failed before any app-actions test loaded: `VmServiceDisappearedException`
  during the tool's VM attachment. The device log shows the VM opening and subsequent tool teardown,
  with no preceding app crash or low-memory kill. The existing bounded emulator recovery now
  recognizes this exact loading failure. Its console replay failed before the runner change and
  passes afterward, including repeated failure, a test already executed, and preserved-phone cases.
- Replacement `./scripts/local-pr-check.sh --full` passed on Linux x86_64: both native variants
  freshly ran 572 tests each (570 passed, two existing disabled tmux cases); Flutter ran 2,767 tests
  successfully with seven optional fixture skips (six setup and one compression). Formatting,
  analysis, native lint, Flutter release APK/AAB, both Flutter SBOMs, development-code exclusion,
  all-ref secret scan and strict fresh dependency verification passed. No ARM64 exclusion applied.
- API 35 instrumentation discovered 60 cases: 24 passed, including four Room migrations, and 36
  were opt-in assumptions. Separate opted-in fixture provisioning, host trust, complete native
  surface sweep, Settings reference capture and recovery progress/failure/retry each passed one
  case with zero skips. The recovery case used `omniterm_e2e_terminal_nav_matrix=yes`; the surface
  sweep used `omniterm_e2e_surfaces=yes` and the repository fixture SFTP home. Flutter's core device
  profile passed all 34 cases with zero skips. Hosted validation is pending for the replacement
  checkpoint and must reach terminal results before this repair is considered complete.
- A private candidate corrects Android's combined app/system nonlinear text scale and landscape
  navigation bars. Targeted before/after Android fixtures and independent Compose converter values
  pass, and 2,771 private candidate host tests pass with seven optional skips. After correcting the
  obsolete linear expectation, its device sweep exposed landscape clipping in Servers, Fleet,
  Shares, Alerts and Network, plus a Fleet Broadcast invalid height constraint. Those failures,
  font spacing and wrapping remain unresolved. These candidate changes are not in `d840e92` or
  this checkpoint.

First checkpoint published as `c6817b3`; local and exact-head hosted validation complete:

- Reproduced the missing biometric prompt on API 35 against the original Activity/adapter. Android
  rejected the Activity; with an enrolled fingerprint the new regression also sees authentication
  finish immediately instead of waiting for the system prompt. The fixed gate has completed a real
  fingerprint-authorized Keystore challenge and cancellation (two opted-in device cases passed).
- Android now uses the same strong-biometric-only, per-use AES/GCM challenge and prompt
  title/subtitle/Cancel text as Kotlin. Other platforms retain their biometric-only plugin.
  Integration errors are visible beside PIN fallback; concurrent requests share one prompt.
- Restored Kotlin's launcher artwork and separate system prompt bitmap, including the round-icon
  path. The native branding guard caught Android's round-icon substitution during development.
- A new native lifecycle fixture caught an engine-destruction regression from FlutterFragmentActivity:
  its fragment builder explicitly requests destruction despite an injected engine. An explicit
  retained Fragment now preserves the engine. The enrolled-device fixture passed real Activity
  recreation with the same system fingerprint request, repeated calls, Back/cancel, visible button
  retry, wrong PIN refusal and correct PIN unlock (one executed, zero skipped).
- Lock layout now follows Kotlin's wordmark, instruction, PIN field, full-width Unlock and outlined
  fingerprint button. Startup hides private content until security settings load. Biometric setup
  verifies the user before enabling it; Settings authentication uses its own reason and wording.
- Decode and save Kotlin's actual text presets (Small 80%, Default 92%, Large 110%), preserving
  existing numeric Flutter values; combine app and platform text scaling. Exact screenshots at
  accessibility scales are still pending; no whole-app visual parity is claimed.
- Full Flutter core device profile passed on API 35: 32 executed, zero skipped, including the
  enrolled biometric recreation branch, route/subtab/theme/orientation sweep and native pickers.
  The live-host profile passed two tests with zero skips, including six SSH modes and 14 real
  Activity destruction/replacement transitions preserving engine identity and window security.
  Its initial run exposed a test synchronization issue: after entering a PIN, the lock/intent
  fixture tapped before the newly enabled Unlock button rendered. It now pumps that frame and
  explicitly checks that the button is enabled before tapping.
- Native API 35 validation discovered 58 tests: 24 executed successfully (including four Room
  migration cases), 34 opt-in E2E assumptions, zero actual failures. After installing both APKs
  once, repository-host provisioning and trust passed, then `E2eAppSurfaceStressTest` passed with
  `-e omniterm_e2e_surfaces yes -e omniterm_e2e_sftp_home /config` (one executed, zero skipped).
- `./scripts/local-pr-check.sh --full` passed on Linux x86_64 on September 20: formatting and
  analysis passed; 2,746 Flutter tests executed successfully, with seven optional skips (six
  `OMNITERM_SETUP_FIXTURE` cases and one `OMNITERM_COMPRESSION_*` case). Native unit tasks and
  lint analysis were up-to-date, not freshly re-executed; no Linux ARM64 exclusion applied.
  Flutter release APK/AAB, both Flutter SBOMs, development-code exclusion and pinned all-ref
  secret scanning passed. The gate's device phase was deferred after stopping the emulator for
  memory; the explicit local API 35 results above cover it.
- The required dependency metadata `--write` pass produced no changes (the explicit biometric
  version matches Kotlin), and forced-refresh `--verify` passed for native project, compile and
  both release SBOM graphs. This is not a claim of strict verification metadata for the separate
  Flutter Gradle project. Both diff checks and the pinned staged secret scan passed.

The signed checkpoint passed all selected hosted jobs: native Build & Test, API 29 Room
migrations, native release SBOM generation, Flutter analysis/tests, Android release and iOS builds,
Flutter emulator E2E, CodeQL analysis, dependency review, secret scans and Scorecard analysis.
The companion no-op CodeQL job and separate Scorecard annotation are not counted as executed
security analyses. The next Settings/terminal work remains open.

Reproduce biometric hardware validation on an enrolled disposable Android emulator with
`flutter test integration_test/biometric_host_test.dart -d <device> --dart-define=OMNITERM_E2E_BIOMETRICS=true`;
provide the enrolled emulator fingerprint only after its native authentication operation starts.
Without this define the file runs the availability/cancellation guard. The native Patrol fixture
`integration_test/native/biometric_unlock_test.dart` also exercises recreation when a strong
biometric is enrolled; on a clean CI device it reports that branch unavailable and checks PIN
fallback. Both Android-specific files explicitly skip on other platforms. Protected system prompt
screenshots from `adb screencap` are black and are not visual evidence.

Terminal keyboard checkpoint published as `fea3297`; hosted emulator correction in progress:

- Restores Kotlin's regular two-row, eleven-column layout and centered arrow cluster, with the
  separate compact twenty-column layout only for landscape while the software keyboard is open.
  The compact state is passed from above Scaffold, which consumes keyboard insets in its body.
- Uses Kotlin's key color tokens, borders, dimensions and fixed function/symbol toggle positions.
  Navigation/editing keys send on press, repeat after 400 ms and then every 60 ms, and stop on
  release, cancellation, leaving the touch target, widget removal or app backgrounding.
- Five focused hold/layout regressions were added. Against the original keyboard, four fail and
  its existing compact layout passes; the candidate passes all five and the twenty existing live
  terminal widget cases. The complete Shell screen widget file passes 63 tests; navigation passes
  24 tests, and analysis is clean. These are not a substitute for device/visual validation.
- A live SSH regression failed against the original keyboard for the expected reason (one Up
  sequence) and passed with the candidate (seven sequences from one held key). The host profile
  passed two tests with zero skips, covering all six SSH modes and 14 Activity transitions.
- Full-app Android IME validation reproduced the missing compact-layout handoff from the scaffold
  to ShellScreen. The fix passes the inset before Scaffold consumes it and hides ordinary session
  headers in compact mode, while retaining connection errors/progress. A small scrollable fallback
  keeps controls reachable during transient rotation frames with the old keyboard height.
- Matching Kotlin/Flutter captures on the same API 35 runtime exposed a second inset defect:
  Flutter's compact bar started at x=0 under a 48.76-dp display cutout. Its device regression failed
  before the fix; compact content now respects the system safe area. The software keyboard also
  requested Done instead of Enter; a failing widget regression covers the corrected Enter request,
  terminal carriage return and retained input focus.
- The full-app layout fixture exercises the actual Android IME, all keyboard layers, read-only mode,
  dark/light/high contrast and large text. It verifies the theme and text scaler in the rendered
  tree. Its first version updated the underlying preferences without updating the root theme;
  those initial theme screenshots are excluded. The corrected run passed one native test with
  zero skips, including all six SSH modes and 14 Activity transitions. The final inset/Enter tree
  passed the complete host profile on September 23: two executed, zero skipped. The held key sent
  six Up sequences in that run, and the actual Android IME/layout assertions passed.
- Added opt-in `E2eParityReferenceCaptureTest` for repeatable Kotlin reference frames against the
  provisioned repository SSH fixture. With `-e omniterm_e2e_parity_captures yes`, one test executed
  successfully with zero skips and captured twenty frames; screenshot security and preferences are
  restored afterward. Flutter's optional `OMNITERM_E2E_VISUALS=true` instrumentation captures stay
  in private test storage and are absent from the production app. An initial unseeded reference run
  timed out; explicit repository provisioning and host-key trust preceded the successful run.
- The comparison is not whole-terminal visual acceptance: the main header, canvas font/grid,
  software-keyboard details and fallback Enter glyph still differ and remain in the next terminal
  work. This is a terminal-keyboard checkpoint, not acceptance of the whole terminal UI.
- The final keyboard tree passed `./scripts/local-pr-check.sh --full` on Linux x86_64 on September 23:
  2,753 Flutter tests passed, with seven optional skips (six setup-fixture cases and one compression
  fixture). Formatting, analysis, release APK/AAB, both Flutter SBOMs, development-code exclusion,
  pinned all-ref secret scanning and forced-refresh strict dependency verification passed. Native
  unit/lint tasks reused up-to-date results; no Linux ARM64 exclusion applied. The gate explicitly
  deferred device checks while the emulator was stopped for memory.
- Separate final-tree API 35 evidence covers that deferral: Flutter core 32 executed/zero skipped;
  host profile two executed/zero skipped; native package 59 discovered, 24 passed including four
  Room migration cases, and 35 opt-in assumptions (zero actual failures). Native repository-host
  provisioning/trust and the required surface sweep passed with `-e omniterm_e2e_surfaces yes
  -e omniterm_e2e_sftp_home /config` (one executed, zero skipped). The final Kotlin keyboard capture
  fixture also passed again (one executed, zero skipped, twenty reference frames).
- After a machine reboot, the first repeated host run could not launch while the emulator user was
  credential-locked; the run resumed after explicitly verifying the unlocked state. A later run exposed a stale
  boot ID in the disposable Podman fixture. Recreating that fixture restored its runtime; the
  succeeding host profile above exercised it. Neither failure required application changes.
- The final Flutter visual fixture passed on September 23 (one executed, zero skipped) and retained
  twenty frames matching the Kotlin capture matrix. Insets and keyboard geometry agree. The
  captured Flutter app surface is dimmer despite matching rendered color tokens; whether this is
  a capture/runtime effect or an application rendering difference remains to be isolated. Do not
  treat color-token assertions as pixel-level acceptance.
- The signed keyboard checkpoint passed every selected hosted job except the Flutter emulator
  suite. Its failed job was inspected before editing: `biometric_unlock_test.dart` timed out
  waiting for the wrong-PIN result after the no-enrolled-biometric fallback. Native build/tests,
  API 29 migrations, native SBOM, Flutter analysis/release/iOS, CodeQL, dependency review, both
  history scans and Scorecard analysis passed. Conditional no-op jobs were skipped.
- Reproduced that exact failure on a clean API 35 emulator with no enrolled fingerprint. The
  controller's availability error arrived before the screen rendered its enabled PIN field, so
  the test's text entry was discarded. The corrected fixture waits for the rendered input and
  enabled submit control, checks that input was accepted, and verifies a wrong PIN consumes one
  attempt. Both the clean-device fallback and enrolled-fingerprint recreation/cancellation cases
  now pass separately (one executed, zero skipped each). The replacement full local gate passed:
  2,753 Flutter tests, seven optional fixture skips, clean formatting/analysis, release APK/AAB,
  both Flutter SBOMs, development-code exclusion, pinned history secret scan and forced-refresh
  strict native dependency verification. Native unit/lint tasks reused up-to-date results; no
  Linux ARM64 exclusion applied. The device phase was explicitly deferred with the emulator off;
  the separate API 35 results above cover it. No authentication production code changed.
- The Flutter CI workflow now retains the device runner's logs and Android test reports even on
  failure. It uses the same evidence already produced locally, with a pinned upload action and
  seven-day retention. The previous failed runner did not upload these diagnostic files.
- A normal debug APK of `fea3297` was signature/package/version/kernel-verified, installed and
  cold-launched on API 35. It includes authentication and the keyboard changes. Settings parity
  remains separate and is not included; replacement hosted checks are still required.

The next exact-head run (`b158d8c`) completed every selected hosted job. All passed except
Flutter emulator E2E, which failed **before** the surface test started: Flutter exposed its VM
service but the host's five-second connection handshake timed out. The retained device logs show
no app crash; the earlier plain actions and app-lock tests passed, and the native biometric test
was not reached. This is a different failure from the corrected PIN-input synchronization case.

The device runner now recognizes that specific pre-test attachment failure and uses its existing
single recovery attempt after resetting the disposable emulator. It requires the tool's loading
failure, zero executed tests and the integration-device stack frame. A replay of the hosted output
failed on the original runner and passes with the correction; negative cases verify that actual
test execution, a repeated failure and a preserved personal device cannot trigger extra retries.
The local and both hosted gates already invoke this same shell regression suite. The corrected
runner passed the full core device profile on a clean API 35 emulator: 32 tests, zero skips.
Its enrolled-biometric branch was unavailable on this clean device; the previous separate enrolled
recreation/challenge result remains the evidence for that branch.

The final `./scripts/local-pr-check.sh --full` passed: 2,753 Flutter tests, seven optional fixture
skips, formatting/analysis, release APK/AAB, both Flutter SBOMs, development-code exclusion, pinned
all-ref secret scan and forced-refresh strict native project/compile/release-SBOM verification.
Native unit/lint tasks reused up-to-date results, with no ARM64 exclusion. The emulator was stopped
for this gate, so its device phase was deferred; the explicit API 35 core run above covers the
changed runner. Replacement exact-head hosted checks remain required.

The next runner checkpoint (`25091c4`) completed all selected checks; every job passed except
Flutter emulator E2E. Its initial DDS failure recovered through the existing bounded reset. The
actual failure then occurred after the Settings action test finished: its final save was still
refreshing app-lock state when teardown closed the database (`ConnectionClosedException`). This
is an application/test completion boundary, not a pre-test transport failure, and is not retried.

The Settings screen now keeps Save disabled and displays pending state until persistence and
lock refresh both finish. The success message stays hidden until then. Refresh failures are
shown with a Retry save action. The action test explicitly checks the final visible result before
teardown. Two controlled refresh regressions fail on the original screen for the missing pending
state; the corrected screen passes both and all 24 existing Settings screen cases.

The final full preflight passed on September 26 on Linux x86_64: 2,755 Flutter tests passed, with
seven optional fixture skips (six setup cases and one compression case). Formatting, analysis,
release APK/AAB, both Flutter SBOMs, development-code exclusion, pinned all-ref secret scanning
and forced-refresh strict native project/compile/release-SBOM verification passed. Native JVM
and lint analysis tasks reused up-to-date results; no Linux ARM64 exclusion applied.
The emulator remained available: native API 35 discovered 59 cases, with 24 executed successfully
(including four Room migrations) and 35 opt-in E2E assumptions, zero actual failures. Separate
repository-host provisioning and trust each passed, then the required native surface sweep passed
with `-e omniterm_e2e_surfaces yes` and the provisioned fixture's SFTP home (one executed, zero
skipped). Flutter core passed all 32 tests with zero skips, including Settings actions, route/theme/
orientation sweep and native pickers. This clean emulator had no enrolled fingerprint; the earlier
separate enrolled-device challenge/recreation results cover that branch. Signed checkpoint
`2a9fcd9` passed every selected exact-head hosted job, including native Build & Test, API 29 Room,
release SBOM, Flutter emulator/release/iOS, CodeQL and repository security analysis. Skipped
companion workflow jobs and the neutral Scorecard annotation are not counted as executed tests.
The broader Settings parity changes below were not in that checkpoint.

Settings parity integration is locally validated on the working branch; new exact-head hosted
checks remain pending:

- The six cards, inline Back/title, fixed Cancel/Save actions, switches, chips, sliders, labels,
  ordering, PIN setup and anchored menus follow Kotlin's Settings screen. Menus retain Android's
  text scale independently of the app preset, use intrinsic widths, and prefer above the anchor
  when insufficient space remains below. Settings and popup overflow indicators stay visible.
- PIN setup persists immediately without applying unrelated drafts. Settings saves retain their
  confirmation/authentication order and wait for persistence plus lock refresh. Failed PIN removal
  retains the remaining cleanup for Retry save, even after preferences were successfully written.
  PIN removal now commits credential deletion and throttle reset together before changing live
  controller state. A fault-injection regression fails on the original partial-write path and
  passes after the transaction fix, alongside the 66 existing lock/cleanup cases.
- Numeric drafts keep incomplete input visible and block invalid saves. Successful saves normalize
  bounded values; concurrent calls share the operation and edits made during it remain unsaved.
  System theme clears a forced theme. Defaults/ranges and editor highlighting character units now
  follow Kotlin, including Off; old unversioned values are not heuristically reinterpreted as KB.
- Added host regressions for Settings persistence, draft handling, popup scaling/placement and PIN
  cleanup retry; existing Settings/App Lock flows now exercise Kotlin's immediate single-PIN setup.
  The phone-sized functional fixture failed on the original screen's missing reference layout,
  then passed on the candidate (one executed, zero skipped). It checks persisted values only after
  the sticky Save button reports completion; an offscreen progress bar cannot prove completion.
- Candidate API 35 screenshot traversal passed one test with zero skips across dark, light, high
  contrast and Large text, capturing all six cards, PIN setup and the theme menu. Kotlin reference
  capture passed separately. Stable capture fixtures are included; private font diagnostics are
  excluded. These captures do not establish whole-app pixel parity: Android/Flutter glyph metrics,
  shared header/navigation and wider accessibility-scale comparison remain open. A separate
  scaling correction is being prepared: Kotlin applies its Android curve after combining the
  phone and app scales, whereas the current Flutter app multiplies after platform conversion.
- The first combined core run passed all 34 Android cases with zero skips. Live SSH validation
  then exposed an existing keyboard-layout boundary: changing scaffold layouts remounted the
  terminal, so hiding the landscape IME immediately reopened it. A device identity assertion fails
  on the original screen with the previous terminal state already disposed. The scaffold and
  terminal now retain their mounted content across layout and temporary overflow-wrapper changes.
  The corrected live-host profile passed both the plain SSH/Docker/Podman flow and native terminal
  lifecycle case (two executed, zero skipped). Core passed 34 Android cases, zero skipped.
- Final Linux x86_64 full preflight passed: 2,767 Flutter cases with seven optional fixture skips
  (six setup, one compression), release APK/AAB, both Flutter SBOMs, development-code exclusion,
  pinned all-ref secret scan (237 commits), and forced-refresh strict native verification passed.
  Native JVM/lint tasks reused successful results; each JVM variant has 570 passing cases and two
  pre-existing disabled tmux cases, with no ARM64 exclusion on this host. API 35 discovered 60
  native cases: 24 passed (including four Room migrations), 36 opt-in assumptions, zero actual
  failures. Separate provision/trust, `omniterm_e2e_surfaces=yes` with the repository fixture home,
  and `omniterm_e2e_settings_captures=yes` each passed one test with zero skips.
- The final PIN-removal transaction was added before the full preflight and later native Flutter
  Settings cases, after the core run's first Settings/unlock cases. Those first seven cases are
  reran successfully on the final source (seven executed, zero skipped). The initial focused
  wrapper stopped before any test because it attempted to clear an already-uninstalled package;
  the corrected wrapper checks package presence first. This was fixture setup, not an app failure.
  Published as `d840e92`; its normal APK contains this integration. Exact-head hosted outcomes and
  the required follow-up are recorded at the top of this section.

New authorized work: implement Kotlin Dependabot #107 (AGP 9.4.1 / Bouncy Castle 1.86) and its
metadata companion #108. Validation is isolated from the Flutter Settings candidate. The existing
root resolution rule must also change or it silently overrides the Bouncy Castle catalog bump.
Signed dependency checkpoint `74f40bf` is pushed to #107 after native full preflight, strict
fresh-resolution verification and API 35 runtime validation. It includes all #108 hashes unchanged
plus the six Bouncy Castle artifacts required by the corrected resolution rule. Every selected hosted check passed for that exact head, including API 29 migrations,
release SBOM, CodeQL and repository security checks. Redundant companion #108 is closed and its
branch removed. #107 awaits independent review; its dependency changes are not yet applied to this
Flutter branch, and no dependency update has been merged to main.

Parity acceptance inventory (all pending until compared on Android):

- Shared surfaces: light/dark/AMOLED/high contrast; app and system text scaling; typography,
  cards, buttons, fields, switches, chips, scroll indicators, dialogs and menus; portrait and
  landscape top/bottom navigation; host selector, alerts popup, refresh and exit/unsaved guards.
- Servers: summary/search/groups, host cards, add/edit/clone, authentication and jump-host options,
  multiselect/import, actions, host-key trust/replacement and connection/progress/error states.
- Fleet: all three tabs, filters, bulk actions, broadcast/deploy/pipeline editors and results.
- Monitor: all six tabs, metric details/history, process/service/log actions and confirmations.
- Terminal: connect/session picker, tabs, plain/tmux/control sessions, keyboard/key bar, input and
  selection, zoom/fullscreen, search/transcript ranges, links, session/options menus, leave/resume,
  disconnect and background notification actions.
- Files: all four tabs, navigation, sorting/filtering/selection, item/context menus, editor,
  upload/download/pickers, transfer queue/progress/errors, archive/share options and warnings.
- Containers: all five tabs, runtime/host selection, detail/actions/logs/exec, compose editor,
  deploy/pull/delete confirmations and progress.
- Tools: tool grid and headers; Alerts (three tabs/rules/incidents), Scripts (two tabs/edit/run),
  Network (nine tabs and their forms/results), Auth & keys (profiles/keys/trust/import/generation),
  Backup (selection/password/restore/conflicts/results), Health scoring (edit/reset), Settings
  (all six Kotlin cards, choices, security/PIN/biometric setup and save), About/diagnostics/crashes.
- Lock and privileged authentication: platform biometric prompt, cancel/fallback/error/retry,
  cold start/background return, PIN setup/change/throttle and secure-window behavior.

Required publication gates remain the full local PR check, opted-in API 35 surface sweep and
affected native/Flutter device flows, signed sanitized checkpoints, and all exact-head PR checks.
Capture comparable Kotlin/Flutter screenshots and record outstanding differences explicitly;
generic functional test success is not visual acceptance. No merge or release is authorized.

## September 17 return review — lifecycle and notification fixes

The handover's detector claims were independently reproduced: current workflows pass all 39
checks; the actual pre-fix workflows fail exactly 12 and pass 27 with GNU grep. The real CodeQL
analysis on the incoming `c7933d6` head ran for 8m51s and completed its analysis step; its companion
no-op was skipped. The seven named checkpoints were reviewed from their source changes, including
the attempt-local SSH channel ownership boundary and backup omission/selection/time reporting.

**The missing live-device recreation control now exists in the instrumentation APK only.** It
calls Android's `recreate()` or finishes and relaunches the Activity, requires the old instance's
destruction and a different resumed instance, and checks engine identity plus `FLAG_SECURE`.
The still-running Dart fixture then probes a server-side shell variable and rejects reconnects.
All six combinations of plain SSH, tmux and control mode with keep-alive off/on completed both
transitions, including the lock and intent checks. The first complete Dart run exposed a native
teardown issue: finishing and relaunching leaves old tasks in Recents without a live Activity.
Cleanup now removes those app-owned task records and still requires zero remaining tasks.
The complete host profile subsequently passed: 2 tests executed, 0 skipped, including native
teardown. It recorded 14 successful Activity destruction/replacement transitions: two per shell
combination plus two lock/intent transitions. Final local validation is recorded below; hosted validation will run on the signed checkpoint.

**The event-channel explanation in the earlier A entry was wrong.** Flutter replaces a channel's
handler without cancelling its existing subscription. The new handler has no active sink, so the
next cancel reports `No active stream to cancel` and does not release the bridge's sink. Both
channels reproduced this on the device. Each now retains its event handler for the engine's
lifetime, refreshes Activity-scoped method handlers on every attachment, and still guards callbacks
from superseded engines. The device guard exercises the real cancel/listen protocol across both
transitions, plus the real notification Resume and Disconnect actions.

**A posted SSH notification could not resume its terminal.** The service puts the session ID in
`omniterm://notification/session/<id>`, while the receiver read only an extra. Flutter also treated
that URI as an automatic named route, producing an undefined-route exception. A negative control
using the real posted notification's `PendingIntent` reproduced both symptoms against the original
receiver. The receiver now reads the session URI, and automatic Flutter deep linking is disabled
so the existing app-lock-aware intent handler is the sole dispatcher. The lock guard checks that
an intent waits behind the lock across recreation, is consumed once after PIN unlock, and later
intents still arrive. No process-death survival is claimed.

**Reconciliation with main.** The already-shipped Kotlin/dependency changes are incorporated into
the migration branch. The only conflict was the detector script's explicit absent-workflow handling;
main's compatibility guard is retained, without counting an absent workflow as a passed check.

**Limits retained from the review.** The historical key-generation cleanup failure has not been
reproduced deterministically. Its original job log shows one surviving card and an earlier harness
transport reboot; it does not establish either duplicate keys or a general environmental cause.
The newer clipboard guard tests the payload sent to Android; it is not clipboard readback proof.
The current working agreements explicitly keep hosted instrumentation data-layer-only and require
the complete local package plus an opted-in surface sweep, so the hosted filter remains unchanged.

Validation on the final source tree:

- `./scripts/local-pr-check.sh --full` passed on Linux x86_64 on September 17. Native unit/lint
  tasks were `UP-TO-DATE`, not freshly executed. Flutter analysis and formatting passed; Flutter
  tests executed 2,730 successfully with seven optional skips (six `OMNITERM_SETUP_FIXTURE` cases
  and one `OMNITERM_COMPRESSION_*` case). No Linux ARM64 runtime exclusions applied on this host.
  Release APK/AAB, both Flutter SBOMs, development-code exclusion, the pinned all-ref secret scan,
  and forced-refresh strict verification of all native graphs and both release SBOM graphs passed.
- `./scripts/flutter-device-test.sh --device emulator-5554 --profile core` passed: 30 executed,
  zero skipped, including every Flutter route/subtab/theme/orientation and native picker/permission
  flows. The `--profile host` run passed: two executed, zero skipped. Its initial Podman failure
  was reproduced directly as a stale boot-ID error; recreating only that disposable fixture fixed
  readiness before the successful rerun. No app assertion or timeout was weakened.
- `./gradlew connectedOpenSourceDebugAndroidTest` ran the whole native package on API 35:
  58 discovered, 24 executed successfully (including four Room tests), 34 opt-in E2E assumptions,
  zero actual failures. This ran after the full gate, whose device phase explicitly said deferred.
- After reinstalling the application and instrumentation APKs once, direct instrumentation ran
  `E2eLabHostProvisioner#provisionLabHost` and `#trustLabHostKey` against the repository SSH fixture.
  `E2eAppSurfaceStressTest` then passed on September 19 with `-e omniterm_e2e_surfaces yes`
  and `-e omniterm_e2e_sftp_home /config`: one executed, zero skipped. Gradle had removed the test
  APK after its connected run; the first provisioning attempt therefore never ran a test.
- Both diff checks and the pinned staged secret scan passed. No production/test source changed
  after the full gate; subsequent changes are this evidence record.

The signed checkpoint and its exact-head hosted checks are the remaining publication steps.
Do not reuse incoming-head CI results for this source. Earlier evidence below belongs to the
historical heads named there.

## C, D, E: three more places that finished work and said nothing

**C — every long operation's foreground-service start was discarded.** `start()` returned `bool`
and all seven call sites across six view models did `unawaited(...)`. The same tri-state collapse as
`SessionService`: "iOS has no foreground service", "no plugin registered" and "Android refused" all
arrived as `false`. A user starting a backup, deploy, fleet broadcast, transfer or share scan
expects it to survive switching away, and silently it would not. `start()` now returns
`ok`/`unsupported`/`failed(detail)`, and each screen reports a genuine refusal through its existing
error surface — phrased as *"This may not keep running if you leave the app"*, because
`ForegroundServiceStartNotAllowedException` means nothing to the person holding the phone.
`unsupported` stays silent by design. Fleet was the exception: it has only per-host row notes, and a
service refusal is not per-host, so it got a small dedicated warning above the results.

**D — four cancel paths in the backup flow said nothing.** Export passphrase, import passphrase,
restore selection, restore confirmation. The last two matter most: by then the file has been read
*and decrypted*, so a blank screen leaves the user unable to answer the only question a restore
raises — did anything change? All four now say so explicitly, and none is styled as an error,
because the user chose it.

**E — disconnect-all lost failures and showed no progress.** `terminate` wrote straight to `_error`
inside a loop, so the second failure overwrote the first; a user disconnecting three hosts saw one
message and had no idea the other two were still running on their servers. It now *returns* the
failure and `disconnectAll` aggregates them with host names. It also had no busy state despite
costing two SSH round trips per host, and its own button stayed enabled — now `isDisconnectingAll`,
a "Disconnecting…" label, and a refused second run. The caller navigated away regardless; it now
stays put when anything could not be confirmed stopped, rather than hiding the message naming it.

### Controls

D and E each needed a second attempt to produce a real control. E's first control failed to
*compile* against `HEAD` because `isDisconnectingAll` is new, which proves nothing behavioural;
isolating the aggregation test (which uses no new API) produced the genuine before-symptom — a
single unnamed failure where two hosts had failed. D's pre-existing test asserted `vm.status == null`
under the reason *"cancelling must not produce a file"*; `status` was only ever a proxy, so it now
asserts `files.saved` is empty and `statusIsSuccess` is false, which is what it always meant.

### A process failure, twice

Item C's gate was launched and then the tree was edited for D; the same happened again for E. A
validation whose tree changed underneath it describes a tree that never existed, so both runs were
discarded and C+D+E were validated together on a settled tree. The rule for a multi-item checklist:
batch the edits, validate once, commit, *then* start the next item.

### Validation

Every stage green: `core rc=0`, `host rc=0`, `local-pr-check rc=0`, both diff checks `0`,
`FAILED=0`.

## B (§1): audited under retention, no change needed

**Historical status.** The September 17 live test above now exercises the lock and consume-once
behavior through actual Activity destruction; the earlier missing-trigger limitation is superseded.

Both halves hold, and retention makes one of them *safer* rather than riskier.

**External launches consumed once — holds by construction.** `consume()` strips the intent: extras
removed, the `omniterm://` data URI nulled, the action reset to `ACTION_MAIN`. On the Dart side
`takeInitialActions()` sits behind a per-`State` `_initialExternalRead` flag, and with a retained
engine the widget tree survives recreation, so that `State` is never rebuilt and the call cannot
re-run. The replay risk would have come from a *restarting* isolate re-reading a fresh Activity
intent — which is exactly what retention prevents.

**App-lock protection — survives for the same reason.** The lock state and `AppLockGate`, with its
`ExcludeFocus` over the whole tree, live in the Dart isolate that now persists across recreation. A
locked app stays locked. The PIN throttle is separately persisted, so it survives process death too.

Recorded as **audited, no defect found** — deliberately not as "verified on device". Proving it on a
device needs the same controlled recreation trigger that A and the continuity item both died on.
**Three items are now blocked by that one missing capability**, which makes it the highest-value
thing for a next session to solve: a JVM test source set for `flutter_app/android`, or a
recreation trigger reachable from a Patrol test.

## A (§1): a superseded `onCancel` could silently kill notification delivery

**Historical explanation, corrected by the September 17 review above.** Handler replacement does
not trigger the claimed cancellation. The new live guard and engine-owned registration supersede
this account and its harness limitation.

Engine retention turned a dormant issue into a live one. `ExternalLaunchBridge` and
`SessionServiceBridge` hold their Dart `EventSink` at object level and cleared it unconditionally in
`onCancel`. That was harmless while the engine died with the Activity — each bridge had exactly one
registration for the life of the process.

With the engine retained, the replacement Activity re-registers a handler for the same channel,
Flutter tears down the previous stream, and **that teardown's `onCancel` arrives after the new
handler has already attached** — so the superseded registration nulls the *live* sink. The symptom
is silent and delayed: launcher shortcuts, notification resumes and shade actions (Disconnect,
Disconnect all, Resume) stop reaching Dart after the first recreation, queueing into `pending`
forever, with nothing logged at the moment it breaks.

Both bridges now record which registration owns the current sink. A superseded `onListen` will not
install one; a superseded `onCancel` will not clear one.

### The guard for it was removed, because it could not fail

An assertion was added to the native recreation guard and then taken out again. Measured, from the
device logcat immediately before `recreate()`:

```
OmniTermSinkGuard: before recreation: externalLaunchSink=false sessionServiceSink=false
```

Both sinks are already null at that point, because the native guard runs *after* `runDartTest`
returns and Dart has torn its subscriptions down — the same structural limitation the incoming
handover noted about this guard ("recreates the Activity AFTER Dart fixture cleanup"). An
unconditional assertion reported that ordinary teardown as a lost sink; a conditional one skipped
every time. Either way it proved nothing, so it is gone rather than left looking like coverage. The
`hasLiveSink()` accessor added for it was removed too, rather than left as dead production surface.

**What would actually test this:** a JVM test source set for `flutter_app/android` (the ownership
logic extracts cleanly into a Flutter-free class), or a Dart-visible recreation trigger — which is
itself the measured dead end recorded further down. The fix is small and its reasoning is written at
the call site; it is recorded here as *fixed but unproven in this harness*, not as covered.

## Outstanding handover items — tracked goal

An earlier revision of this tracker claimed the incoming handover's four sections were complete.
**That was wrong** and is corrected here. §0 and §4 are genuinely done; §1 and §3 have named
sub-bullets outstanding; **§2 was misread** — it asks for a *native* (Compose) fixture proof, and
what was delivered was Flutter widget coverage. `FleetScreen.kt:190` carries all three popups and
no Kotlin `androidTest` covers them.

Worked in this order, most load-bearing first. Each item is done only with a negative control where
one is possible, the full gate, and device profiles for anything a screen can reach.

| # | Item | Source | State |
| --- | --- | --- | --- |
| A | Engine-owned event subscriptions across Activity attachments | §1 | **implemented and device-verified; final CI pending — see September 17** |
| B | App-lock protection across recreation; external launches consumed once | §1 | **device-verified; final CI pending — see September 17** |
| C | `LongOperationNotifications.start` returned failures are ignored at all call sites | §3 | **done** |
| D | Passphrase / restore-selection / confirmation cancellation are silent | §3 | **done** |
| E | Disconnect-all needs observable completion/errors and cleanup ownership | §1 | **done** |
| F | Native (Compose) fixture proof for all three Uptime/DF/PS popups | §2 | **done** |
| G | Compose Update delayed stdout/stderr and local-build fallback; mutation-warning audit across Fleet/containers/stacks | §2 | **done** |
| H | Completion while the Backup screen is unmounted; untested routes/error/cancel sweep; cross-app identity and overflow | §3 | **done** |

A is first because engine retention (`5c99960`) is what made those bridge lifetimes matter: they now
outlive the Activities they were registered against.

Already closed and not to be reopened: §0 (change detectors), §4 (Dependabot #102/#103/#104), the
engine retention/FLAG_SECURE/Quit trio, the four preflight bugs, bastion parity, the pool key, and
the latency measurement. Device-initiated recreation continuity is a **measured dead end**, recorded
below — 120 MainActivity lifecycle events, 0 destructions.

### F — the three Fleet diagnostics, proved natively (`4b42c7c`)

`FleetDiagnosticStreamingRobolectricTest` drives the real `AppViewModel` over an injected transport
that streams one chunk, holds, then streams a second. It asserts each of Uptime/DF/PS sends *its
own* command (the screen pairs label to command by hand), that output appears while the command is
still running rather than only at completion, that the popup names the host it dialled, and that
`broadcastCommandText`/`broadcastTargetMode` are untouched.

Robolectric, not instrumentation, on purpose: root-package instrumentation tests are filtered out of
the required CI checks, so an `androidTest` here would have run in no gate at all.

### G — Update's runtime behaviour, and the warning rule made checkable

**Streaming.** `ComposeCommandTest` already pinned what the update *script* contains. What it could
not show is how the app behaves while that script runs, and update is the slowest action in the app
— a registry pull then a local image build, minutes apart.
`ComposeStackUpdateStreamingRobolectricTest` holds the stream open on a channel so the test decides
exactly when each stage lands. It proves stages appear progressively (not batched at exit), that a
non-fatal pull failure stays readable to the end — the only evidence the image was built locally
rather than pulled — that the button sends the audited script *once* and never replays it, and that
a stack with no compose working directory dispatches nothing and says why.

Negative control: disabling the progressive append in `runStreamingAction` failed both streaming
tests; the command-wiring tests correctly kept passing, since they test something else.

**Mutation warnings.** Fleet is consistent (read-only diagnostics one tap; broadcast confirms,
lists every target host and escalates to `destructive` via `fleetCommandDangerWarning`). Containers
and services are consistent. **Stacks had drifted**: `up` (UP -D) and `pull` sat in the mutating row
with every sibling confirming around them and went straight to the daemon unwarned — while the
*identical* UP -D offered on a downed stack did confirm, and the live-stack path is the more
disruptive of the two because running containers get recreated.

The drift was invisible because the decision lived in a `when` inside a composable, where nothing
could check it. It is now `StackActions.kt`: the two button lists and the warning copy as values,
with the screen rendering from the same lists. `StackActionConfirmTest` holds the rule — every
mutating action warns and names its stack, read-only ones return null, and `down` is pinned as the
*only* exemption (its dialog also carries the remove-orphans choice), so a new destructive button
cannot quietly join it. Writing that test immediately caught a second, smaller drift: `removeOrphans`
was the one warning whose title did not name the stack, which matters most here because the page
repeats these buttons down a list of many stacks.

Negative control: removing the `up`/`pull` entries reproduced the original defect as three failures,
including `expected:<[down]> but was:<[pull, up, down]>`.

### H — a finished backup that nobody was watching (partly done)

`backup_screen.dart` recorded the save outcome only `if (context.mounted)`. Saving hands off to the
system file picker — a separate Activity — so the screen is routinely unmounted behind it, and since
engine retention (`5c99960`) the view model reliably outlives it. The result: a backup that was
really written recorded nothing — no confirmation, **no last-export timestamp** — and a failed save
was dropped the same way. Returning to the screen showed no trace that the export had happened.

The guard was on the wrong side of the line. `BackupViewModel` is app-scoped
(`main.dart:406`), so `vm.report*` is always safe; only UI work needs `mounted`, and
`_revealFeedback()` already makes its own check. The outcome is now recorded unconditionally. The
matching silent drop just above it — screen closed after the backup was built but before the picker
opened — now reports rather than returning quietly.

Negative control: with the original guard restored, the new test fails on `vm.statusIsSuccess` while
`files.saved` still has length 1 — the file written, the app unaware. Exactly the defect.

Audited and left alone: `_import` already records completion ungated, its `mounted` checks guard
only `showDialog`, and cross-app identity/overflow is already covered by `backup_payload_test.dart`
(additive restore, credential-profile id remapping, renamed-duplicate mapping) — restore is additive
by design and the confirm dialog says so, so nothing silently merges duplicate rows.

### H, continued — the routes/error/cancel sweep

**The first pass at scoping this was wrong and is corrected here.** A static scan for `ValueKey`s
that no test file mentions reported 58 untested cancel/confirm/error paths. That number is not real:
a key no test *names* is not an untested path, because most of these dialogs are driven by text and
tooltip finders instead. Checked one at a time, by behaviour: auth-key and credential-profile
deletion (including the blast-radius warning that names dependent hosts), SFTP delete, single image
and volume removal, and scripts/shares/tunnels/alerts deletion are all already covered.

Three genuine gaps survived that check, all of them destructive, and all now closed:

- **Bulk host delete — the dialog itself.** `servers_view_model_test` calls
  `deleteSelectedServers()` directly, which bypasses the dialog, so nothing covered the wiring: that
  it appears, that Cancel cancels, that Delete removes only the selection. A confirm wired to the
  wrong branch passed every existing test. Its Cancel button had no key at all; it has one now.
  Control: wiring Cancel to the destructive branch empties the fleet (`length of <2>` vs `[]`).
- **Cron delete — the confirm branch.** Only the cancel branch was exercised. Deleting one job
  rewrites the entire crontab, so the risk is not that the line survives but that everything else
  disappears with it. Control: dropping non-job lines from `renderCrontab` loses `MAILTO` and the
  comments, and the test says so.
- **Bulk image and volume delete.** Implemented inline in `infra_tabs.dart`, with no view-model
  method, so no view-model test could reach them. They loop over a selection, so a stale or wrong
  set removes rows the user never ticked — and neither images nor volume data can be recovered.
  Control: ignoring the tick set removes both fixtures instead of one.

Read-only actions were left one tap throughout, per the handover's "keep read-only actions
lightweight".

## Branch split — the Kotlin fixes now have their own PR to main (2026-09-15)

The checklist above was worked entirely on `migration-to-flutter`, which meant every native Kotlin
fix and every Dependabot update sat behind PR #92 and could not reach `main` until the whole
migration merged. `main` ships the Kotlin app today, so that was a real delay, not a bookkeeping
detail. **PR #105 (`kotlin-bug-fixes` -> main)** now carries them:

- Dependabot's own commits for the android-dependencies group (15 updates) and the github-actions
  group (5 updates), cherry-picked with authorship preserved. They were based on `bf227d2`, which
  *is* main, so they applied clean. `main` had still been pinning `deploy-pages@v5.0.0`.
- `verification-metadata.xml` **regenerated on that branch** with
  `scripts/refresh-verification-metadata.sh --write`, not copied from the closed companion PR #103,
  whose checksums were computed against a different dependency set.
- 43 native Kotlin files, +2807/-423 — the fixes that had accumulated here.
- The change-detector fix, which `main` still needed: its `codeql.yml` and `android-pr-check.yml`
  both carried the `echo "$changed" | grep -q` form that silently selects "nothing changed".

**Nothing was reverted here.** `app/`, `gradle/libs.versions.toml` and
`gradle/verification-metadata.xml` are byte-identical across the two branches, so the split costs no
rework when PR #92 lands.

Not ported to main, deliberately: the Flutter-only CI (`flutter-pr-check.yml`,
`flutter-release.yml`, `flutter-device-test.sh`, the Flutter SBOM scripts) and the
`test-flutter-device-preservation.sh` step this branch adds to `android-pr-check.yml`. Taking that
file wholesale would break main, so only the detector hunk was spliced across.

Both PRs are green: #92 on `3818004` and #105 on `67150e6`, each with CodeQL genuinely analysing
(8m56s job, companion no-op skipped) rather than reporting green off the placeholder.

## Historical September 13 handoff

For current work, start at the September 17 return review at the top of this file. The cutoff,
retired schedules, and checkpoint statuses below apply to the earlier session only.

**Codex-to-Claude handoff cutoff: September 13, 2026 at 10:30 AM IST today (05:00 UTC), not tomorrow.**
Implementation stopped before cutoff. The external cutoff fired at 10:30:00 IST and queued
finalization at 10:30:01; private handover finalized at 10:32, then this public summary was corrected
after the queued cutoff message arrived. Both outgoing continuation and cutoff timers are now
verified disabled/inactive, with successful delivery and no retry pending. Operational details:
`secrets/internal-docs/docs/CLAUDE_HANDOFF_2026-09-13.md`.
Stale `continue` messages must not restart implementation or recreate the retired schedule. This is a
handoff, not a claim that the whole review is complete. Claude must return an equivalent detailed
handover and a ready-to-use prompt for Codex to independently review and finalize the codebase.
The cutoff retires the outgoing Codex session; it does not forbid Claude's subsequently authorized
continuation from the handover.

**Return handover for Codex:** `secrets/internal-docs/docs/CLAUDE_TO_CODEX_REVIEW_2026-09-13.md`
(private, gitignored). It carries the per-checkpoint evidence, the negative-control counts as finds
versus guards, the two claims this session did **not** prove, the CI-filter decision left to a
human, running jobs with stop commands, and a ready-to-use prompt asking Codex to review these
changes independently. It is kept current as work proceeds rather than written at the end.

**Claude session resumed from that handover on 2026-09-13.** It did not revive the retired Codex
schedule. Claude Code has no external, session-targeted `queue` command equivalent to the Codex
adapter in `AGENTS.md`, so its 30-minute `continue` schedule runs on the client's own in-session
scheduler instead of a `systemd --user` timer. That is a real weakening of the requirement and is
recorded rather than glossed: the schedule does not survive the client process exiting, and it fires
only while the session is idle. Everything else in the continuation rules is unchanged.

### Final checkpoint and CI snapshot

- Signed/pushed source checkpoint and actual PR head:
  `b691ddd5ea66beebcdcfd3cd347b14216a4f88ee`, signature G. Worktree was clean at 10:33 IST.
  This final documentation-only correction to `WORK_PROGRESS.md` is intentionally uncommitted;
  no production/test edits remain. Preserve it for the incoming agent's next validated checkpoint.
  Do not supersede still-running exact-head CI merely to publish a final status correction.
- At 10:33 IST, native Build & Test and release SBOM succeeded; Room still running in run
  `34738906013` (Room job `103675867004`). Flutter Analyze/Test, Android release/SBOM and iOS
  succeeded; emulator still running in run `34738905988` (job `103675128133`).
- CodeQL run `34738905986` reported success but actual Analyze Java/Kotlin job `103675129381`
  was **skipped**. Only the no-code-change placeholder succeeded, despite native paths in the
  detector's changed-file list. This is an unresolved security-gate bug, not CodeQL coverage.
  The `echo "$changed" | grep -qE ...` detector under `pipefail` can reject an early match when
  the writer receives SIGPIPE. A controlled small-pipe regression reproduced that mechanism;
  default local runs did not reproduce it. Fix/test the detector and audit equivalent workflows.
- Dependency review (`34738905957`), Scorecard analysis (`34738905964`) and both secret scans
  (`34738905962`, `34738904792`) succeeded; separate Scorecard check neutral. Unselected docs-only
  companions are skipped, not platform passes. Detailed new CI test counts remain to be audited.
- PR remains REVIEW_REQUIRED and incomplete. A read-only exact-head watcher remains active;
  its private service/log/recovery details are in the handover. Even a successful watcher exit
  cannot prove the skipped real CodeQL analysis ran. Inspect actual jobs and terminal results.
- No Claude launch, merge, release, test termination or protection changes. The incoming agent
  must finish the CI/security gate and remaining work below and leave a reciprocal Codex handover.

1. Read `AGENTS.md`. Inspect `git status`, `git log -5`, and the remote branch before editing.
2. Check PR #92's **actual head SHA** and all its checks. Signed checkpoints `64d8e23` and
   `925ae3c` were pushed; the latter reconciles `main` (`bf227d2`) into this branch without changing
   the validated source. All `925ae3c` checks finished, but three jobs failed (details below).
   Replacement CI-repair checkpoint `500f35d` was signed and pushed. Native Build & Test, API 29
   Room, native release SBOMs, CodeQL, dependency review, Scorecard analysis, both secret scans,
   Flutter analysis/tests, Android/iOS builds and emulator testing passed. All selected jobs on
   that exact head reached terminal success; the separate Scorecard result is neutral. Skipped
   jobs are unused docs-only companions, not missing platform gates. Never infer CI success from
   local results or reuse these results for the next source checkpoint. Later SSH checkpoint
   `85f5cfe` had one terminal Flutter surface failure. This checkpoint contains the locally
   validated swipe/runner repair below; its replacement exact-head CI must still be monitored.
3. Preserve the existing fixes. Finish the remaining investigations below in small batches; run
   the required validation, update this tracker, commit with signing enabled, push, and monitor
   every selected check to completion before publishing the next replacement head.
4. For an incoming agent, keep its own session-targeted continuation active while work remains,
   as required by `AGENTS.md`. Re-establish it on a replacement machine using that client's own
   verified mechanism; local timers do not survive loss of the original host.

Useful read-only recovery commands:

```sh
git status --short
git log -5 --oneline
gh pr view 92 --json headRefOid,statusCheckRollup,reviewDecision
gh run list --branch migration-to-flutter
```

The earlier `925ae3c` merge conflicts were only in `AppUi.kt` and `AppViewModel.kt`: preserve visible recovery
feedback, transport-generation ownership/cancellation, and batched recovery persistence. All
incoming hotfixes were already present. Before this tracker-only edit, the resolved merge tree
was byte-identical to checkpoint `64d8e23` (tree `44ac3dc54ff8690544e4a36d00abab5a1a33647a`).
That merge changed no build-affecting source. The newer SSH setup batch below has its own validation.

## Change-detector repair — CodeQL was never analysing this PR

`b691ddd` is now terminal on every selected check and every one of them reports success, but
**`Analyze Java/Kotlin` passed in 3 seconds**: that is the `analyze-skip` companion no-op, not
CodeQL. The `Detect code changes` job (run `34738905986`, job `103675118702`) listed
`app/build.gradle.kts` and 525 further `app/` paths in its own log and still set `code=false`,
so the real analysis job `103675129381` was skipped. The green checks list was hiding the fact
that no security analysis had run on this branch at all.

**Cause.** All three PR detectors decided with `if echo "$changed" | grep -qE '<include paths>'`
under `set -uo pipefail`. `grep -q` exits at its *first* match and closes the pipe. Once the
changed-path list is longer than grep's first read, the producing `echo` is killed by SIGPIPE
(141); `pipefail` reports the pipeline as 141 even though grep matched, the `if` takes the else
branch, and a build-affecting PR is classified as docs-only. The longer the PR, the likelier the
required analysis silently disappears.

**Reproduction.** A default local run does *not* reproduce it — `b691ddd`'s real list is 28,959
bytes across 580 paths, just under the buffer where it tips. Feeding the same detector a matching
path followed by 40,000 further paths reproduces it deterministically on GNU grep 3.12
(`PIPESTATUS` `141 0`, pipeline 141, `code=false`); the threshold on that host is between 16 KB
and 48 KB of changed paths. Note the local host's `grep` in some interactive shells is `ugrep`,
which does not reproduce this at any size — reproduce with `/usr/bin/grep`.

**Fix.** `codeql.yml`, `android-pr-check.yml` and `flutter-pr-check.yml` now write the changed-path
list to a file and match the file, so there is no pipe and no producer to kill. `grep` status 0 is
a match, 1 is genuinely no match, and anything above 1 is a real error that fails safe to
`code=true` exactly like the existing `git diff` failure path — previously a broken pattern or
unreadable input would also have been read as "nothing changed". `mktemp`/write failures fail safe
the same way. Behaviour is otherwise unchanged: include prefixes stay anchored, and `push`/
`schedule` still force `code=true` so the main prerelease gate never skips.

**Regression test.** `scripts/test-change-detectors.sh` extracts the *real* `run:` block out of each
workflow (failing loudly if an unsupported `${{ }}` expression appears in one) and executes it
against a stubbed `git`, so it tests the shipped detector rather than a copy. 39 checks across the
three detectors: matching path first in a 40,000-path list; a deliberately non-draining matcher,
which pins the behaviour independently of the host's grep; matching path last; the 580-path shape of
the head that actually skipped CodeQL; docs-only; include prefixes still anchored (`docs/app/...`
must not trigger); paths containing spaces, matching and not; an empty diff; `git diff` failure;
`grep` error; and `push`/`schedule`/`workflow_dispatch` on CodeQL. It also fails if the
`echo … | grep` shape reappears in a workflow.

**Negative control.** The same script run against the unfixed `HEAD` detectors fails 12 of 39 —
the SIGPIPE case and the grep-error case, in all three workflows, each returning the production
symptom `code=false` for a genuinely matching list. The other 27 checks pass on the old code, so
the suite is targeted rather than vacuous.

The test is wired into `scripts/local-pr-check.sh` and into the same "validate tooling" steps that
already run `test-release-engine.sh` in `codeql.yml`, `android-pr-check.yml` and
`flutter-pr-check.yml`; `test-change-detectors.sh` was added to the Flutter detector's own include
list so changes to it can trigger that gate. A detector job cannot catch its own false negative
(if it skips, the test skips with it), but `push` to `main` always sets `code=true`, so the
prerelease gate always executes it.

**This does not mean CodeQL has now passed.** It means the next pushed head is the first one whose
`Analyze Java/Kotlin` result can be believed. Until a real analysis job runs to completion on the
replacement head, this branch has no CodeQL coverage.

#### Validation for this tree

`./scripts/local-pr-check.sh --full` **passed** with `flutter` and `adb` on PATH and
`JAVA_HOME=/opt/java/temurin-17`. An earlier attempt exited 1 before the `--full` section purely
because `flutter` was missing from that run's environment — a harness error, not a result.

- Change-detector suite **39 passed / 0 failed**; the negative control against the unfixed detectors
  fails **12 of 39**, all three workflows, each returning the production symptom `code=false`.
- Flutter full suite **2676 passed / 4 optional live skips** — 3 `OMNITERM_SETUP_FIXTURE`
  setup-relay cases and 1 `OMNITERM_COMPRESSION_*` case, both needing a disposable OpenSSH fixture.
  `flutter analyze` clean in 6.5s.
- Native unit tests, **freshly executed** this run (not reused UP-TO-DATE results): each variant
  560 discovered = **558 passed / 2 skipped / 0 failures / 0 errors**. Both skips are
  `TmuxAltScreenReplayTest` capture cases (`no capture dir provided`); captures are unavailable on
  this host. No ARM discovery exclusion applies on x86_64; required CI still executes Robolectric.
- Flutter release APK + App Bundle, both release SBOM graphs, release test-code exclusion and
  strict forced-fresh dependency verification passed. No checksum metadata changed.
- Full-history secret scan: 200 commits, 14.97 MB, no leaks.
- **The connected device matrix actually ran this time** rather than being deferred:
  `connectedOpenSourceDebugAndroidTest` on API 35 `emulator-5554`, **58 tests = 24 passed /
  34 skipped / 0 failures**. Every one of the 34 is an opt-in `E2e*` case self-skipping through
  `assumeTrue` because its instrumentation arguments were absent. That explicitly includes
  `E2eAppSurfaceStressTest`, so **this run is not the required route/subtab/theme/rotation sweep**.
  It is not re-run here because this checkpoint changes no application source — only workflow YAML,
  `scripts/local-pr-check.sh` and a new test script. `b691ddd`'s device evidence still stands for
  the app itself.
- `git diff --check` and `git diff --cached --check` both clean.

## The clipboard readback needed a longer wait, not a weaker assertion

`crash_log_test`'s clipboard read failed on CI a second time, on the dependency head. Diagnosed
rather than assumed:

- **The earlier retry did run** — the failure carries its own message, and ~17s elapsed against a
  ~6s budget, so the budget was exhausted rather than skipped.
- **`about.copied` does mean what it claimed.** `_copy` awaits `Clipboard.setData` and only then
  sets the marker, so the platform accepted the write.
- **It is transient, not a platform denial.** This test passed on CI for nine of the eleven heads
  pushed in this session and failed on two.

So the budget is now 30 seconds of wall-clock rather than ~6. Waiting longer for a value that
cannot change costs nothing on the runs that succeed immediately.

The alternative was considered and rejected: dropping the clipboard readback and asserting
redaction on the stored crash report instead. That would be a weaker test of the thing this case
exists for — a password reaching the clipboard is the hazard, and reading it back through the real
clipboard is what makes the assertion about the path a user actually takes. The failure message now
also names the focus assumption as the thing to re-examine if it recurs, rather than stating it as
fact.

### Validation for this tree

Every stage green: `core rc=0` (which contains `crash_log_test`), `host rc=0`,
`local-pr-check rc=0`, both diff checks `0`, `FAILED=0`.

### CI result for the dependency integration

`0ce8d02` reached terminal state with **everything green except this one flaky test**: `Build &
Test`, `Analyze Java/Kotlin`/CodeQL, `Validate Room migrations`, `Validate release SBOM generation`,
`Build iOS`, `Build release artifacts`, dependency review, both secret scans and supply-chain
analysis all passed **on AGP 9.4.0 with strict checksum verification against the regenerated
metadata**. That is the evidence local runs cannot substitute for, and it holds.

## Dependabot's open groups integrated into this branch

The automated PRs the incoming handover listed (#99/#100/#101) are all **closed** — Dependabot
superseded them while this review ran. The live set was #102 (android-dependencies, 15 updates),
#103 (its verification-metadata regeneration) and #104 (github-actions, 5 updates). All three are
now merged into this branch and closed as superseded by it.

**Compatibility review before taking anything.** #102 is entirely build and test tooling minors:
AGP 9.3.2→9.4.0, Compose BOM 2026.09.00, KSP 2.3.12, Navigation 2.10.1, Room 2.8.4→2.8.5,
robolectric 4.17, roborazzi 1.74.0, benchmark 1.5.0, develocity 4.5.1. No SSH, ads or consent
majors, so no compatibility hold applies. `smbj` — the one network library in the group — was
**already at 0.15.0 on this branch**, so the merge introduces no new network-library change. #104
keeps full SHA pins with version comments on all five actions.

**The `codeql.yml` collision was the one to watch.** #104 bumps action SHAs in the same file this
branch's change-detector fix rewrote. It auto-merged, and was verified rather than assumed
afterwards: the file-based matcher and its fail-safe grep-status handling are intact, no
`echo`-into-`grep` shape returned anywhere, and `scripts/test-change-detectors.sh` still passes
**39/39** against the merged workflows.

**#103's metadata file was not used.** It was generated against `main`, and this branch is ahead of
`main` on several of the same libraries, so its checksums describe a dependency graph this branch
does not resolve. `gradle/verification-metadata.xml` was regenerated with
`./scripts/refresh-verification-metadata.sh --write` per the repository rule, and the diff audited:
**no removed entries, no new trust rules, `verify-metadata` still `true`**, and all 600+ added
artifacts carry both SHA-256 and SHA-512.

### One process failure worth recording

The first regeneration exited **143 — SIGTERM from a `timeout 900` in the wrapper**, not from the
script. The partial file it left behind differed materially from the complete one: **2035
insertions with 3 deletions, versus 2052 insertions and none**. It had dropped entries it never
re-added. Committing it would have failed CI's strict verification in a way that reads like a
Dependabot problem rather than a local one. An interrupted generation is not a generation.

### Validation for this tree

Every stage green: `metadata-verify rc=0` (forced fresh resolution across buildscript, app, test,
lint, instrumentation, benchmark and both release SBOM graphs), `core rc=0`, `host rc=0`,
`local-pr-check rc=0`, both diff checks `0`.

## Attempted and measured dead: forcing a real recreation from the device

The incoming handover asked for shell-variable continuity *through* recreation, not just engine
identity. The Dart lifecycle flow already sets `OT_LIFECYCLE=<token>` and re-probes it after each
`pressHome()`/`openApp()` cycle — the missing ingredient was a real Activity destruction for those
probes to cross.

**Every obvious lever is ruled out by the manifest.** `configChanges` covers
`orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode`,
so Android calls `onConfigurationChanged` rather than restarting: rotation, dark mode (Patrol's
`enableDarkMode`) and font scale all do nothing here.

**Android's "Don't keep activities" was tried and does not work in this harness.** Enabling
`always_finish_activities` from the instrumentation via `UiAutomation.executeShellCommand`, around
the lifecycle flow only and restored in a `finally`, produced:

```
MainActivity lifecycle events observed: 120, of which destructions: 0
```

The counter proves the callback *was* watching — 120 events across the flow — and that **not one
destruction happened**. A direct `adb` check was inconclusive for a different reason: the
`ActivityRecord` stays in task history after Home, which describes the record rather than the
instance. Hypothesis for why, untested: the app holds a foreground service during these flows, and
that may keep the task out of the state the setting acts on.

**The first attempt passed and proved nothing.** With the setting enabled but no destruction
counter, the whole suite went green — the probes were crossing an ordinary background/foreground
transition exactly as before. The counter is the only reason that is known. Recorded because the
next attempt will be tempted by the same green result.

The attempt is reverted; `MainActivityTest` is back to the committed guard. What remains true:
engine identity and `FLAG_SECURE` survival are proven across a forced `recreate()`, and live-shell
continuity through a *device-initiated* recreation is still unproven. A working approach needs a
controlled recreation trigger that this harness does not currently have.

## One proxy, two pooled connections, over a trailing space

The follow-up flagged when the bastion parity fix landed. `SshSessionPool.poolKey` embedded
`proxyHost` **raw**, while `DartSshTransport` now dials `proxyHost.trim()` — so `"p"` and `" p "`
dialled the same proxy and opened two pooled connections, for a difference the user cannot see.

It is narrower than first sketched, and the narrowing is the interesting part:

- The key governs **pooled** connections only, and jump connections are leased `unpooled`, so
  `proxyUser` never reaches it on the bastion path at all.
- For `http`/`socks5`, a blank `proxyUser` means *no proxy authentication*, which is genuinely a
  different connection from an authenticated one. Normalising that would have merged two unlike
  connections.

So only `proxyHost` is trimmed. The tests split accordingly, and the control shows it: the
whitespace case **fails against real `HEAD`**, while the blank-proxy-user case **passes both ways**
— a guard pinning what was deliberately *not* normalised, so a later tidy-up cannot quietly merge
authenticated and anonymous proxy connections.

### Validation for this tree

Every stage green: `core rc=0`, `host rc=0`, `local-pr-check rc=0`, both diff checks `0`,
`FAILED=0`. This tree also carries the trigger correction above, which is comment- and
tracker-only.

## Where connect time actually goes — measured, and the hypothesis was right

The incoming handover recorded a hypothesis and was explicit it must be measured, never claimed:
"Flutter does not pool bastion clients, so sequential probes can each reauthenticate". Measured on
the repository's own fixtures (`test/dartssh_latency_live_test.dart`, opt-in via
`OMNITERM_SETUP_FIXTURE`):

```
direct  first exec (connect + auth + channel) : 152ms
direct  second exec (pooled connection)       :  45ms   3.4x faster
bastion first exec (jump auth + target auth)  : 265ms
bastion second exec (NOT pooled, by design)   : 264ms   no saving at all
bastion first-connect overhead vs direct      : 113ms
```

**These are loopback Docker containers on one machine.** The *shape* transfers; the milliseconds are
not a claim about any user's hosts, and must not be quoted as one.

**The hypothesis is confirmed.** The cause is explicit in `DartSshTransport._acquire`: a jump
connection is leased `unpooled`, so every `exec` through a bastion repeats the whole handshake —
bastion TCP, bastion authentication, `forwardLocal`, target authentication. The direct path pools
and shows it.

**It is parity, not a Flutter defect.** Compose does the same thing and says so: "Jump-host sessions
are not pooled" (`data/ssh/JschSftp.kt:29`). Both implementations share this limitation. Changing it
would alter the connection model on both platforms — an idle authenticated bastion session held open
is a security-adjacent decision, not a parity cleanup — so it is measured and recorded here rather
than changed.

### The first version of this measurement asserted nothing

It ended with `expect(secondJump, lessThan(firstJump))`, which passed on 269ms versus 279ms. That is
noise: it would have passed whether or not any reuse happened, which is precisely the guard that
proves nothing. The direct-path assertion is now `secondDirect * 2 < firstDirect`, far outside what a
loaded machine produces, and the bastion path **reports rather than asserts**, with the reason and
the `JschSftp.kt:29` citation written into the test. No wall-clock budget is asserted anywhere: it
would be flaky, and worse, it would read as a promise about user hosts.

### Validation for this tree

Every stage green: `core rc=0`, `host rc=0`, `local-pr-check rc=0`, both diff checks `0`,
`FAILED=0`. The harness adds a seventh optional live skip in the ordinary gate; its numbers come
from the explicit fixture run above.

## A saved server that connects in Compose failed in Flutter

Found by doing what the incoming handover asked *first* — "verify blank bastion user fallback/host
trimming parity with Kotlin" — before any latency measurement. Both halves were real.

| | Compose (`data/ssh/JschSession.kt`) | Flutter, before |
| --- | --- | --- |
| Blank bastion user | `proxyUser.ifEmpty { creds.username }` (`:164`) | passed `''`; the bastion refused authentication |
| Bastion host | dials `proxyHost.trim()` (`:114`, `:173`) | trimmed only when *deciding* `_isJump`, then dialled and host-key-verified untrimmed |

The trimming half is the sneakier one. `_isJump` tests `proxyHost.trim().isNotEmpty`, so a host
saved with a trailing space — what a paste or a soft keyboard leaves — passed the test and was then
dialled verbatim. It fails twice: the lookup, and the pinned host key, which is stored under the
trimmed name, so trust would not match even if DNS tolerated it.

The username fallback is scoped to the **jump** path only. For `http`/`socks5` a blank user means
*no proxy authentication at all* on both sides — `applyProxy` guards with `isNotEmpty`, and
`proxy_socket.dart` offers `_authNone` — so a fallback there would have invented credentials neither
side sends.

**Proven against the real fixture bastion, not a stub.** `omniterm-test-bastion` reaching the
internal-only `omniterm-test-internal-a`: both new cases fail against real `HEAD` with genuine
OpenSSH authentication refusals, and pass with the fix.

**Skip accounting:** the optional live skips go from 4 to 6, because these two need
`OMNITERM_SETUP_FIXTURE` and the Docker fixtures. In the ordinary gate they **skip** — their
evidence is the explicit fixture run above, not the suite total.

### Noticed while fixing this, not yet changed

`SshSessionPool.poolKey` embeds `proxyUser` and `proxyHost` **raw**. Now that the effective bastion
identity is `proxyUser.ifEmpty(username)` and `proxyHost.trim()`, two credential sets that dial the
same bastion identically — `"h"` versus `" h "`, or a blank user versus an explicit one equal to the
target account — still produce different pool keys and so open separate connections. That is
conservative rather than unsafe (a differing key never reuses a connection authenticated with other
credentials), but it defeats pooling in exactly the case the latency item is about. Normalising the
key to the effective values is the obvious follow-up and is deliberately left as a separate change,
because connection reuse is security-adjacent and deserves its own evidence.

### Validation for this tree

Every stage green: `core rc=0`, `host rc=0`, `local-pr-check rc=0`, both diff checks `0`,
`FAILED=0`. Flutter **2715 passed / 6 optional live skips**; `flutter analyze` clean in 7.0s.
Device profiles `core` 30/0 and `host` 2/0. Full-history secret scan: 212 commits, no leaks.

## SSH sessions no longer die when Android recreates the Activity

The defect the incoming handover called "proven unfixed". A default `FlutterActivity` creates its
engine in `onCreate` and destroys it in `onDestroy`, so **any** Activity recreation tore down the
Dart isolate. In this app
that isolate *owns the SSH sessions*: the foreground service kept the process alive, but nothing
kept the sessions alive, so every shell died on a configuration change while the notification still
claimed they were running.

### Correction: which recreations this app actually sees

An earlier version of this entry, and the commit message on `5c99960`, said the triggers were
"rotation, a theme or font-scale change, a system-initiated restart". **The first two are wrong.**
The manifest declares
`configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"`,
and Android calls `onConfigurationChanged` for a change the app declares it handles rather than
restarting the Activity. A rotation or theme switch never recreated this app.

What remains, and what the fix is actually for: **system-initiated destruction** — the Activity
reclaimed while backgrounded under memory pressure, the "Don't keep activities" developer setting,
and any configuration change outside that list. Backgrounded-and-reclaimed is the case a terminal
app cares about most, so the fix keeps its value; the trigger is simply narrower than first stated.
The before-proof below is unaffected: it forces `recreate()` directly.

### Before-proof, re-established on this tree

The parked patch applied cleanly. The guard failed, naming both engines:

```
AssertionError: Activity recreation must preserve the Dart engine that owns SSH sessions
  expected same:<FlutterEngine@a0a718c> was not:<FlutterEngine@614aa53>
```

That run is also the clearest example of the handover's warning that Patrol's Dart summary is not
the result: it reported **Successful: 1, Failed: 0** while the native JUnit run failed the build.
Read the JUnit XML, not the pretty output.

### What the embedding actually guarantees

Checked against the Flutter engine source in the local SDK rather than assumed, because the whole
design rests on it:

- `FlutterActivityAndFragmentDelegate.onAttach:228` calls `host.configureFlutterEngine(...)` on
  **every** attach, cached engine or not. That is what re-points the five Activity-holding bridges
  (`ScreenSecurity`, `ExternalLaunch`, `PlatformPermissions`, `CustomTabs`, `DeviceInfo`) at the
  live Activity, so none of them can capture a dead one.
- `doInitialFlutterViewRun:508` returns early when `isExecutingDart()`, so a retained engine does
  not re-run the entrypoint on the replacement Activity.
- `FlutterActivity.shouldDestroyEngineWithHost:1084` returns false once `isFlutterEngineFromHost`
  is set, which `provideFlutterEngine` does.

`provideFlutterEngine` was chosen over `FlutterEngineCache` deliberately: the cached-engine path
**throws** when the cache is empty and would require an Application subclass to pre-populate it.

### Retention alone would have broken two promises

**FLAG_SECURE.** A window flag belongs to a window, and a recreated Activity gets a new one. Dart
caches its last applied setting and only sends a *change*, so nothing re-sends `setSecure` after a
recreation — the replacement window would have come up unprotected, and on this app the
task-switcher thumbnail is captured automatically and routinely contains a live root shell.
`ScreenSecurityBridge` now remembers the requested state and reapplies it before the replacement
window renders. The device guard asserts it survived, but only when the fixture had it set, so it
cannot invent a protection the user never asked for.

**Explicit Quit.** "Terminate & Exit" tells the user that exiting terminates active background SSH
sessions, and that was true only by side effect: `SystemNavigator.pop()` finished the Activity and
the engine died with it. Retention removes the side effect, which would have turned that sentence
into a lie — a live isolate, open sessions and an ongoing notification after the user quit.
`AppExitBridge` now stops the foreground services, finishes the task, then destroys the engine —
replying *before* teardown, because destroying the engine closes the channel the call arrived on.
`AppExit` falls back to `SystemNavigator.pop()` on a missing plugin, a `PlatformException`, or a
`false` answer, so no build and no platform becomes unexitable.

### Validation

Every stage green: `core rc=0`, `host rc=0`, `local-pr-check rc=0`, both diff checks `0`,
`FAILED=0`.

- **The native engine guard now passes**: JUnit **1 test / 0 failures / 0 errors**, against
  1 failure in the before-proof above. It is a permanent repo test now, not a parked patch.
- Flutter full suite **2715 passed / 4 optional live skips**; `flutter analyze` clean in 6.3s.
  4 of the new cases are `app_exit_test.dart`, covering the fallbacks.
- Device profiles on API 35 `emulator-5554`: `core` 30 passed / 0 skipped, `host` 2 passed /
  0 skipped, no unexpected warnings. The three extra known warnings are javac
  `source/target 8 is obsolete` notices from the enlarged Java test file.
- Native unit tests reused UP-TO-DATE — the Kotlin that changed is `flutter_app/android`, compiled
  by the device debug builds and the release APK/AAB. Release artifacts, both SBOM graphs and strict
  dependency verification passed. Full-history secret scan: 211 commits, no leaks.

### Still open in this area

The guard proves engine *identity* across recreation and that FLAG_SECURE survives. It does not yet
prove a live shell keeps its server-side state through recreation — the stronger fixture test the
handover asks for, driving a shell variable through recreate/finish/relaunch, remains to be written.
App-lock behaviour across recreation and external-intent consume-once semantics with a retained
engine are likewise unverified here.

## Two of the three Fleet diagnostics had no coverage at all

The incoming handover said "Flutter already has this guard". True in shape, one third in coverage:
the streaming test covered **Uptime** only. DF and PS had none, so a wrong command, a button
dialling the wrong host, or a read-only diagnostic quietly consuming the Broadcast tab's unsent
command would have been caught for one button and missed for the other two.

All three are now covered, each asserting its own command reaches the transport, that output appears
as it arrives rather than only at completion, that a running command shows it is running, and that
Broadcast's tab, unsent command text and target selection are untouched. The original single-button
test was folded in rather than left duplicating the new Uptime case.

**This is a guard, not a find.** `runHostDiagnostic` is thin and correct and the three buttons are
generated from one list, so no defect is claimed. The guard was checked for the thing a guard is
usually wrong about — whether it can fail at all: mutating the wiring so every button sends `uptime`
fails DF and PS with `Expected: ['df -h'] / Actual: ['uptime']`.

### Validation for this tree

Every stage green: `core rc=0`, `host rc=0`, `local-pr-check rc=0`, both diff checks `0`,
`FAILED=0`. Test-only change; no production source touched.

## The notification prompt was landing on top of the file picker

`LongOperationNotifications.start()` fires the notification-permission request `unawaited`, and the
Backup **export** starts its operation and then opens DocumentsUI moments later — so Android stacked
two system surfaces on the same moment. The repository already knew: the device test's own helper
carried the comment *"Android can place that prompt behind DocumentsUI; after Back it becomes the
foreground Activity and Flutter cannot scroll or animate until it is answered"*, and worked around
it in the test rather than fixing it.

`ensureNotificationPermission()` is now separately awaitable. `start()` still fires it without
waiting — its original reasoning, that a delayed service start could outlive finished work and leave
Android showing an ongoing notification for nothing, is sound and preserved — and export awaits it
first, which makes `start()`'s own call a no-op. Deliberately narrow: there are **seven** `start()`
call sites across six view models, all `unawaited`, so changing `start()`'s contract would have
altered six unrelated flows. Import needs nothing: it opens the picker *before* any operation begins.

**The wait is bounded at 30 seconds, and that bound is not padding.**
`PlatformPermissionsBridge.request` keeps the pending `MethodChannel.Result` in a field and
completes it from `onRequestPermissionsResult`, so an Activity recreated while the dialog is up
loses the callback and the future never completes. That is the same Activity-destruction area listed
as the largest open item in the incoming handover.

### Two corrections this slice needed, both caught rather than noticed

1. **The first test measured the wrong thing.** It recorded call order and passed against real
   `HEAD`, because `unawaited(request())` still *initiates* the call synchronously — order is
   identical either way. It was observing initiation, not settling. Rewritten to hold the permission
   open with a gate and assert the picker has *not* opened; it now fails on `HEAD` with the exact
   production symptom, `Actual: ['permission', 'picker']`.
2. **The first fix hung the export on device.** Awaiting an unbounded permission request moved the
   whole export behind the dialog, DocumentsUI never opened, and both native picker tests timed out
   at `waitUntilVisible`. That traded an overlapping dialog for an export that cannot start — the
   worse failure. Hence the bound, and the device tests now answer the prompt where it actually
   appears instead of discovering it behind the picker.

This area proved subtler than its one-line description in the incoming handover. Treat the remaining
one-line items there as sketches, not specifications.

### The validation wrapper's own fix earned its keep immediately

The run that failed the device core profile reported `local-pr-check rc=0` and **`FAILED=1`**, unit
`SubState=failed`. Under the previous wrapper — which returned only `local-pr-check`'s result — that
same run would have reported green.

### Validation for this tree

Every stage green: `core rc=0`, `host rc=0`, `local-pr-check rc=0`, both diff checks `0`,
`FAILED=0`.

- Flutter full suite **2709 passed / 4 optional live skips**; `flutter analyze` clean in 7.0s.
- Device profiles on API 35 `emulator-5554`: `core` 30 passed / 0 skipped — including both native
  picker tests whose prompt handling moved — and `host` 2 passed / 0 skipped.
- Native unit tests reused UP-TO-DATE; no `app/` Kotlin changed. Release APK/AAB, both SBOM graphs
  and strict dependency verification passed. Full-history secret scan: 209 commits, no leaks.
- Control: **2 of 2** new widget tests fail against real `HEAD`.

## A cancelled backup showed a success message for a file that was never written

Three defects in the export/import feedback, and one in this session's own tooling.

**A stale success message survived a cancelled export.** `inspectBackup` and `importBackup` both
clear `_status` at the start; `exportBackup` alone did not. A user who exported, then exported again
and cancelled the file dialog, was left looking at "Backup saved to …" for a file that had just not
been written. The screen actively asserted something false.

**A cancelled save said nothing at all.** An existing widget test asserted exactly that silence, on
the reasoning that announcing a cancel is noise and nothing was written. That holds for a cancel
*before* any work — but by this point the backup has been built, and encrypted for a sensitive
selection, behind a "Creating backup…" spinner. Ending visible work with no result is what
AGENTS.md's app-wide rule forbids. The test was rewritten rather than deleted, with the old
reasoning and why it no longer applies recorded in the test itself.

**An empty chosen file was silently ignored on import.** Picking a file and having nothing happen is
the worst of both: the user cannot tell whether the app failed, the file was wrong, or the tap
missed. It now names the problem and says what a real backup file looks like.

### The device suite caught the fix being wrong, which is what it is for

A native Patrol test, `integration_test/native/backup_file_picker_test.dart`, asserted that a
cancelled save shows **no message at all**, to catch "a screen that reports success on the way *into*
the picker rather than on the way out of it". The first version of this fix failed it — and the
failure was correct, not merely a collision:

- The message card painted **every** non-error status green, the colour the user reads as success.
  The new message would have said "Nothing was written" in the success colour, which is worse than
  the silence it replaced. The view model now distinguishes a status that reports completed work
  (`statusIsSuccess`) from one explaining why none happened, and only `reportSaved` and the restore
  summary set it; the card uses the neutral accent otherwise.
- The device assertion was then **strengthened, not relaxed**: "no message exists" was a fair proxy
  only while the sole possible message was a success claim. It now reads the rendered text and
  requires that it does not contain `Backup saved` **and** does contain `Nothing was written`,
  which also catches a message that wrongly claims success — something the old form could not.

### And one in this session's own tooling

The validation wrapper ended with `exit $rc`, where `$rc` was only `local-pr-check`'s result. The
run that failed the device core profile therefore exited **0** and reported green. That is the same
defect class this whole session has been fixing — a layer reporting success without doing the work —
sitting in the harness used to prove the fixes. The wrapper now records every stage and fails if any
one of them did. Any earlier run in this session that reported only `local-pr-check rc=0` was still
accompanied by an explicitly quoted `core rc=` / `host rc=` line, so no result already recorded here
depends on the broken propagation; but re-read those lines rather than trusting the unit's status.

### Validation for this tree

Every stage green under the fixed wrapper: `core rc=0`, `host rc=0`, `local-pr-check rc=0`, both
diff checks `0`, `FAILED=0`.

- Flutter full suite **2707 passed / 4 optional live skips**; `flutter analyze` clean in 6.4s.
- Device profiles on API 35 `emulator-5554`: `core` 30 passed / 0 skipped — including the native
  picker test whose contract changed — and `host` 2 passed / 0 skipped.
- Native unit tests reused UP-TO-DATE; no Kotlin changed. Release APK/AAB, both SBOM graphs and
  strict dependency verification passed. Full-history secret scan: 208 commits, no leaks.
- Control: **3 of 3** new widget tests fail against real `HEAD`.

## The backup screen forgot what the user chose, and mis-stated when it saved

**A failed selection read reverted to "everything", permanently.** `loadSelection()` set
`_selectionLoaded = true` *before* the await, so a read failure marked the selection loaded anyway:
the screen fell back to the default and every later call returned early instead of retrying. The
default is *everything*, so a user who had deliberately excluded credentials or crash logs would
have had them back in the exported file without being told — the wrong direction for that mistake
to go. The flag is now set only after the read succeeds, with a separate in-flight guard so
repeated calls from `build` do not stampede, and the user is told the shown selection is not theirs.

**A saved file could look unsaved.** The `backup_last_export_time` write is fire-and-forget. When it
failed, `_lastExportTime` was still set in memory, so the screen said "last backup: just now" — and
the next launch read the old value back and said something else. The file existing is true and is
not walked back; what is now reported is that the record of *when* may not survive.

Control: **3 of 3** new tests fail against real `HEAD`. Two details were worth getting right. The
first settings double threw *synchronously*, which escaped the `catchError` the production code
attaches — the real repository methods are `async` and always fail through the returned Future, so
a synchronous throw tests a situation that cannot happen. And the first "retry" test did not test a
retry at all; it was replaced with one whose repository fails only the *first* read, which is the
behavioural change the fix is actually about.

## The emulator E2E job is intermittently failing, in a different place each time

Three failures now, on three different tests, each on a head whose application source was unchanged
from a run where it passed:

| head | failing test | also present |
| --- | --- | --- |
| `be4e882` | `key_generate_test.dart:132`, cleanup left a card | `DELETE_FAILED_INTERNAL_ERROR`; transport failure → emulator reboot + retry |
| `95b5f0c` | `crash_log_test.dart:103`, clipboard read returned null | `DELETE_FAILED_INTERNAL_ERROR`; no reboot |
| (`b86ed2c`, `11ec327`, `9947585` passed) | — | `DELETE_FAILED_INTERNAL_ERROR` present on a passing run too |

That pattern points at the hosted emulator environment rather than at any one test, and it is the
reason the `removeKeyIfPresent` convergence change **remains unproven as a fix** — the condition
that produced its failure has not recurred.

The clipboard failure is understood and is not an application defect. `crash_log_test` already waits
for the `about.copied` marker, which only appears after the platform call returns, so the *write*
completed; the *read* came back null. Android serves clipboard reads only to a focused app, so a
transient focus change answers null for content that is genuinely present. The read is now a bounded
retry (40 attempts, ~6s). It weakens nothing: the polled value cannot change, the redaction
assertions are untouched, and a read that never succeeds still fails — now naming focus as the
likely cause while stating that the write cannot be confirmed from there either way.

### Validation for this tree

`./scripts/local-pr-check.sh --full` passed (`rc=0`); both diff checks clean.

- The device `core` profile was run **three times in a row**, not once: a single green run says
  very little about an intermittent failure. All three passed, 9 entrypoints each, 0 failures. This
  does not prove absence and is not offered as proof.
- Flutter full suite **2705 passed / 4 optional live skips**; `flutter analyze` clean in 6.4s.
- Device `host` profile passed earlier in this batch (2 passed / 0 skipped).
- Native unit tests reused UP-TO-DATE; no Kotlin changed. Release APK/AAB, both SBOM graphs and
  strict dependency verification passed. Full-history secret scan: 206 commits, no leaks.

## A backup quietly dropped every pinned host key

`BackupViewModel._pinnedHostKeys()` caught any trust-store failure and returned `{}`. The
tolerance is right — a locked keystore must not cost the user every other section — but it was
**silent**, and the file looked complete. The user found out at restore time, when every host had
dropped from "verified against a pinned key" to trust-on-first-use: the next connection is accepted
as *new* rather than flagged as *changed*, which is the single thing pinning exists to catch.

It was also a parity divergence. Compose does not catch at all (`ui/AppViewModel.kt:11714`) —
`exportEntries()` throwing fails the whole backup. Native was loud and total; Flutter was silent and
partial. Flutter keeps the more forgiving behaviour and gains the missing half: the save message now
says the pinned host keys could not be read, that they are not in the file, what restoring it will
do, and to back up again once the keystore is available. It rides on `_status`, which
`backup_screen.dart` already renders — checked, after the background-service fix showed how easy it
is to leave a warning in a getter nothing draws.

Separately, the trust store was read **unconditionally**, even though `BackupPayload.encode` drops
`knownHosts` unless the closed selection carries servers. A failure could therefore have warned
about keys that were never going to be written. The read is now gated on the same condition as the
write.

**Tests and control.** Four cases; against real `HEAD`:

| case | on `HEAD` | what it is |
| --- | --- | --- |
| a trust store that cannot be read is reported, not hidden | **fails** | the real defect |
| the file carries no `knownHosts` at all | passes | characterises the file, so the warning is not decorative |
| a readable but empty store is not an omission | passes | required silence — nothing was lost |
| a failure is silent when servers were not selected | passes | required silence — nothing would have been written |

Only one is a find. The second matters anyway: without asserting the file contents, the warning
could describe an omission that did not happen. The warning is also asserted to contain no `ssh-`
substring — a warning about keys must never contain one.

### Validation for this tree

`./scripts/local-pr-check.sh --full` passed (`rc=0`); both diff checks clean. An earlier attempt
failed on the `dart format` gate — a hand-edited test file, the same mistake as the key-cleanup
checkpoint, now recorded so it stops recurring. `flutter analyze` does not catch it.

- Flutter full suite **2702 passed / 4 optional live skips**; `flutter analyze` clean in 5.6s.
- Device profiles on API 35 `emulator-5554`: `core` **30 passed / 0 skipped** (25 Dart across 9
  entrypoints, every one first attempt, + 3 native backup-picker + 2 native permissions), `host`
  **2 passed / 0 skipped**. Run before the format-only delta, which changes no behaviour.
- **The connected matrix ran** this time: **58 tests = 24 passed / 34 opt-in `E2e` skips / 0
  failures**. Still not the required route sweep — `E2eAppSurfaceStressTest` is among the skips.
- Native unit tests reused UP-TO-DATE; no Kotlin changed. Release APK/AAB, both SBOM graphs and
  strict dependency verification passed. Full-history secret scan: 205 commits, no leaks.

## Who owns the SSH channel before a session takes it

Two defects between `openShell` returning a channel and a `ShellSession` adopting it.

**The channel leaked when persistence failed.** `_persistentTarget` does real database work *after*
the shell is open. When it threw, the exception unwound straight past an open SSH channel: not in
`_sessions`, invisible to the user, and holding a shell on the server until the process died. Only
the two generation checks closed it; nothing covered a throw. There is now an explicit ownership
boundary — a `channelAdopted` flag flipped the instant `ShellSession` takes the channel, with a
`finally` that closes it on every other exit. The two explicit closes were folded into that
boundary rather than left duplicated.

**A live session was reported as a failed connection.** `_reloadSaved()` runs *after* the session is
registered and usable. Letting it throw sent a working shell's connect into the failure handlers, so
the user was told the connection had failed while their terminal sat in front of them. It now keeps
the session and says the true, narrower thing: connected, but the resumable-session list may be
stale until the next change. That list is what Leave and resume read, so it is worth saying — it is
simply not a failed connect.

**Tests and control.** Three cases. Against real `HEAD`:

| case | on `HEAD` | what it is |
| --- | --- | --- |
| a persistence failure closes the channel it opened | **fails** (`closeCalled` false) | real leak |
| a live session is not reported as a failed connection | **fails** (`Bad state: fixture storage unavailable`) | real misreport |
| a superseded attempt closes its channel | passes | preserved behaviour, not a find |

The third is counted honestly: the original code already closed the channel at both generation
checks. It is kept because the refactor replaced those explicit closes with the `finally`, and that
is exactly the kind of change that silently drops a case. An earlier control run removed both the
`finally` *and* the original explicit closes, which made all three fail and overstated the defect;
the table above is from the real `HEAD` file.

The post-registration test needed a repository double (`_FailsReadingAfterWriting`) whose
persistent-session *reads* fail once one has been *written*. That lands the failure precisely in the
window after ownership transfers, deterministically, without counting calls.

### Validation for this tree

`./scripts/local-pr-check.sh --full` passed (`rc=0`); both diff checks clean.

- Flutter full suite **2698 passed / 4 optional live skips**; `flutter analyze` clean in 6.4s.
- Device profiles on API 35 `emulator-5554`: `core` **30 passed / 0 skipped** (25 Dart across 9
  entrypoints, every one first attempt, + 3 native backup-picker + 2 native permissions), `host`
  **2 passed / 0 skipped**. These exercise the connect path this checkpoint changes.
- Native unit tests reused UP-TO-DATE; no Kotlin changed. Release APK/AAB, both SBOM graphs and
  strict dependency verification passed. Full-history secret scan: 204 commits, no leaks.
- In-script connected matrix deferred (emulator stopped for the heavy gate); the device profiles
  above are this checkpoint's device evidence.

## A refused background service told nobody

`SessionService.sync`/`stop` returned `bool`, and `_syncBackgroundSessions` used that only to clear
a cache so the next change would retry — then dropped it. A keep-alive Android refused was
completely silent. The user went on believing their shells were protected while backgrounded, which
is the whole reason the feature exists. AGENTS.md's app-wide rule is explicit that user-triggered
work owes a clear result or an actionable error; this owed one and gave nothing.

The gap ran through three layers:

- **The Kotlin bridge never reported failure at all.** `SessionServiceBridge` answered
  `result.success(true)` unconditionally, so a `startForegroundService` that throws — Android 12+
  raises `ForegroundServiceStartNotAllowedException` for a start attempted from the background —
  crossed the channel as a raw exception with its reason lost. It now catches and answers
  `result.error("session_service_failed", <the platform's own message>, null)`.
- **`bool` could not carry the answer.** "iOS has no foreground service", "no plugin registered"
  and "this Android device refused" were all `false`. `SessionServiceResult` now distinguishes
  `ok` / `unsupported` / `failed(detail)`. The distinction is the point: iOS can never support this,
  so a permanent warning there would be worse than silence.
- **Nothing rendered it.** The Shell now shows `shell.backgroundService.warning` with the
  platform's own reason and a dismiss control, for genuine refusals only.

Two defects in the first version of this fix, found while testing it and worth recording:

- Dismissing did nothing. A failure clears the retry cache, the next session notification retries,
  it fails identically, and the warning reappeared at once. Dismissal now remembers the exact
  message it silenced; a *different* failure, or a recovery, clears that memory.
- The original code never cleared the warning when the service started working again. It does now.

**Tests.** 3 channel cases (unsupported vs. refused-with-reason vs. answered-false), 4 view-model
cases (refusal surfaced with its reason, unsupported stays silent, an unchanged failure does not
re-announce on every output frame, dismissal sticks until something changes) and 2 widget cases.
The shared double moved to `test/support/fake_session_service.dart` alongside the others.

**Negative control.** With the result discarded exactly as before, 4 of the 6 new behavioural tests
fail — including the widget test, which matters because a getter nothing renders is the same
silence the fix set out to end. The two that pass both ways assert *absence* on unsupported
platforms, which is correct in both directions.

### Validation for this tree

`./scripts/local-pr-check.sh --full` passed (`rc=0`); both diff checks clean.

- Flutter full suite **2695 passed / 4 optional live skips**; `flutter analyze` clean in 6.3s.
- Device profiles on API 35 `emulator-5554`: `core` **30 passed / 0 skipped** (25 Dart across 9
  entrypoints, every one first attempt, + 3 native backup-picker + 2 native permissions), `host`
  **2 passed / 0 skipped**. No unexpected warnings. These cover the Shell screen, which this
  checkpoint changes.
- Native unit tests reused UP-TO-DATE; no `app/` Kotlin changed here. The Kotlin that did change is
  `flutter_app/android`'s bridge, compiled by both the device debug builds and the release APK/AAB.
- Release APK/AAB, both SBOM graphs and strict dependency verification passed. Full-history secret
  scan: 203 commits, no leaks.
- The emulator was stopped for the heavy gate, so `local-pr-check`'s in-script connected matrix
  reported **deferred**; the explicit device profiles above are this checkpoint's device evidence.

## Two tests that could not tell a real defect from a racing environment

### The key suites' cleanup could not converge, and said nothing useful when it failed

`End-to-end on an emulator` failed on head `be4e882` at `key_generate_test.dart:132`. Nothing in
`app/` or `flutter_app/` differs between that head and `b691ddd`, where the same job passed, so the
code under test was identical; the same suite also passes locally first-attempt on a clean API 35
device. **The cause is still open and is recorded as open.** Earlier in that job Flutter's own
inter-entrypoint `adb uninstall com.jetsetslow.omniterm` failed with `DELETE_FAILED_INTERNAL_ERROR`
and a separate entrypoint needed an emulator reboot after a transport failure, so the device was
demonstrably not pristine — but the runner's `reset_android_flutter_harness` never reported its own
failure, so the packages *were* gone by `pm path` between entrypoints. Cards are keyed by database
id (`authKeys.key.<id>`), and the surviving card was id 1, so "one card whose delete did not take
effect" is at least as likely as "two cards the cleanup could not clear". Do not write this up as a
dirty-device flake; it is not established.

**Narrowed on head `b86ed2c`, which passed.** That run hit the *same*
`DELETE_FAILED_INTERNAL_ERROR` and `key_generate_test` still passed. What it did **not** have was
the mid-run transport failure that rebooted the emulator and retried an entrypoint. So the failure
correlates with the reboot, not with the failed uninstall — and a green run here is therefore not
evidence that the cleanup change fixed anything, because the condition never recurred. Said plainly:
the cause is still open.

What *is* established is that `removeKeyIfPresent` — shared by `key_generate_test.dart` and
`key_import_test.dart` — deleted `.first` exactly once and then asserted `findsNothing`. That
cannot clean up more than one matching card, and on failure it produced an anonymous finder dump
that cannot distinguish the two candidates. It now loops until the count reaches zero, bounded by
*progress* rather than a clock so it cannot spin, with a 10-second inner wait because the deletion
is a database write observed through a stream and `pumpAndSettle` can return before the rebuilt
list has lost the row. A delete that stops making progress now fails as
`deleting "<alias>" left N card(s) listed after confirming, down from M: the delete did not take
effect`. The next occurrence will say which cause it was.

Control: a new `auth_keys_screen_test.dart` case seeds two key rows sharing an alias straight
through the repository and proves the premise deterministically — they render as **two** cards, and
one delete leaves one behind. `importKey` refuses a duplicate alias, but its guard is the view
model's cached list; the row itself carries no uniqueness, so a restore or an unclean device can
produce this state. This is **not** a reproduction of the CI failure, and is not claimed as one.

### A native identity guard compared live telemetry and raced the host check

`BackupCompatibilityInstrumentedTest.profileEditCannotSilentlyCreateDuplicateServerLogins`
compared whole `ServerEntity` rows. Five of those fields belong to the background host check:
`updateConnectionState` and `updateAuthState` (`data/Daos.kt`) write `status`, `healthScore`,
`lastLatency`, `authStatus` and `authError` on their own schedule, and the fixture host is
deliberately unroutable, so the probe reliably starts. Observed failure: every identity, credential
and configuration field matched and only `healthScore=100 → 0` and `status=offline → connecting`
differed. The assertion now normalises exactly those five fields, with the reason written down, and
still compares every other field exactly — the question it asks is whether a *rejected* profile
edit altered identity, credentials or configuration, which has nothing to do with what the last
probe found.

**Coverage gap worth deciding on (not changed here).** This test runs in almost no gate. Required
CI's Room jobs filter instrumentation to
`-Pandroid.testInstrumentationRunnerArguments.package=com.jetsetslow.omniterm.data`, and this class
is in the root package, so CI never executes it. Locally it runs only inside `local-pr-check
--full`'s connected matrix, which reported **deferred** in every recent gate because the emulator
was stopped for the heavy run. It surfaced now only because the emulator was left up. Widening the
required instrumentation filter changes CI cost and shape, so it is left as an explicit decision
for the next session rather than taken unilaterally.

### Validation for this tree

`./scripts/local-pr-check.sh --full` passed (`rc=0`); both diff checks clean. Two earlier attempts
failed honestly and are not passes: one on the `dart format` gate (my hand-wrapped predicate in
`auth_keys_screen_test.dart`; the gate reports rather than rewrites by design), and one on the
native assertion above before it was fixed.

- Flutter full suite **2687 passed / 4 optional live skips**; `flutter analyze` clean in 6.8s.
- **The connected device matrix executed this time rather than deferring**: API 35
  `emulator-5554`, **58 tests = 24 passed / 34 skipped / 0 failures**, with
  `profileEditCannotSilentlyCreateDuplicateServerLogins` among the 24 that ran and passed. All 34
  skips are opt-in `E2e*` cases self-skipping through `assumeTrue`, `E2eAppSurfaceStressTest`
  included — so this is still not the required route sweep.
- Device profiles on API 35 before the gate: `core` **30 passed / 0 skipped** (25 Dart across 9
  entrypoints, every one first attempt, + 3 native backup-picker + 2 native permissions, with the
  convergent cleanup in place), `host` **2 passed / 0 skipped**. No unexpected warnings.
- Native unit tests reused UP-TO-DATE, not freshly executed; the only Kotlin change here is in
  `androidTest`. Release APK/AAB, both SBOM graphs and strict dependency verification passed.
  Full-history secret scan: 202 commits, no leaks.

## tmux preflight — a dead connection offered to install a package

Two defects in `ShellViewModel.connect`'s tmux availability probe, both found by reading the
transport contract rather than the tests.

**1. A returned error read as a definite "tmux is missing".** `DartSshTransport.exec` reports
failure by *returning* `'SSH Error: …'`, not by throwing — the codebase already knows this in
`telemetry_poller`, `infra_view_model`, `tmux_bootstrap` and `ssh_failure.dart`. But `_hasTmux`
caught only *thrown* errors and otherwise did `answer.trim().endsWith('yes')`. A refused
connection, a timeout or a rejected key therefore became a confident "not installed", and the app
offered to install a package over a link that did not exist. `parseTmuxCheck` now returns `bool?`
— `yes`/`no` definite, a returned `SSH Error:`, an empty answer or anything unrecognised
unverified — mirroring `parseTmuxSessionProbe`, which had the shape right all along. Only a
definite `false` raises the install prompt; `null` lets the connection report the host's real
failure. It reads the last non-blank line, so a login banner before the answer is fine, and a word
merely *ending* in "yes" no longer counts.

An unverified probe is also no longer written into `_tmuxVerified`. The old code cached a thrown
probe as "present", so one flaky moment silently disabled the check for the rest of the session on
the exact host that needed it.

**2. The probe ran outside the attempt it belonged to.** It awaited a full round trip to the host
with `_connecting` still false. There was no busy state, so a slow probe was indistinguishable from
a tap that did nothing; `cancelConnect` had nothing to cancel and a late answer could raise a
prompt for a connection the user had abandoned; and the `if (_connecting) return` guard at the top
of `connect` could not see it, so a second tap during the probe started a second full connection.
It now runs inside the owned attempt/generation boundary with a `Checking for tmux…` phase, and a
superseded or cancelled probe returns without touching the newer attempt's state.

`installTmuxAndConnect`'s post-install re-probe now requires a definite yes: an unanswered probe is
not evidence the install worked.

**Tests.** 5 `parseTmuxCheck` cases (definite answers, banner before the answer, returned transport
errors, empty/unrecognised, and the `endsWith` trap) and 5 new `ShellViewModel` cases. The fake
transport gained an `execGate`, matching its existing `gate` for `openShell`, so a probe can be
held in flight while the busy state, double-tap guard and cancellation are observed.

**Negative control.** All 5 new view-model tests fail against the unfixed view model, each with the
production symptom: the install prompt raised on a refused connection; `isConnecting` false while
the probe is pending; two probes from two taps; a prompt raised after `cancelConnect`; and a thrown
probe cached as verified so the second connection never asked again. The 6th case in that group is
a pre-existing test renamed — its old name asserted "assumes tmux is there", a mechanism that no
longer exists — and it passes both ways, as it should. An earlier draft of the caching test passed
on unfixed code for the wrong reason and was rewritten until it genuinely failed.

### Validation for this tree

`./scripts/local-pr-check.sh --full` passed (`rc=0`); both diff checks clean.

- Flutter full suite **2686 passed / 4 optional live skips** (2676 + the 10 new cases), same 3
  `OMNITERM_SETUP_FIXTURE` relay skips and 1 `OMNITERM_COMPRESSION_*` skip. `flutter analyze`
  clean in 6.3s. Focused run of the four affected files: 112 passed.
- Native unit tests were **reused UP-TO-DATE, not freshly executed** — this checkpoint changes no
  Kotlin. Required x86_64 CI executes them.
- Flutter release APK + App Bundle, both release SBOM graphs, release test-code exclusion and
  strict forced-fresh dependency verification passed. Full-history secret scan: 201 commits, no
  leaks.
- **Device profiles on API 35 `emulator-5554`, run before the heavy gate:** `core` **30 passed /
  0 skipped** (25 Dart across 9 entrypoints, every one first attempt with no retries, + 3 native
  backup-picker + 2 native permissions), `host` **2 passed / 0 skipped** (1 Dart fixture + 1 native
  "SSH survives Home and explicit background; tmux leaves and resumes the same shell", 151s). No
  unexpected warnings (16 known on core, 6 on host).
- The emulator was stopped for the heavy gate, so `local-pr-check`'s own in-script connected matrix
  reported **deferred, not passed**. The explicit `core`/`host` profiles above are the device
  evidence for this change. Normal Flutter debug launcher rebuilt, reinstalled and reopened
  (`COLD 2817ms`).

## SSH setup checkpoint (`85f5cfe`) — pushed; one exact-head CI failure

Signed and pushed `85f5cfe7392caafa4afdd249f635456a06777916`; all selected checks are terminal.
Native Build & Test, release SBOMs, API 29 Room/backup (7 tests), CodeQL, dependency review,
Scorecard analysis, both secret scans, Flutter analysis/tests, release artifacts/SBOMs and iOS
passed. Flutter emulator failed: the surface sweep expected Builder after a swipe but remained
on Stacks (`app_surface_stress_test.dart:203`). Exact job `103606496057` logs were inspected;
the locally validated repair follows below. No unchanged failed workflow rerun. The replacement
head must pass its own checks before PR #92 can be described as green.

Separately, a new API 35 Activity-recreation guard failed for the expected reason:
the replacement Activity owns a different Flutter engine. Its Dart Home/background/tmux flow
passed, but final native JUnit result is **1 failure / 0 skips**, not a pass. Production engine
retention is not fixed yet. The guard currently proves engine identity, not a live shell during
recreation; that stronger fixture test is still required. The failing guard is preserved privately
as a patch, not included in the swipe repair tree before its production ownership fix exists.

### Swipe/runner checkpoint (`b691ddd`) — signed/pushed; local validation complete, CI incomplete

The deterministic paused-swipe guard failed on API 35 with unchanged production gesture code:
the selected offline host stayed on Stacks instead of opening Builder. Flutter required nonzero
release velocity; Kotlin uses deliberate distance. The repair follows Kotlin's 96 logical-pixel
threshold and 2.2 horizontal/vertical ratio, once per gesture, while retaining nested-scroll gesture
ownership. Eight focused widget cases and existing navigation tests passed (**32 / 0 skipped**).
Expanded navigation/Infra/widget validation passed **71 / 0 skipped**, analyzer clean.
The first API 35 core run passed all 25 plain Dart cases (including the full surface sweep) and
3 native backup picker cases. It then stopped before the 2 native permission cases: Patrol's
optional update lookup hit a network reset. This was **28 passed / 2 unstarted**, not a passing
core profile, and the host/full gate were not reached. Normal debug launcher restoration passed.
The device runner now invokes the pinned Patrol CLI in its supported CI mode with analytics off,
matching hosted execution and avoiding optional update-service dependence. A new isolated runner
guard failed on the old invocation for that exact missing environment, then passed with the fix;
it also proves a real Patrol test failure propagates unchanged without retry. Both local preflight
and required native CI already execute this same runner regression script.
The replacement API 35 core run passed **30 / 0 skipped** (25 Dart, 3 native backup picker,
2 native permission cases); fixture-host run passed **2 / 0 skipped** (Dart fixture + native
Home/background/tmux). No unexpected warnings. `./scripts/local-pr-check.sh --full` **passed**:
Flutter **2,676 passed / 4 optional live-test skips**, analyzer clean. Native unit/lint tasks reused
Gradle's up-to-date results for unchanged native source; they were not newly executed in this run.
The reused native results contain **558 passed / 2 optional tmux replay skips per variant**,
560 discovered, zero failures/errors. The four Flutter live skips have separate earlier evidence
for unchanged SSH code, not new execution in this batch. No Linux ARM64 discovery exclusion applies
on this x86_64 host.
Fresh strict dependency/compile verification, both native release SBOM graphs, Flutter APK/AAB/SBOM
and release test-code exclusion passed. No checksum metadata changes. Full-history secret scanning
passed. The emulator was deliberately stopped for the heavy gate: its in-script device matrix was
deferred, not counted as passing. Separate API 35 Room afterward: **4 passed / 0 skipped**. Normal
Flutter debug launcher rebuilt/reinstalled/reopened successfully. Both diff checks and the staged
secret scan passed before signing/pushing `b691ddd`; remote branch and PR head were verified.
Monitor every selected exact-head job and fix the CodeQL false skip; do not infer CI success.

### Validation for the prior SSH deadline checkpoint (`85f5cfe`)

- Reproduced two indefinite Flutter setup waits: a loopback peer accepted TCP but never sent an
  SSH banner, both directly and as a bastion. Both new guards failed on the unfixed transport.
- Added a 15-second network budget per authentication and bastion-forwarding stage. It pauses only
  around the actual host-key decision; the existing 120-second approval limit stays intact.
  Trust-store reads/writes remain bounded. Failed setup closes its owned connections, suppresses
  late approval prompts/answers, and retires late forwarding channels without retrying requests.
  Bastion forwarding has its own visible phase, and returned timeout errors retain the failed stage.
- Final focused Flutter tests: **60 passed / 0 skipped**, including eight deterministic clock/trust
  tests, four real loopback socket cases and the explicitly enabled live-compression test.
  Analyzer clean. Real repository OpenSSH relay tests:
  **3 passed / 0 skipped** — delayed approval beyond 15 seconds, stalled authentication and stalled
  forwarding. No fixture daemon/network configuration was changed by these tests.
- New Kotlin counterpart guards use real JSch and loopback sockets, replacing only Android-backed
  trust storage with a fail-closed in-memory store. Final focused run: **2 passed / 0 skipped per
  variant**. No native production behavior changed in this batch.
- API 35 Flutter `host`: **2 passed / 0 skipped** (one Dart fixture case and one native Patrol
  Home/background/tmux lifecycle case). `surface`: **1 passed / 0 skipped**, all routes/subtabs,
  themes and rotations. No unexpected warnings; normal debug launcher restored afterward.
- The first full-validation wrapper stopped before the gate because its restricted PATH lacked
  `rg`; this was not an app/test failure or a passing gate. The corrected wrapper completed
  `./scripts/local-pr-check.sh --full`, then the separate API 35 Room matrix (**4 passed / 0 skipped**),
  and rebuilt/reinstalled/reopened the normal Flutter debug launcher successfully.
- Full gate: Flutter **2,668 passed / 4 optional live-test skips**, analyzer clean; native unit
  suites each **558 passed / 2 optional tmux replay skips**, 560 discovered, no failures/errors.
  This x86_64 host executed the Robolectric classes; there was no ARM discovery exclusion here.
  The four Flutter skips are the three setup fixture cases and one compression case, all separately
  enabled and passed above. The two native replay captures remain unavailable, not passing.
- Strict fresh dependency verification, release APK/AAB builds, native/Flutter SBOM graphs and
  release test-code checks passed. The owned emulator was intentionally stopped during the heavy
  gate, so its in-script connected matrix was deferred, not counted as passing; separate runtime
  and Room evidence is listed above. The new head still needs its own API 29 migration/platform CI.
- The above local validation belongs to `85f5cfe`; repair the failed surface gate and validate
  the replacement final tree before its own signed checkpoint. No merge or release is implied.

The three new live setup tests are opt-in in the ordinary unit suite. Run
`flutter test test/dartssh_setup_live_test.dart` with `OMNITERM_SETUP_FIXTURE=yes` and privately
loaded `OMNITERM_TEST_USER` / `OMNITERM_TEST_PASSWORD` from the repository fixture configuration.
They use only the fixed loopback fixture ports. Report these default skips separately from the
existing optional live-compression test; neither is default unit-suite coverage.

## CI repair checkpoint (`500f35d`) — local and exact-head CI validation completed

All selected jobs finished successfully: native Build & Test, API 29 Room/backup tests (7 cases),
both native release SBOM graphs, CodeQL, dependency review, Scorecard analysis, both history secret
scans, Flutter analysis/unit tests, Android release artifacts/SBOMs, unsigned iOS archive and
API 35 core emulator tests (**30 passed / 0 skipped**). Flutter CI unit tests reported **2,658
passed / 1 optional compression skip**. Host-backed/lifecycle tests are not selected by CI's
`core --no-fixtures` profile. The separate Scorecard result is **neutral**, not success.
Only unused docs-only companion jobs were skipped. No failed workflow was rerun unchanged.

All checks for `925ae3c6a755810d59525a42658cc004b37e67df` reached a terminal state:

- Native Build & Test failed in `TerminalLeavePersistenceRobolectricTest`: its teardown reset Main
  while canceled IO work was still dispatching cleanup. Room and native release SBOM jobs were
  consequently **skipped, not passing**. The fix waits for ViewModel and process-terminal jobs
  before resetting the test dispatcher; it does not increase test deadlines or change app behavior.
  A deterministic blocked-finalizer regression fails with the original teardown for the expected
  reason. Apply the same cleanup to the tmux startup tests.
- Flutter analysis/unit tests, Android release artifacts/SBOMs, and unsigned iOS archive passed.
  Emulator testing failed in the native backup save-cancellation test: after the screen revealed
  feedback at the top, the lazy list disposed its export button. Scroll back to the button before
  asserting it is enabled. Native picker tests reached 2 passed / 1 failed / 0 skipped on that head.
  Local retesting also exposed the first-operation notification prompt behind DocumentsUI: the
  test now explicitly handles denial after closing the picker before interacting with Flutter.
  The interrupted device run is not counted as a pass; the subsequent complete profile passed.
- Dependency vulnerability review passed; the license step rejected `file_selector_android`
  `0.5.2+9`'s non-SPDX identifier. The complete published LICENSE contains BSD-3-Clause and
  Apache-2.0 notices, both already approved by the existing policy. Archive and LICENSE checksums
  were independently checked. The new reviewer recognizes only the exact reviewed package,
  version, manifest, ecosystem, source, and identifier, reports the normalization, and rejects
  unrelated LicenseRefs or compounds. Eleven offline tests exercise the policy and gate alignment.
  Missing GitHub license metadata still produces the existing explicit warning, not a reviewed
  license claim. No dependency version, vulnerability threshold, or general allow-list changed.
- CodeQL, Scorecard analysis, and both secret scans passed. The separate Scorecard result was
  neutral, not success. No unchanged failed workflow was rerun, and no protections were weakened.

Focused repair validation: native leave/cleanup and tmux startup tests passed **7 tests per
variant, zero skips**; the new cleanup guard failed against the original teardown for the expected
reason. Native Flutter backup picker retest passed **3 tests, zero failures/skips**, including
actual notification denial. License-policy tests passed **11 tests**, and the reviewer accepted
the recorded GitHub comparison with its unresolved-license warnings retained.

Current repair tree validation:

- `./scripts/local-pr-check.sh --full` **passed**. `refresh-verification-metadata.sh --write`
  followed by strict fresh verification passed, with no checksum changes; the full gate repeated
  `--verify`, including both native release SBOM graphs and Flutter release APK/AAB/SBOM checks.
- Native unit suites: **556 passed / 2 optional replay skips per variant**, 558 discovered, zero
  failures/errors. Skips remain the unavailable `TmuxAltScreenReplayTest` captures, not a new
  exclusion. This x86_64 host executed the affected Robolectric classes.
- Flutter: **2,658 passed / 1 optional live-compression skip**; analyzer clean. SSH production code
  is unchanged from the separately enabled fixture-compression proof recorded below.
- Flutter API 35 `core --no-fixtures`: **30 passed / 0 skipped** — 25 Dart integration cases,
  3 native backup picker cases, 2 native permission cases. No unexpected warnings. This profile
  excludes the host-backed and terminal-lifecycle fixture suites; their earlier evidence below
  remains unchanged, not part of this core run.
- The emulator was intentionally stopped during the memory-heavy gate, so the in-script device
  matrix was deferred. Separate API 35 Room migrations afterward: **4 passed / 0 skipped**.
- The wrapper's final launcher reopen failed because the Flutter package was absent after restart,
  after both `--full` and Room had passed. Rebuilt/reinstalled the normal Flutter debug launcher
  separately; this was an environment-restoration failure, not a failed app test or a green wrapper.
- Full-history secret scanning passed. Both diff whitespace checks passed; repeat the staged secret
  scan and diff checks immediately before the signed checkpoint.

The failed prior head's native Room and SBOM skips remain skips in that historical run; both
gates passed on replacement head `500f35d`. Every future pushed head needs its own complete checks.

## Implemented and regression-tested in the earlier reliability checkpoints

| Area | Changes and evidence |
| --- | --- |
| Background/resume | Kotlin recovery persistence precedes Leave-resumable teardown; Flutter recovery intent/races and foreground-service lifecycle corrected. Runtime lifecycle guards exercise window switching and resumable sessions. Activity/engine destruction remains open below. |
| tmux startup | Show the existing pane before optional history hydration; order quiet-pane/control-mode repaint and guard late responses. Flutter shell-channel negotiation has a post-authentication deadline. Broader setup deadlines remain open. |
| SSH commands | Cancelled/expired Flutter channel-limiter waiters are removed; late leases/channels are cleaned up; cancelled work does not advance to later stages. Kotlin checks cancellation after blocking acquisition and before dispatch. Healthy Stop preserves pooled connections in both versions. Failed Kotlin jump-target authentication releases both owned sessions. No arbitrary command retries. |
| Empty-host navigation | Hidden Monitor/Infra subtabs no longer consume swipes; a selected offline host still permits local Compose editing. |
| Backup | Visible inspection/decryption/restoration progress, compatibility with Kotlin schema 5 and Flutter formats, explicit restore summaries, identity-based reuse and dependent-record remapping. User clarified the old backup itself worked; missing decryption feedback was the issue. |
| Server identity | Compare host, port, effective SSH username and auth method, not label or secret. Add/edit/clone/restore guards and profile-edit transactions prevent new collisions. Existing names/credentials remain intact; errors name conflicting hosts. Do not silently merge legacy duplicates. |
| Profile feedback | Both profile editors show saving state and inline errors. Flutter sheet scrolls; primary controls are disabled while saving. Native and Flutter runtime tests verify a rejected profile edit remains visible and preserves stored data. |
| Fleet/containers | Fleet Uptime/DF/PS use per-host streaming popups without changing Broadcast. Broadcast presets/save grouped with command input. Container actions show immediate busy state, streamed errors and Compose-update stage output. Further fixture/warning audit remains below. |
| Terminal text | Kotlin session identity keys the terminal viewport, preventing stale buffers on host switches. Flutter normal/hidden-normal resize reflows without truncating output; preserves pending wrap and wide characters at one column. Direct full-buffer toggle is visible after long press. |
| Overflow affordances | Persistent directional hints on overflowing Kotlin dialogs/menus/lists and Flutter popup scroll views; hints update with scroll position and disappear when no content overflows. |

Important cancellation boundary: once a request is handed to the SSH library/server, Stop cannot
guarantee the remote command did not run or has terminated. Never claim otherwise or retry it
automatically. Shared Flutter authentication and internal channel negotiation can outlive a
cancelled caller; later resources are cleaned up. The new checkpoint bounds SSH setup while
preserving the separate user-approval window; Activity/engine ownership remains open.

## Validation for the previous source checkpoint (`64d8e23` / `925ae3c`)

- `./scripts/local-pr-check.sh --full` **passed** for this source tree, including strict fresh
  dependency verification and both release SBOM graphs. The owned emulator was stopped during
  the memory-heavy gate; its in-script device matrix was deferred, not counted as passing.
  The separately executed runtime suites below passed, and after the gate the emulator was
  restored and API 35 `AppDatabaseMigrationTest` passed **4 tests / 0 skips**.
- Flutter unit/widget suite: **2,658 passed**, one optional live-compression test skipped in the
  default invocation. The separately enabled live-compression test passed against the disposable
  repository fixture with unchanged SSH code. Analyzer: no issues.
- Kotlin full unit suites: each variant (`openSourceDebug`, `playStoreDebug`) discovered 557
  tests: **555 passed, 2 optional replay cases skipped**, no failures/errors. The skipped cases
  are `TmuxAltScreenReplayTest` (missing optional captures), not platform exclusions on this host.
  Focused identity tests: 7 passed; SSH cancellation guards: 3 passed, no skips in either group.
- Native API 35 runtime: **14 passed, zero skipped** — seed 1, host provisioning 2, terminal
  lifecycle 4, navigation 3, surface sweep 1, backup/profile regression 3.
- Flutter API 35 runtime: host suite **1 passed / 0 skipped**, surface suite **1 passed / 0 skipped**.
  Host suite also runs the native Patrol lifecycle component. No unexpected warnings; known
  upstream Kotlin Gradle plugin warnings remain. Normal debug launcher restored after testing.
- Device-only before proofs: unkeyed Kotlin host switch produced the wrong viewport; native
  profile edit accepted a conflicting login and reported success. Both guards pass with fixes.
  Deterministic before proofs also cover Flutter reflow loss, one-column hang, pending-wrap loss,
  pre-cancelled SSH connections, Kotlin cancellation/connection retirement, and profile collisions.

The default Flutter compression skip is not an untested feature claim. The optional Kotlin
`TmuxAltScreenReplayTest` captures are unavailable in this checkout; those replay cases remain
skipped, not passing. Linux ARM64 excludes unsupported Robolectric native-runtime classes at
discovery; required x86_64 CI must run those classes. This development host is Linux x86_64.
API 36/37 emulator validation remains deferred per `AGENTS.md`; API 29 migrations run in CI.

### Reproduce without the original machine's private scripts or logs

Use JDK 17 for the native project, the repository-pinned Flutter SDK/toolchain, and JDK 21 for
Flutter Android builds. Run `./scripts/test-hosts.sh up` for disposable hosts. Load generated
fixture credentials privately from `scripts/test-hosts/.env`; never print or commit them.

```sh
./scripts/local-pr-check.sh --full
git diff --check
git diff --cached --check
./scripts/flutter-device-test.sh --device <api35-device-id> --profile host
./scripts/flutter-device-test.sh --device <api35-device-id> --profile surface
```

For native device validation, build/install the OpenSource debug app and its test APK **once**,
then drive the runner directly so Gradle reinstalls do not erase provisioning. The package is
`com.jetsetslow.omniterm.app.oss.test/androidx.test.runner.AndroidJUnitRunner`.
Use the repository's fixture port mapping and the generated account, not a personal host.

| Native class | Count | Required instrumentation arguments |
| --- | ---: | --- |
| `E2eLabSeedTest` | 1 | `omniterm_e2e_seed=yes`; fixture `host`, `port`, `username`, `password`, `lab_password`, `proxy_password` |
| `E2eLabHostProvisioner` | 2 | `omniterm_e2e_provision_host=yes`, `omniterm_e2e_trust_host=yes`; fixture `host`, `port`, `user`, `pass` |
| `E2eTerminalLifecycleStressTest` | 4 | `omniterm_e2e_terminal_lifecycle=yes` |
| `E2eTerminalNavigationMatrixTest` | 3 | `omniterm_e2e_terminal_nav_matrix=yes` |
| `E2eAppSurfaceStressTest` | 1 | `omniterm_e2e_surfaces=yes`, `omniterm_e2e_sftp_home=/home/omniterm` for the runtime fixture |
| `BackupCompatibilityInstrumentedTest` | 3 | No opt-in required; creates/removes its own synthetic records |
| `data.AppDatabaseMigrationTest` | 4 | No opt-in required; run separately on API 35 locally and API 29 in required CI |

Class names are relative to `com.jetsetslow.omniterm`. Pass arguments as `-e key value` and
select a class with `-e class <fully-qualified-class>`. Reject skipped/failing runs explicitly.
Do not cite plain `connectedAndroidTest` as opt-in E2E coverage.

## Remaining authorized work — do not replace this with unrelated tasks

0. **Required CI coverage is now established:** the repaired detector ran real CodeQL analysis on
   the recent signed heads, including `bbfed74`. Its successful analysis step and job were inspected;
   the skipped companion is not counted. Continue checking actual selected jobs after every push.
   Analysis duration alone is not evidence of coverage, and a green placeholder is not analysis.
1. **SSH background retention and remaining latency:** audit Flutter Activity/engine destruction,
   live-session ownership, foreground-service error visibility and disconnect-all feedback.
   Continue measuring cold-connect and tmux startup latency; the new setup deadlines prevent hangs,
   but are not a claim that healthy connections are faster. Verify blank bastion username fallback
   and endpoint trimming against Kotlin with fixture regressions before changing them.
   Follow up Flutter's tmux preflight before its busy/attempt guard, error-string classification
   (transport failures must not mean tmux is missing), and channel cleanup if persistence fails
   after a shell opens. Add held-probe/concurrent-attempt and post-open storage-failure tests.
2. **Fleet/container proof and consistency:** add a native fixture guard that taps all three Fleet
   diagnostics and proves popup streaming without changing Broadcast; Flutter has this live guard.
   Exercise real Compose Update with delayed output/stderr and local-build fallback. Audit mutation
   confirmations across Fleet, individual containers and stacks; keep read-only actions lightweight.
3. **Complete parity/feedback audit:** use the release handover and existing migration records;
   inspect untested feature routes and error/cancellation paths. Keep progress, errors, skip summaries
   and overflow indicators consistent. Do not declare full Kotlin/Flutter parity based only on the
   completed fixes above. Flutter backup picker cancellation still has legacy silent-result
   handling; add explicit cancellation feedback consistently in both apps in the backup UX batch.
   Also audit backup trust-store export omissions, selection/last-export metadata IO failures and
   first-operation notification permissions overlapping the document picker. Do not silently omit
   pinned keys or misreport a saved file when only its metadata update failed.
4. **Publishing discipline:** checkpoint frequently, monitor every pushed head, fix failures from
   exact job logs, and leave required reviews/protections/signing/checks intact. This request does
   not authorize merging to `main`, publishing a release, or merging unrelated automated PRs.

## Automated PR review (read-only; last checked 2026-09-11)

- #99: AGP 9.3.2 → 9.4.0. Head `a8436aa96140500cd1ca4cd14195a1268e9e0c1e`.
  Build/CodeQL failed for missing plugin verification metadata; migrations/SBOM skipped.
- #100: proposed metadata fixup for #99, head `ac059121d7c6786f201eb288385fe293b1734d52`.
  No checks; not independently forced-fresh validated. Do not treat it as green or merge automatically.
- #101: deploy-pages 5.0.1, head `e18225d4d6b924b30cd017a500d8877970174d59`.
  Review required; docs-only placeholder checks are not evidence of app-build validation.

Re-query these heads/statuses before acting. No automated PR has been changed or merged by this review.

## Claude continuation and return-review prompt

Read AGENTS.md, this tracker, the private September 13 Claude handover and the original release
record. Continue the authorized Kotlin/Flutter reliability and feature/functionality parity review
on `migration-to-flutter`. First verify actual branch/HEAD, remote, dirty files, PR #92 exact-head
checks and running local jobs. Preserve existing changes and all completed fixes above. Private
notes are supplementary; this tracked document must remain enough to recover on another machine.

Start with the current PR head and actual selected job logs; the CodeQL detector repair and real
analysis are established on recent heads. Continue the exact Kotlin/Flutter UI parity work, SSH lifecycle and
latency, Fleet/container streaming/warning and app-wide feedback/parity work above. Use repository
fixtures only. Add deterministic regression tests and real-runtime before/after proof where required;
show progress, explicit results, cancellation/skip reasons and actionable errors. Preserve host
identity semantics, app-lock/privacy, explicit Quit, security checks and platform-specific limits.

Make frequent signed checkpoints only after the full local gate validates each build-affecting
final tree; run both diff checks and staged secret scanning. Push only the working branch, monitor
every selected exact-head check through terminal state and keep this tracker current. Never rerun
unchanged failed workflows, count skips as passes, merge main, merge automated PRs or release without
new authority. Set up your own verified exact-session continuation schedule per AGENTS.md, not the
retired Codex timer, and stop it at completion or handback. Stale `continue` is not new work.

Before returning to the user, leave a dated `CLAUDE_TO_CODEX_REVIEW` document under private docs and
link it here. Include completed/pending work, SHAs, dirty files, tests and commands with counts/skips,
before/after evidence, exact CI status, risks, platform gaps and any running jobs/stop/recovery steps.
Include a ready-to-use prompt for Codex to independently review your changes, reproduce critical
regressions, verify parity and security, finish remaining authorized issues and finalize only when
all required evidence is complete. Distinguish implementation-complete from validation-complete;
do not declare full parity merely because a subset passed. Keep the public summary sanitized.
