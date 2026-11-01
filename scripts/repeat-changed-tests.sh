#!/usr/bin/env bash
# Runs the unit-test classes a change adds or edits several more times. A test that depends on
# timing can pass once on its pull request and fail on main afterwards:
# FleetBroadcastOutcomeRobolectricTest passed PR Check on 521b811 and failed the release build of
# the identical tree, 2ed805c. Repeating the classes a change touches catches most such tests
# before the merge. scripts/test-repeat-changed-tests.sh pins this behaviour.
#
# Usage: repeat-changed-tests.sh --base <ref> [--runs N] [--worktree] [--list] [-- <gradle args>]
#   --base      what the change is measured from: the PR's base commit, or origin/main locally
#   --runs      how many more times to run them (default 5)
#   --worktree  also count uncommitted and untracked test files (the local preflight)
#   --list      print the classes and stop
set -euo pipefail

usage() {
  echo "Usage: $0 --base <ref> [--runs N] [--worktree] [--list] [-- <gradle args>]" >&2
  exit 2
}

BASE=""
RUNS=5
WORKTREE=false
LIST=false
GRADLE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) [[ $# -ge 2 ]] || usage; BASE="$2"; shift 2 ;;
    --runs) [[ $# -ge 2 ]] || usage; RUNS="$2"; shift 2 ;;
    --worktree) WORKTREE=true; shift ;;
    --list) LIST=true; shift ;;
    --) shift; GRADLE_ARGS=("$@"); break ;;
    *) usage ;;
  esac
done
[[ -n "$BASE" ]] || usage
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "--runs must be a positive whole number" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
GRADLEW="${OMNITERM_GRADLEW:-$ROOT/gradlew}"
TEST_ROOT=app/src/test/java

# Measured from the merge base where there is history. CI's shallow checkout of the PR's merge
# commit has none; there the base commit is that merge commit's parent, so it is the merge base.
FROM="$(git merge-base "$BASE" HEAD 2>/dev/null || git rev-parse --verify --quiet "$BASE^{commit}")" || {
  echo "Cannot find $BASE to compare against." >&2
  exit 1
}

changed_paths() {
  git diff --name-only --diff-filter=AMR "$FROM" HEAD -- "$TEST_ROOT"
  if [[ "$WORKTREE" == "true" ]]; then
    git diff --name-only --diff-filter=AMR HEAD -- "$TEST_ROOT"
    git ls-files --others --exclude-standard -- "$TEST_ROOT"
  fi
}

CLASSES=()
while IFS= read -r path; do
  [[ "$path" == *.kt && -f "$path" ]] || continue
  # A shared helper has no tests of its own to run. Each test file holds the class it is named for.
  grep -q '@Test' "$path" || continue
  class="${path#"$TEST_ROOT"/}"
  class="${class%.kt}"
  CLASSES+=("${class//\//.}")
done < <(changed_paths | sort -u)

if [[ "$LIST" == "true" ]]; then
  [[ ${#CLASSES[@]} -eq 0 ]] || printf '%s\n' "${CLASSES[@]}"
  exit 0
fi
if [[ ${#CLASSES[@]} -eq 0 ]]; then
  echo "No changed unit-test classes to repeat."
  exit 0
fi

FILTERS=()
for class in "${CLASSES[@]}"; do FILTERS+=(--tests "$class"); done
echo "Repeating ${#CLASSES[@]} changed test class(es) $RUNS more times:"
printf '  %s\n' "${CLASSES[@]}"
for ((run = 1; run <= RUNS; run++)); do
  echo "Repeat $run of $RUNS"
  if ! "$GRADLEW" :app:testPlayStoreDebugUnitTest "${FILTERS[@]}" --rerun ${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"}; then
    echo "A changed test failed on repeat $run of $RUNS after passing: it depends on timing." >&2
    exit 1
  fi
done
