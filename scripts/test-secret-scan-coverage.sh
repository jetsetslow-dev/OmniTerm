#!/usr/bin/env bash
# Asserts that the secret gate actually covers the branches work happens on.
#
# The scan is only useful where it runs. It guarded `main` alone while the Kotlin->Flutter port ran
# to 33 commits on `migration-to-flutter` — a branch that is neither `main` nor a PR *to* `main`
# matches nothing, so those commits were first scanned at the merge. That is the most expensive
# moment to find a secret: the history is already written, and clearing it means a rewrite rather
# than a fix.
#
# A test rather than a comment because the trigger list is exactly the kind of line that gets
# narrowed during an unrelated tidy-up, and nothing would fail. `scripts/test-ci-gradle-gate.sh`
# guards the Gradle gate's arguments for the same reason.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/secret-scan.yml"

# Branches that must be scanned on push. Add to this list, never remove: a branch that carries
# commits and is not here is a branch whose secrets are found late.
REQUIRED_BRANCHES=(main migration-to-flutter)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$WORKFLOW" ] || fail "missing $WORKFLOW"

python3 - "$WORKFLOW" "${REQUIRED_BRANCHES[@]}" <<'PY'
import sys

import yaml

workflow, *required = sys.argv[1:]
with open(workflow, encoding="utf-8") as handle:
    parsed = yaml.safe_load(handle)

# PyYAML resolves a bare `on:` key to the boolean True, which is the one YAML footgun this file
# reliably hits.
triggers = parsed.get("on", parsed.get(True))
if not isinstance(triggers, dict):
    raise SystemExit(f"FAIL: could not read the `on:` block of {workflow}")

problems = []
for event in ("push", "pull_request"):
    block = triggers.get(event)
    if not isinstance(block, dict):
        problems.append(f"`{event}` is missing or has no branch filter")
        continue
    branches = block.get("branches") or []
    for branch in required:
        if branch not in branches:
            problems.append(f"`{event}` does not cover `{branch}` (has: {branches})")

if problems:
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    raise SystemExit(1)

print(f"secret scan covers {', '.join(required)} on push and pull_request")
PY
