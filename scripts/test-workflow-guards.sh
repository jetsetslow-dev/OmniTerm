#!/usr/bin/env bash
# Workflow wiring that only shows on GitHub, checked before a push. The CodeQL Go job must set up the
# pinned Go toolchain before CodeQL's init: init wraps the go it finds on PATH to watch the build,
# and putting the pinned go in front of that wrapper afterwards left CodeQL seeing no Go at all
# ("CodeQL could not process any code written in Go", PR #147). The release job must build one APK
# per architecture and check what it built (scripts/verify-release-apks.py) before any of it is
# hashed, attested or uploaded. Each rule is also shown failing on a copy of the workflow broken the
# way it guards against.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/codeql.yml"
RELEASE="$ROOT/.github/workflows/android-release.yml"

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

check_release() {
  python3 -I - "$1" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
start = next((i for i, l in enumerate(lines) if l == "  release:"), None)
if start is None:
    sys.exit("android-release.yml has no release job")
end = next((i for i in range(start + 1, len(lines)) if re.match(r"^  [\w-]+:\s*$", lines[i])), len(lines))
steps = []
for l in lines[start:end]:
    m = re.match(r"^      - name: (.+)$", l)
    if m:
        steps.append((m.group(1), []))
    elif steps:
        steps[-1][1].append(l)
def first(test):
    """The first step with a line, not a comment, that passes test."""
    return next((i for i, (_, body) in enumerate(steps)
                 if any(test(l) for l in body if not l.lstrip().startswith("#"))), None)
problems = []
build = first(lambda l: "./gradlew" in l and "TASKS" in l)
if build is None or not any("-Pomniterm.abiSplits=true" in l for l in steps[build][1]):
    problems.append("the release build does not pass -Pomniterm.abiSplits=true, so no APK per architecture is built")
verify = first(lambda l: re.search(r"python3 (-I )?scripts/verify-release-apks\.py", l))
collect = first(lambda l: "scripts/collect-release-apks.sh" in l)
publish = first(lambda l: "sha256sum" in l or re.search(
    r"uses: (actions/(upload-artifact|attest-[\w-]+)|r0adkll/upload-google-play)@|gh release (create|upload)", l))
if verify is None:
    problems.append("no step runs scripts/verify-release-apks.py")
else:
    if publish is not None and publish < verify:
        problems.append(f"'{steps[publish][0]}' runs before the release files are verified")
    if collect is None or collect > verify:
        problems.append("the release files are verified before the APKs are collected")
for p in problems:
    print(f"android-release.yml release: {p}")
sys.exit(1 if problems else 0)
PY
}

check "$WORKFLOW"
check_release "$RELEASE"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# expect_failure [--release] <name> <Python writing argv[1], the workflow, broken that way to argv[2]>
expect_failure() {
  local checker=check source="$WORKFLOW"
  if [[ "$1" == "--release" ]]; then checker=check_release source="$RELEASE"; shift; fi
  local name="$1" broken="$work/$1.yml"
  python3 -I -c "$2" "$source" "$broken"
  if cmp -s "$source" "$broken"; then
    echo "test-workflow-guards: the '$name' copy is unchanged; the rule is not exercised" >&2
    exit 1
  fi
  if "$checker" "$broken" >/dev/null; then
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
# The release job: no APK per architecture, no check, and the check too late or too early.
VERIFY_STEP='re.search(r"\n      - name: Verify release APKs and bundle\n.*?(?=\n      - name: )", s, re.S).group(0)'
expect_failure --release no-abi-splits '
import sys
s = open(sys.argv[1]).read()
s = s.replace(" -Pomniterm.abiSplits=true", "")
open(sys.argv[2], "w").write(s)'
expect_failure --release no-verify "
import re, sys
s = open(sys.argv[1]).read()
s = s.replace($VERIFY_STEP, '')
open(sys.argv[2], 'w').write(s)"
expect_failure --release verify-after-checksums "
import re, sys
s = open(sys.argv[1]).read()
step = $VERIFY_STEP
s = s.replace(step, '').replace('\n      - name: Upload workflow artifacts\n', step + '\n\n      - name: Upload workflow artifacts\n')
open(sys.argv[2], 'w').write(s)"
expect_failure --release verify-before-collect "
import re, sys
s = open(sys.argv[1]).read()
step = $VERIFY_STEP
s = s.replace(step, '').replace('\n      - name: Collect GitHub Release outputs (APK)\n', step + '\n\n      - name: Collect GitHub Release outputs (APK)\n')
open(sys.argv[2], 'w').write(s)"

echo "test-workflow-guards: workflow wiring checks passed"
