#!/usr/bin/env bash
# Regression tests for the "Detect ... changes" jobs in the PR workflows.
#
# These detectors decide whether the heavy required jobs run. A detector that wrongly reports
# "no code changed" reports SUCCESS while the analysis it guards never executes, so a bug here is
# invisible in the PR checks list. That is exactly what happened on PR #92 head b691ddd: 580
# changed paths (28,959 bytes) including app/** selected the no-code-change branch, the
# "Analyze Java/Kotlin" companion no-op reported pass in 3s, and CodeQL never analysed the code.
#
# Cause: `if echo "$changed" | grep -qE '<paths>'`. grep -q exits at its first match and closes
# the pipe; once the changed-path list is larger than grep's first read, the producing echo dies
# of SIGPIPE (141) and `set -o pipefail` makes the pipeline non-zero even though grep matched.
# The `if` then takes the else branch. Reproduced on GNU grep 3.12 at ~48 KB of changed paths.
#
# The tests below extract the REAL run: script out of each workflow file and execute it against a
# stubbed git, so they exercise the shipped detector rather than a copy of it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
checks=0

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$*" >&2
}

pass() {
  checks=$((checks + 1))
  printf 'ok: %s\n' "$*"
}

# ---------------------------------------------------------------------------
# Extract a step's `run: |` block from a workflow, by step id.
# ---------------------------------------------------------------------------
extract_run() {
  local workflow="$1" step_id="$2"
  python3 - "$workflow" "$step_id" <<'PY'
import sys, textwrap
workflow, step_id = sys.argv[1], sys.argv[2]
lines = open(workflow).read().splitlines(True)
start = None
for i, line in enumerate(lines):
    if line.strip() == "- id: %s" % step_id:
        start = i
        break
if start is None:
    sys.exit("step id %r not found in %s" % (step_id, workflow))
run_at = None
for i in range(start + 1, len(lines)):
    stripped = lines[i].strip()
    if stripped == "run: |":
        run_at = i
        break
    if stripped.startswith("- ") or (stripped and not lines[i].startswith(" " * 8)):
        break
if run_at is None:
    sys.exit("no 'run: |' block for step %r in %s" % (step_id, workflow))
indent = len(lines[run_at]) - len(lines[run_at].lstrip(" ")) + 2
body = []
for line in lines[run_at + 1:]:
    if line.strip() and not line.startswith(" " * indent):
        break
    body.append(line[indent:] if line.strip() else "\n")
script = "".join(body)
# The only GitHub expression allowed inside these detectors is the event name; anything else
# would silently become a literal here and the test would stop testing the real thing.
script = script.replace("${{ github.event_name }}", "${TEST_EVENT_NAME}")
if "${{" in script:
    sys.exit("unsupported GitHub expression left in %s/%s:\n%s" % (workflow, step_id, script))
sys.stdout.write(script)
PY
}

# ---------------------------------------------------------------------------
# Run one extracted detector against a fixture list of changed paths.
# Echoes the resulting code=<value>, or "code=<missing>".
# ---------------------------------------------------------------------------
run_detector() {
  local script="$1" fixture="$2" event="${3:-pull_request}" git_mode="${4:-ok}" grep_mode="${5:-real}"
  local case_dir; case_dir="$(mktemp -d "$WORK/case.XXXXXX")"
  local bin="$case_dir/bin"
  mkdir -p "$bin"

  # git stub: only `git diff --name-only <base> <head>` is used by these detectors.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "${1:-}" = "diff" ]; then\n'
    if [ "$git_mode" = "fail" ]; then
      printf '  echo "fatal: bad object" >&2; exit 128\n'
    else
      printf '  cat %q; exit 0\n' "$fixture"
    fi
    printf 'fi\nexit 0\n'
  } > "$bin/git"
  chmod +x "$bin/git"

  case "$grep_mode" in
    error)
      # grep exit status >1 means a real error (bad pattern, unreadable file), never "no match".
      printf '#!/usr/bin/env bash\necho "grep: stub failure" >&2\nexit 2\n' > "$bin/grep"
      chmod +x "$bin/grep"
      ;;
    early-exit)
      # A matcher that reports a match and exits WITHOUT draining its input. Any detector that
      # feeds the matcher through a pipe loses to SIGPIPE here regardless of grep's real buffer
      # size, which makes the SIGPIPE regression deterministic on every host.
      printf '#!/usr/bin/env bash\nhead -c 1 "${!#}" >/dev/null 2>&1 || head -c 1 >/dev/null\nexit 0\n' \
        > "$bin/grep"
      chmod +x "$bin/grep"
      ;;
  esac

  GITHUB_OUTPUT="$case_dir/output" \
  BASE_SHA=0000000000000000000000000000000000000000 \
  HEAD_SHA=1111111111111111111111111111111111111111 \
  TEST_EVENT_NAME="$event" \
  PATH="$bin:$PATH" \
    bash -c "$script" > "$case_dir/stdout" 2> "$case_dir/stderr"

  local value
  value="$(sed -n 's/^code=//p' "$case_dir/output" 2>/dev/null | tail -n 1)"
  if [ -z "$value" ]; then
    echo "code=<missing>"
    sed -n '1,20p' "$case_dir/stderr" >&2
  else
    echo "code=$value"
  fi
}

expect() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "code=$expected" ]; then
    pass "$label -> $actual"
  else
    fail "$label: expected code=$expected, got $actual"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
filler() { # filler <count> <prefix>
  python3 -c 'import sys; n=int(sys.argv[1]); p=sys.argv[2]; print("\n".join("%s/f%06d.md" % (p, i) for i in range(n)))' "$1" "$2"
}

# ---------------------------------------------------------------------------
# Per-workflow expectations
# ---------------------------------------------------------------------------
# workflow | step id | a path that MUST trigger the build | the same path buried one level deep
DETECTORS=(
  ".github/workflows/codeql.yml|decide|app/build.gradle.kts|docs/app/build.gradle.kts"
  ".github/workflows/android-pr-check.yml|filter|app/build.gradle.kts|docs/app/build.gradle.kts"
  ".github/workflows/flutter-pr-check.yml|filter|flutter_app/lib/main.dart|docs/flutter_app/lib/main.dart"
)

for entry in "${DETECTORS[@]}"; do
  IFS='|' read -r workflow step_id match_path trap_path <<< "$entry"
  name="$(basename "$workflow")"
  echo
  echo "== $name ($step_id) =="

  # A detector that still pipes into grep -q can silently skip a required analysis. Keep the
  # shape itself out of the tree, not just its symptom.
  # ^[^#]* keeps this from matching the explanatory comment inside the workflow itself.
  if grep -nE '^[^#]*echo +"\$changed" *\| *grep' "$REPO_ROOT/$workflow" >/dev/null 2>&1; then
    fail "$name pipes the changed-path list into grep; use a file (see this script's header)"
  else
    pass "$name does not pipe the changed-path list into grep"
  fi

  script="$(extract_run "$REPO_ROOT/$workflow" "$step_id")" || { fail "$name: could not extract $step_id"; continue; }

  fix="$WORK/$name"
  mkdir -p "$fix"

  # 1. THE REGRESSION. Matching path first, then a long tail. Pre-fix this returns code=false
  #    because grep -q closes the pipe and pipefail sees echo's SIGPIPE.
  { echo "$match_path"; filler 40000 docs; } > "$fix/early-long"
  expect "$name: matching path first in a 40k-path list" true \
    "$(run_detector "$script" "$fix/early-long")"

  # 2. Same, with a matcher that provably never drains its input: host-independent proof that the
  #    detector does not depend on the matcher reading to EOF.
  expect "$name: non-draining matcher on a 40k-path list" true \
    "$(run_detector "$script" "$fix/early-long" pull_request ok early-exit)"

  # 3. Matching path LAST: the fixture and pattern are right even when nothing exits early.
  { filler 40000 docs; echo "$match_path"; } > "$fix/late-long"
  expect "$name: matching path last in a 40k-path list" true \
    "$(run_detector "$script" "$fix/late-long")"

  # 4. The shape of the head that actually skipped CodeQL: match at line 19 of 580 paths.
  { filler 18 docs; echo "$match_path"; filler 561 docs; } > "$fix/head-shape"
  expect "$name: matching path at line 19 of 580" true \
    "$(run_detector "$script" "$fix/head-shape")"

  # 5. Docs only really must skip; the detector is not allowed to just answer true.
  filler 500 docs > "$fix/no-match"
  expect "$name: documentation-only change" false \
    "$(run_detector "$script" "$fix/no-match")"

  # 6. Anchoring: the same filename one directory deeper must NOT trigger a build.
  { filler 20 docs; echo "$trap_path"; } > "$fix/trap"
  expect "$name: include prefixes stay anchored to the start of the path" false \
    "$(run_detector "$script" "$fix/trap")"

  # 7. Paths containing spaces must not split, drop, or fake a match.
  { printf 'docs/release notes.md\ndocs/a b/c d.md\n'; } > "$fix/spaces-nomatch"
  expect "$name: paths with spaces, no match" false \
    "$(run_detector "$script" "$fix/spaces-nomatch")"
  { printf 'docs/release notes.md\n'; echo "$match_path"; } > "$fix/spaces-match"
  expect "$name: paths with spaces, real match" true \
    "$(run_detector "$script" "$fix/spaces-match")"

  # 8. Empty diff is a genuine no-match, not an error.
  : > "$fix/empty"
  expect "$name: empty changed-path list" false \
    "$(run_detector "$script" "$fix/empty")"

  # 9. git diff failure fails safe to a full run.
  expect "$name: git diff failure fails safe" true \
    "$(run_detector "$script" "$fix/no-match" pull_request fail)"

  # 10. grep failing for a real reason (status >1) is not "no match" either.
  expect "$name: grep error fails safe" true \
    "$(run_detector "$script" "$fix/no-match" pull_request ok error)"
done

# ---------------------------------------------------------------------------
# CodeQL only: push and schedule are the prerelease gate and must never skip.
# ---------------------------------------------------------------------------
echo
echo "== codeql.yml prerelease gate =="
codeql_script="$(extract_run "$REPO_ROOT/.github/workflows/codeql.yml" decide)"
filler 500 docs > "$WORK/docs-only"
for event in push schedule workflow_dispatch; do
  expect "codeql.yml: $event runs the full analysis even for docs-only changes" true \
    "$(run_detector "$codeql_script" "$WORK/docs-only" "$event")"
done

echo
if [ "$failures" -ne 0 ]; then
  printf '%d check(s) failed, %d passed\n' "$failures" "$checks" >&2
  exit 1
fi
printf 'All %d change-detector checks passed\n' "$checks"
