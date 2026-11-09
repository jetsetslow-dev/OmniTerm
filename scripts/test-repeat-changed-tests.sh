#!/usr/bin/env bash
# Pins scripts/repeat-changed-tests.sh: it repeats the test classes a change adds, edits or
# renames, not helpers without tests or untouched classes, fails when any repeat fails, and runs
# the repeats on only the processors --cpus allows.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/repeat-changed-tests.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "repeat-changed-tests: $*" >&2
  exit 1
}

REPO="$WORK/repo"
PKG="$REPO/app/src/test/java/com/example"
mkdir -p "$PKG"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false
test_class() { printf 'package com.example\n\nclass %s {\n    @Test fun %s() = Unit\n}\n' "$1" "$2"; }
test_class KeptTest kept > "$PKG/KeptTest.kt"
test_class EditedTest before > "$PKG/EditedTest.kt"
test_class MovedTest moved > "$PKG/MovedTest.kt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm base
BASE="$(git -C "$REPO" rev-parse HEAD)"

test_class EditedTest after > "$PKG/EditedTest.kt"
test_class AddedTest added > "$PKG/AddedTest.kt"
printf 'package com.example\n\ninternal fun sharedHelper() = Unit\n' > "$PKG/SharedHelper.kt"
mkdir -p "$PKG/inner"
git -C "$REPO" mv "$PKG/MovedTest.kt" "$PKG/inner/MovedTest.kt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm change
test_class LocalTest local > "$PKG/LocalTest.kt"

listed() { (cd "$REPO" && "$SCRIPT" --base "$BASE" --list "$@"); }

expected="com.example.AddedTest
com.example.EditedTest
com.example.inner.MovedTest"
[[ "$(listed)" == "$expected" ]] || fail "committed changes listed as: $(listed)"
# The script sorts in the C locale whatever the caller uses, so LocalTest comes before inner/.
[[ "$(LC_ALL=en_US.UTF-8 listed --worktree 2>/dev/null)" == "com.example.AddedTest
com.example.EditedTest
com.example.LocalTest
com.example.inner.MovedTest" ]] || fail "--worktree listed as: $(listed --worktree)"

FAKE_GRADLEW="$WORK/gradlew"
cat > "$FAKE_GRADLEW" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OMNITERM_TEST_INVOCATIONS"
[[ -r /proc/self/status ]] && awk '$1 == "Cpus_allowed_list:" { print $2 }' /proc/self/status >> "$OMNITERM_TEST_INVOCATIONS.cpus"
[[ -z "${OMNITERM_TEST_FAIL_ON:-}" ]] && exit 0
[[ "$(wc -l < "$OMNITERM_TEST_INVOCATIONS")" -lt "$OMNITERM_TEST_FAIL_ON" ]]
EOF
chmod +x "$FAKE_GRADLEW"
export OMNITERM_GRADLEW="$FAKE_GRADLEW" OMNITERM_TEST_INVOCATIONS="$WORK/invocations"

(cd "$REPO" && "$SCRIPT" --base "$BASE" --runs 3 -- --no-daemon) > /dev/null
[[ "$(wc -l < "$WORK/invocations")" -eq 3 ]] || fail "expected 3 Gradle runs, got $(wc -l < "$WORK/invocations")"
want=":app:testPlayStoreDebugUnitTest --tests com.example.AddedTest --tests com.example.EditedTest --tests com.example.inner.MovedTest --rerun --no-daemon"
while IFS= read -r line; do
  [[ "$line" == "$want" ]] || fail "unexpected Gradle arguments: $line"
done < "$WORK/invocations"

rm -f "$WORK/invocations"
status=0
(cd "$REPO" && OMNITERM_TEST_FAIL_ON=2 "$SCRIPT" --base "$BASE" --runs 5) > /dev/null 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail "a failing repeat exited $status instead of 1"
[[ "$(wc -l < "$WORK/invocations")" -eq 2 ]] || fail "kept running after a failed repeat"

if command -v taskset >/dev/null 2>&1 && [[ -r /proc/self/status ]]; then
  rm -f "$WORK/invocations" "$WORK/invocations.cpus"
  (cd "$REPO" && "$SCRIPT" --base "$BASE" --runs 2 --cpus 1) > /dev/null
  [[ "$(sort -u "$WORK/invocations.cpus")" == "0" ]] || fail "--cpus 1 ran Gradle on $(sort -u "$WORK/invocations.cpus" | tr '\n' ' ')"
  [[ "$(wc -l < "$WORK/invocations.cpus")" -eq 2 ]] || fail "--cpus ran $(wc -l < "$WORK/invocations.cpus") repeats, not 2"
  # A running Gradle daemon would not be held to the limit.
  [[ "$(tail -1 "$WORK/invocations")" == *" --no-daemon" ]] || fail "--cpus let Gradle use a daemon: $(tail -1 "$WORK/invocations")"
  rm -f "$WORK/invocations.cpus"
  (cd "$REPO" && "$SCRIPT" --base "$BASE" --runs 1) > /dev/null
  [[ "$(cat "$WORK/invocations.cpus")" != "0" ]] || fail "without --cpus, Gradle still ran on processor 0 alone"
fi
status=0
(cd "$REPO" && "$SCRIPT" --base "$BASE" --cpus 0) > /dev/null 2>&1 || status=$?
[[ "$status" -eq 2 ]] || fail "--cpus 0 exited $status instead of 2"

rm -f "$WORK/invocations"
(cd "$REPO" && "$SCRIPT" --base HEAD --runs 3) > /dev/null
[[ ! -e "$WORK/invocations" ]] || fail "ran Gradle with no changed test classes"

echo "repeat-changed-tests checks passed."
