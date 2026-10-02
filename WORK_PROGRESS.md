# Server metrics and tmux recovery fixes

Branch: `kotlin-bug-fixes`. No merge or release is authorized.

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
