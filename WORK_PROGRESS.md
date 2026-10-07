# Server metrics, tmux recovery and container action fixes

Branch: `kotlin-bug-fixes`. No merge or release is authorized.

## October 7: navigation fixture isolation — local gates complete; publishing pending

- PR #92 failed an existing shared native navigation fixture: an expected empty-host swipe remained on Infra after Room published a leftover offline host. The exact failed job and unit XML were inspected; controlled contamination reproduced expected SFTP versus actual Infra on unfixed code.
- The fixture now clears Room before creating its ViewModel, owns it in a ViewModelStore, and drains Main while waiting for cancelled IO continuations to finish during teardown. Production navigation and assertions remain unchanged. The same source passed all thirteen navigation cases in each companion variant, zero skips, and the contaminated-data after case passed with zero skips.
- The final `./scripts/local-pr-check.sh --full` passed both native unit variants (578 passing cases and two optional external-capture replay diagnostics skipped each), both lints and fresh strict project/release-SBOM/compile dependency verification. No device was online during that invocation; after restarting the disposable API 35 emulator, the unchanged final tree passed fresh `./gradlew connectedOpenSourceDebugAndroidTest`: 24 executed cases, 35 opt-in E2E assumptions unexecuted, actual runner exit zero. All thirteen navigation cases executed in each unit variant. Existing Docker/reboot/health runtime evidence below remains valid for unchanged production code.
- Final diff/secret checks, signed checkpoint publishing and every selected exact-head PR #112 check remain required. No merge or release is authorized.

## October 4: individual container actions — signed checkpoint and hosted checks complete

- Stack service rows now carry each container ID and expose direct Start/Stop/Restart/Pause/Unpause/Remove, Logs/Follow and Shell controls. They use the owning runtime and require no Compose file. Service-wide Stop/Restart/Remove operate only on observed replicas for that runtime/project/service, with explicit all-replica confirmation. Stack lifecycle and Scale retain Compose behavior.
- Confirmations for individual containers scroll with visible overflow indicators and retain fixed actions. A changed selected host or missing container rejects the pending action; existing streaming progress/result/error feedback and runtime refresh remain.
- Ordinary unfixed service-stop regression failed with a Compose command; the unfixed API 35 app also failed after deleting the owned fixture Compose file, leaving both containers running. The final Docker fixture invocation passed four selected cases, zero skips: provisioning, trust, deleted-file container isolation/lifecycle and the required route/subtab/theme/rotation/loader sweep. The final Podman invocation passed provisioning, trust and deleted-file Stop/Start/Restart/Remove isolation (three cases, zero skips). Podman pause/unpause was not selected because the disposable fixture has no cgroups and explicitly refuses pause; Docker exercised both. Command checks cover both engine names and quoted target IDs.
- The first native full gate failed an existing tmux reboot regression in the Play Store variant. Its fake presence check reported an unreachable host while background authentication/reconnect still claimed success, contradicting the fresh-SSH rule under load. The fake transport now consistently refuses all SSH paths once that scenario marks the host unavailable; production reboot logic is unchanged. All five focused tmux cases passed in each variant with zero skips.
- Final `./scripts/local-pr-check.sh --full` passed: 578 passing JVM cases and two optional external-capture diagnostics skipped in each variant, both lints and fresh strict dependency/release-SBOM/compile verification. Fresh API 35 plain instrumentation executed 24 passing cases; 35 opt-in assumptions did not execute and are not counted as passes. Actual runner exit was zero.
- The normal debug APK was verified for package, version, debuggable state and development signature, archived, installed and opened without a fatal exception. SHA-256: `10fa6514ee7e50875859b891de085668dcd346088612d0fe205b5c6909d918cd`.
- Reproduce the selected runtime exercise with the disposable fleet, `E2eLabHostProvisioner` and `E2eContainerActionWithoutComposeTest`, using `omniterm_e2e_provision_host=yes`, `omniterm_e2e_trust_host=yes`, `omniterm_e2e_container_actions=yes`, and `omniterm_container_runtime=docker` or `podman`. Enable `omniterm_e2e_surfaces=yes` and the fixture SFTP home for the required surface sweep. Provision and exercise in one invocation.
- Signed/pushed `e99bb3d` completed all fifteen exact-head PR #112 contexts: ten successes, four unselected companion skips and one neutral annotation. Native build/test, API 29 Room, release SBOM, actual CodeQL and selected security checks succeeded. No merge or release is authorized.

## Implemented

- Health starts unavailable (`-1`) and is scored only from verified CPU, memory and root-disk readings. Empty, incomplete and failed command replies cannot become a perfect score or a historical sample.
- Failed and stale samples clear current metrics and health; retained history remains intact. Freshness is three telemetry intervals, with a minimum of 30 seconds. Hosts, Monitor, Fleet, score explanations and the home widget distinguish unavailable health.
- Reachability writes cannot overwrite telemetry scores. An old open-session flag cannot keep a failed current probe online; fresh SSH activity during the check can protect a newer successful connection.
- Selecting an open or saved tmux session checks the exact remote session and shows pending progress. Failures show an actionable error and preserve recovery data. Only a confirmed missing session removes its recovery entry; it never opens an empty replacement.
- Confirmed missing sessions retain their visible terminal buffer and suppress automatic recovery bookkeeping.

## Validation

- Before fixes: two telemetry regressions failed because health remained 100; the existing-tmux selection regression failed because no busy state was entered.
- Dedicated telemetry/tmux coverage: two telemetry and five tmux Robolectric checks passed, with zero skips. Pure parser guards reject negative CPU idle and impossible Linux available memory.
- Final source passed `./scripts/local-pr-check.sh --full` on Linux x86_64: each native variant ran 575 passing JVM tests and skipped two optional external-capture replay diagnostics (`TmuxAltScreenReplayTest`). Both lints and fresh strict project/release-SBOM/compile verification passed. API 35 plain instrumentation ran 24 passing cases; 34 opt-in assumptions did not execute (AGP XML encodes these as failures, while the runner exit is zero). None is counted as passing.
- Separate API 35 fixture invocation enabled `omniterm_e2e_provision_host=yes`, `omniterm_e2e_trust_host=yes`, `omniterm_e2e_surfaces=yes` and `omniterm_e2e_tmux_retention=yes`, with `omniterm_e2e_sftp_home=/config`. All four cases passed, zero skips: provisioning, host trust, route/subtab/theme/rotation/remote-loader sweep, and unverifiable/confirmed-absent tmux recovery.
- Reproduce the final local gate: `./scripts/local-pr-check.sh --full`.
- Required real Android validation: disposable fixture fleet from `scripts/test-hosts.sh up`, `E2eLabHostProvisioner`, then `E2eAppSurfaceStressTest` with `omniterm_e2e_surfaces=yes` and the fixture SFTP home argument. E2e suites are opt-in; plain connected tests do not exercise them.

## Remaining

- Signed validated checkpoint and draft PR publishing; monitor every selected check for the exact PR head through completion. Local full/runtime validation is complete; hosted checks remain pending.
- Required hosted API 29 Room migration coverage and all selected security/release checks.
