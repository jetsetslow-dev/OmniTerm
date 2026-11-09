#!/usr/bin/env bash
# Workflow wiring that only shows on GitHub, checked before a push. The CodeQL Go job must set up the
# pinned Go toolchain before CodeQL's init: init wraps the go it finds on PATH to watch the build,
# and putting the pinned go in front of that wrapper afterwards left CodeQL seeing no Go at all
# ("CodeQL could not process any code written in Go", PR #147). Each rule is also shown failing on
# a copy of the workflow broken the way it guards against.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/codeql.yml"

check() {
  python3 -I - "$1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
start = next((i for i, l in enumerate(lines) if l == "  analyze-go:"), None)
if start is None:
    sys.exit("codeql.yml has no analyze-go job")
end = next((i for i in range(start + 1, len(lines)) if re.match(r"^  [\w-]+:\s*$", lines[i])), len(lines))
job = lines[start:end]
setup = [i for i, l in enumerate(job) if "./scripts/go-toolchain.sh --github" in l]
init = [i for i, l in enumerate(job) if "github/codeql-action/init@" in l]
problems = []
if not setup or not init or setup[0] > init[0]:
    problems.append("the pinned Go toolchain (go-toolchain.sh --github) is not set up before CodeQL's init")
if any('eval "$(./scripts/go-toolchain.sh)"' in l for l in job):
    problems.append("a step puts the pinned go in front of CodeQL's wrapper after init (eval go-toolchain.sh)")
if not any(re.match(r"^\s+source-root:\s*tunnel\s*$", l) for l in job):
    problems.append("CodeQL's init does not limit the source root to tunnel/")
for p in problems:
    print(f"codeql.yml analyze-go: {p}")
sys.exit(1 if problems else 0)
PY
}

check "$WORKFLOW"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
expect_failure() {
  local name="$1" broken="$work/$1.yml"
  python3 -I -c "$2" "$WORKFLOW" "$broken"
  if cmp -s "$WORKFLOW" "$broken"; then
    echo "test-workflow-guards: the '$name' copy is unchanged; the rule is not exercised" >&2
    exit 1
  fi
  if check "$broken" >/dev/null; then
    echo "test-workflow-guards: '$name' passed the check" >&2
    exit 1
  fi
}
# The order that failed on PR #147: the toolchain set up by the build step, after init.
expect_failure setup-after-init '
import sys
s = open(sys.argv[1]).read()
setup = "      - name: Set up the pinned Go toolchain\n        run: ./scripts/go-toolchain.sh --github\n\n"
assert setup in s, "the setup step changed; update this test"
s = s.replace(setup, "")
s = s.replace("        working-directory: tunnel\n        run: go build ./...",
              "        run: |\n          ./scripts/go-toolchain.sh --github\n          cd tunnel && go build ./...")
open(sys.argv[2], "w").write(s)'
expect_failure eval-after-init '
import sys
s = open(sys.argv[1]).read()
s = s.replace("        run: go build ./...", "        run: eval \"$(./scripts/go-toolchain.sh)\" && go build ./...")
open(sys.argv[2], "w").write(s)'
expect_failure whole-checkout '
import sys
s = open(sys.argv[1]).read()
s = s.replace("          source-root: tunnel\n", "")
open(sys.argv[2], "w").write(s)'

echo "test-workflow-guards: workflow wiring checks passed"
