#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

FAKE_GRADLEW="$TMP_DIR/gradlew"
INVOCATIONS="$TMP_DIR/invocations"

cat >"$FAKE_GRADLEW" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s\n' '<invocation>'
  printf '%s\n' "$@"
  printf '%s\n' '</invocation>'
} >>"$OMNITERM_GRADLE_INVOCATIONS"
EOF
chmod +x "$FAKE_GRADLEW"

COMMON_EXPECTED="$TMP_DIR/common-expected"
cat >"$COMMON_EXPECTED" <<'EOF'
--no-daemon
--no-build-cache
--no-configuration-cache
--max-workers=2
-Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8
-Pkotlin.daemon.jvmargs=-Xmx4g
-Domniterm.publishScan=true
EOF

assert_invocation_count() {
  local expected="$1"
  local actual
  actual="$(grep -c '^<invocation>$' "$INVOCATIONS")"
  [[ "$actual" == "$expected" ]] || {
    echo "expected $expected Gradle invocation(s), got $actual" >&2
    exit 1
  }
}

assert_common_args() {
  local invocation="$1"
  local actual="$TMP_DIR/common-actual-$invocation"
  awk -v wanted="$invocation" '
    /^<invocation>$/ { current++; next }
    /^<\/invocation>$/ { next }
    current == wanted && /^--no-daemon$/ { common = 1 }
    current == wanted && common { print }
  ' "$INVOCATIONS" >"$actual"
  diff -u "$COMMON_EXPECTED" "$actual"
}

export OMNITERM_GRADLEW="$FAKE_GRADLEW"
export OMNITERM_GRADLE_INVOCATIONS="$INVOCATIONS"

GITHUB_EVENT_NAME=pull_request "$ROOT/scripts/ci-gradle-gate.sh"
assert_invocation_count 1
cp "$INVOCATIONS" "$TMP_DIR/pr-invocation"
sed -n '/^<invocation>$/,/^--no-daemon$/p' "$INVOCATIONS" | sed '1d;$d' >"$TMP_DIR/pr-tasks"
cat >"$TMP_DIR/compile-expected" <<'EOF'
:app:assembleOpenSourceDebug
:app:assemblePlayStoreDebug
EOF
diff -u "$TMP_DIR/compile-expected" "$TMP_DIR/pr-tasks"
assert_common_args 1

: >"$INVOCATIONS"
GITHUB_EVENT_NAME=push "$ROOT/scripts/ci-gradle-gate.sh"
assert_invocation_count 2
assert_common_args 1
assert_common_args 2
sed -n '1,/^<\/invocation>$/p' "$INVOCATIONS" >"$TMP_DIR/main-compile-invocation"
diff -u "$TMP_DIR/pr-invocation" "$TMP_DIR/main-compile-invocation"
sed -n '/^<invocation>$/,/^--no-daemon$/p' "$INVOCATIONS" |
  awk '
    /^<invocation>$/ { invocation++; next }
    /^--no-daemon$/ { next }
    invocation == 2 { print }
  ' >"$TMP_DIR/main-tasks"
cat >"$TMP_DIR/main-expected" <<'EOF'
:app:testOpenSourceDebugUnitTest
:app:testPlayStoreDebugUnitTest
:app:lintOpenSourceDebug
:app:lintPlayStoreDebug
EOF
diff -u "$TMP_DIR/main-expected" "$TMP_DIR/main-tasks"

grep -Fq './scripts/ci-gradle-gate.sh' "$ROOT/.github/workflows/codeql.yml"
grep -Fq '\.github/workflows/codeql\.yml' "$ROOT/.github/workflows/codeql.yml"

echo "CI Gradle gate tests passed"
