# Kotlin host colors — 2026-11-03

Scope: make host identity colors more varied, distinguishable and professional. This branch
starts from the merged Kotlin fixes. Independent review and merge remain the user's responsibility.

## Implemented

- Replace six neighboring neon hues with eight muted choices: Blue, Copper, Teal, Rose, Gold,
  Plum, Olive and Ocean. Alternate hues for automatic ID-based assignment; renaming stays stable.
- Give each hue a brighter dark-theme tone and a deeper light-theme tone. Share the theme-aware
  host color helper across cards, session chrome, host menus, monitoring and tool results.
- Replace unlabeled dots with wrapping named chips, visible selection checkmarks and a selectable
  Automatic option in the shared Add/Edit/Clone form. Explain that host colors identify hosts;
  connection health keeps its separate status indicators.
- Read all legacy stored color names without rewriting hosts or backups. The previous six
  explicit choices map to six distinct replacements. Keep global status tokens unchanged.
- Add regression guards for perceptual separation, text contrast on supported surfaces, legacy
  aliases, stable ID assignment and shared host-ID lookup. Exercise the real chooser in both themes.

- Take the CodeQL Action 4.39.2 patch required by the dependency-update gate; pin its full
  commit in analysis/SARIF workflows and align the local CLI and verified bundle digest to 2.27.4.

## Final local validation

`./scripts/local-pr-check.sh --full` passed on the final build-affecting tree.

| Check | Result |
| --- | --- |
| Both full unit variants | 909 discovered, **901 passed / 8 skipped** per variant; no failures/errors |
| Changed test repeats | Six HostColorsTest cases, five additional Play Store runs; **6 passed / 0 skipped** each |
| Both Android lint gates | Passed |
| Strict fresh dependency verification | Project, buildscript, test, lint, instrumentation, benchmark, both release SBOM and compile graphs passed |
| Metadata refresh | Required `--write` and its strict verify pass succeeded; no checksum-file changes needed |
| Dependency advisories and updates | No moderate-or-higher advisories (201 Maven / 13 Actions); no proposed updates under holds (66 Gradle / 36 Actions) |
| Secret scanner and duplicate checks | Passed, including complete history and both local diffs |
| Ordinary API 35 instrumentation | 70 discovered, **28 passed / 42 opt-in E2E skipped**, no failures/errors |
| API 35 Room matrix | **6 passed / 0 skipped**, included above |
| Local CodeQL 2.27.4 | **Zero alerts; 75,770 lines analyzed**, all 121 production Java/Kotlin files extracted |

Unit skips are six opt-in SshSignInLiveTest cases and two unavailable TmuxAltScreenReplayTest
captures. This x86_64 host excluded no ARM-unsupported native-runtime classes. CodeQL's 121/340
source count covers all production files across both variants; tests and benchmark sources are
outside the production compile. The final gate reused valid unchanged unit inputs after the
CI-only CodeQL patch; the full suites had executed in the first attempt, and all five changed-test
repeats executed again. The first attempt stopped at the update-policy check, not a source failure.

## Explicit API 35 runtime checks

The disposable repository SSH fleet was started with `./scripts/test-hosts.sh up`. App and test
APKs were installed once before provisioning and explicit instrumentation, preserving seed data.

- HostColorPickerInstrumentedTest: **1 passed / 0 skipped**; every named choice and restoration of
  Automatic in both themes. It first failed on the old APK because Automatic was absent. The
  separation guard first failed on the old Blue/Indigo pair.
- E2eLabHostProvisioner, `omniterm_e2e_provision_host=yes` and `omniterm_e2e_trust_host=yes`:
  **2 passed / 0 skipped** against the repository fixture.
- E2eAppSurfaceStressTest, `omniterm_e2e_surfaces=yes` and `omniterm_e2e_sftp_home=/config`:
  **1 passed / 0 skipped**; routes, subtabs, themes, rotation and remote loaders.
- E2eTerminalNavigationMatrixTest, `omniterm_e2e_terminal_nav_matrix=yes`: **3 passed / 0 skipped**.
  Its first run exposed a stale overflow assertion when all controls fit. Update only the test
  to require pinned copy-range actions visible before scrolling; terminal behavior is unchanged.
- E2eTerminalOptionsTest, `omniterm_e2e_terminal_options=yes`: **1 passed / 0 skipped**;
  portrait/landscape and font scales 1.0, 1.5 and 2.0 against the disposable SSH fixture.

## Publication boundary

At checkpoint creation, exact-head hosted checks and the required API 29 Room gate are pending.
Monitor Build & Test, Room migrations, release SBOM, CodeQL, dependency review, secret scanning
and supply-chain analysis to terminal status after pushing; the PR description records their
final result without creating another head merely to update CI status.

Independent review and merge remain the user's responsibility. No automated approval or release
is included. Before an authorized merge, consolidate this temporary tracker into the private
handover and remove it from the merge tree.
