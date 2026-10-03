#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$ROOT/scripts/resolve-release-version.sh"
TEST_ROOT="$(mktemp -d)"
REPO="$TEST_ROOT/repo"
MOCK_BIN="$TEST_ROOT/bin"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "release-resolution test: $*" >&2
  exit 1
}

assert_output() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(sed -n "s/^${key}=//p" "$GITHUB_OUTPUT")"
  [[ "$actual" == "$expected" ]] ||
    fail "expected output $key=$expected, got $actual"
}

mkdir -p "$REPO" "$MOCK_BIN"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Release Test"
git -C "$REPO" config user.email "release-test@example.invalid"
git -C "$REPO" commit --allow-empty -q -m initial
export BUILD_SHA="$(git -C "$REPO" rev-parse HEAD)"

cat > "$MOCK_BIN/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
if [[ "$args" == *"/releases/tags/"* ]]; then
  requested="${args##*/releases/tags/}"
  requested="${requested%% *}"
  if [[ -n "${MOCK_RELEASE_JSON:-}" && "$requested" == "${MOCK_RELEASE_JSON_TAG:-}" ]]; then
    printf '%s\n' "$MOCK_RELEASE_JSON"
    exit 0
  fi
  exit 1
fi
if [[ "$args" == *"target_commitish == env.BUILD_SHA"* ]]; then
  printf '%s\n' "${MOCK_SHA_TAGS:-}"
  exit 0
fi
if [[ "$args" == *"prerelease == true"* ]]; then
  printf '%s\n' "${MOCK_PRERELEASE_TAGS:-}"
  exit 0
fi
if [[ "$args" == *"/releases?per_page=100"* ]]; then
  printf '%s\n' "${MOCK_RELEASE_TAGS:-}"
  exit 0
fi
echo "unexpected mock gh invocation: $args" >&2
exit 64
MOCK_GH
chmod +x "$MOCK_BIN/gh"

export PATH="$MOCK_BIN:$PATH"
export GITHUB_REPOSITORY=example/omniterm
export GITHUB_ENV="$TEST_ROOT/github-env"
export GITHUB_OUTPUT="$TEST_ROOT/github-output"

reset_case() {
  : > "$GITHUB_ENV"
  : > "$GITHUB_OUTPUT"
  unset GITHUB_REF_TYPE GITHUB_REF_NAME INPUT_RELEASE_TAG INPUT_RELEASE_CHANNEL
  unset INPUT_VERSION_CODE MOCK_RELEASE_TAGS MOCK_SHA_TAGS MOCK_PRERELEASE_TAGS
  unset MOCK_RELEASE_JSON MOCK_RELEASE_JSON_TAG
  export PUBLISH_EXTERNAL=false
}

run_resolver() {
  (cd "$REPO" && "$RESOLVER")
}

# A successful main aggregate allocates the next prerelease after the repository's consumed
# baseline. Both publishers must receive the exact same packed Android identity.
reset_case
export GITHUB_EVENT_NAME=workflow_run
run_resolver >/dev/null
assert_output release_label v0.9.240-main.1
assert_output code 924001
assert_output release_prerelease true

# Re-running the same source commit reuses its API release even when the draft has not created a
# local git tag yet.
reset_case
export GITHUB_EVENT_NAME=workflow_run
export MOCK_RELEASE_TAGS=v0.9.240-main.1
export MOCK_SHA_TAGS=v0.9.240-main.1
run_resolver >/dev/null
assert_output release_label v0.9.240-main.1

# Manual prereleases advance one patch and keep a promotable build slot.
reset_case
export GITHUB_EVENT_NAME=workflow_dispatch
export INPUT_RELEASE_CHANNEL=prerelease
export MOCK_RELEASE_TAGS=v0.9.240-main.1
run_resolver >/dev/null
assert_output release_label v0.9.241-manual.1
assert_output code 924101

# A published release is the idempotency marker: a retry must not upload its versionCode to Play.
reset_case
export GITHUB_EVENT_NAME=workflow_dispatch
export INPUT_RELEASE_CHANNEL=prerelease
export INPUT_RELEASE_TAG=v0.9.240-main.1
export MOCK_RELEASE_TAGS=v0.9.240-main.1
export MOCK_RELEASE_JSON_TAG=v0.9.240-main.1
export MOCK_RELEASE_JSON="{\"draft\":false,\"target_commitish\":\"$BUILD_SHA\"}"
run_resolver >/dev/null
assert_output release_already_published true

# Different labels that pack to one Play versionCode are always rejected.
reset_case
export GITHUB_EVENT_NAME=workflow_dispatch
export INPUT_RELEASE_CHANNEL=prerelease
export INPUT_RELEASE_TAG=v0.9.240-main.1
export MOCK_RELEASE_TAGS=v0.9.240-Alpha
if run_resolver >"$TEST_ROOT/collision.out" 2>&1; then
  fail "accepted two tags with the same packed versionCode"
fi
grep -q "aliases an Android versionCode" "$TEST_ROOT/collision.out" ||
  fail "collision failure did not explain the versionCode alias"

# Production is promotion of a published prerelease built from this exact SHA.
git -C "$REPO" tag v0.9.241-main.1 "$BUILD_SHA"
reset_case
export GITHUB_EVENT_NAME=workflow_dispatch
export INPUT_RELEASE_CHANNEL=production
export INPUT_RELEASE_TAG=v0.9.241
export PUBLISH_EXTERNAL=true
export MOCK_RELEASE_TAGS=v0.9.241-main.1
export MOCK_PRERELEASE_TAGS=v0.9.241-main.1
run_resolver >/dev/null
assert_output release_label v0.9.241
assert_output code 924199
assert_output release_prerelease false

# The same promotion without a matching published prerelease is forbidden.
reset_case
export GITHUB_EVENT_NAME=workflow_dispatch
export INPUT_RELEASE_CHANNEL=production
export INPUT_RELEASE_TAG=v0.9.242
export PUBLISH_EXTERNAL=true
export MOCK_RELEASE_TAGS=v0.9.241-main.1
if run_resolver >"$TEST_ROOT/promotion.out" 2>&1; then
  fail "accepted production without a published same-SHA prerelease"
fi
grep -q "requires a published" "$TEST_ROOT/promotion.out" ||
  fail "promotion failure did not explain the prerelease requirement"

# An existing immutable tag may never relabel another source commit.
git -C "$REPO" commit --allow-empty -q -m second
export BUILD_SHA="$(git -C "$REPO" rev-parse HEAD)"
reset_case
export GITHUB_EVENT_NAME=push
export GITHUB_REF_TYPE=tag
export GITHUB_REF_NAME=v0.9.241-main.1
export MOCK_RELEASE_TAGS=v0.9.241-main.1
if run_resolver >"$TEST_ROOT/source.out" 2>&1; then
  fail "accepted an existing release tag for a different source commit"
fi
grep -q "not this build's" "$TEST_ROOT/source.out" ||
  fail "source mismatch did not identify the conflicting commit"

echo "release-resolution tests passed"
