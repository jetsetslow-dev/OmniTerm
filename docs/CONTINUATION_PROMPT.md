# Continuation prompt — OmniTerm Kotlin → Flutter parity migration

Paste the block below into Claude Code. The detailed evidence and remaining-work ledger is in
`docs/CLAUDE_HANDOFF_2026-08-09.md`.

```text
Continue the OmniTerm Kotlin → Flutter migration and full parity audit on this machine.

Before changing anything, read these files completely:
1. /home/sbvino/Omniterm/AGENTS.md
2. /home/sbvino/Omniterm/docs/CLAUDE_HANDOFF_2026-08-09.md
3. /home/sbvino/Omniterm/MIGRATION.md, treating its old status/checklist sections as historical
   until reconciled against the current code and the dated handoff.

The required outcome is exact visual and functional parity for every Kotlin screen, subtab, state,
dialog, and action on Flutter, with iOS first-class. Do a complete code-driven audit; do not merely
finish old unchecked items, because supposedly complete work may be partial or wrong. If you find a
Kotlin defect, fix it in both implementations.

Worktrees:
- Flutter: /home/sbvino/Omniterm, branch migration-to-flutter
- Kotlin parity fixes: /home/sbvino/Omniterm-kotlin-parity, branch fix/kotlin-parity-defects
- Flutter SDK: /home/sbvino/sdks/flutter/bin/flutter
- Host: x86_64 SER8, 24 GB installed RAM, KVM available; API 35 AVD omniterm-api35

Both worktrees contain important uncommitted changes. Do not reset, clean, checkout, stash, rebase,
or bulk-stage them. Preserve user-owned edits, especially the Alerts periodic timer and Settings
AMOLED condition. Do not commit or push until the exact final code passes every required gate and
the user asks. Never use git add -A.

Start by inspecting both worktrees and converting the Kotlin UI/actions into a parity ledger. The
Flutter analyzer, all 1,886 host tests, API 35 route/subtab/theme/rotation surface sweep, and the root
full preflight are currently green. The root connected run finished 72 Kotlin tests with zero
failures but skipped 26 opt-in E2E tests, so it is not fleet/screen evidence. Action-level parity,
real fleet behavior, the Kotlin parity worktree's own full gate, iOS native builds, and hosted
exact-head gates remain. Follow the dated handoff's prioritized list and update it as evidence
changes.

Docker is currently inactive because mount-all.service is stuck on the user's inaccessible personal
NFS mounts. Do not kill/bypass/edit those mounts or use a personal lab. When Docker becomes
legitimately available, use scripts/test-hosts.sh and the repository-controlled fleet, including
the required Kotlin E2eAppSurfaceStressTest opt-ins and /config fixture home.

For every claim, record the exact command, device/API, executed test count, fixture, and explicit
skips. A plain connectedAndroidTest can skip all E2e suites and is not screen-coverage evidence.
Re-run ./scripts/local-pr-check.sh --full after further changes and on the Kotlin parity worktree,
plus git diff checks, full Flutter tests, both distribution/release graphs, SBOM/checksum/security
gates, and real device flows on the exact final code. On macOS, build and exercise the unverified
iOS native integrations. Keep MIGRATION.md and the dated handoff accurate before finishing.
```
