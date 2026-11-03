#!/usr/bin/env bash
# Exercise the real wrapper with isolated Git repositories and a Docker argument recorder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo/scripts" "$WORK/bin"
cp "$ROOT/scripts/secret-scan.sh" "$WORK/repo/scripts/"
git -C "$WORK/repo" init -q
git -C "$WORK/repo" -c user.name=Test -c user.email=test@example.invalid \
  -c commit.gpgsign=false commit --allow-empty -qm base
cat > "$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) exit "${SCAN_DOCKER_STATUS:-0}" ;;
  image) exit "${SCAN_IMAGE_STATUS:-0}" ;;
  pull) printf 'pull\n' >> "$SCAN_CALLS" ;;
  run) printf '%s\n' "$@" >> "$SCAN_CALLS"; exit "${SCAN_RESULT:-0}" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH" SCAN_CALLS="$WORK/calls"
scan() { "$WORK/repo/scripts/secret-scan.sh" "$@"; }
expect_failure() {
  local expected="$1"
  shift
  if "$@" > "$WORK/error" 2>&1; then
    echo "secret-scan: expected failure for $*" >&2
    exit 1
  fi
  if [[ -n "$expected" ]]; then grep -Fq "$expected" "$WORK/error"; fi
}

scan
grep -Fxq 'git' "$SCAN_CALLS"
grep -Fxq -- '--redact' "$SCAN_CALLS"
grep -Fxq -- '--no-color' "$SCAN_CALLS"
grep -Fxq -- '--staged' "$SCAN_CALLS"
[[ "$(grep -Fxc run "$SCAN_CALLS")" == 3 ]]
grep -Fxq "$WORK/repo:$WORK/repo:ro" "$SCAN_CALLS"
grep -Fxq "$WORK/repo/.git:$WORK/repo/.git:ro" "$SCAN_CALLS"
grep -Fxq "GIT_CONFIG_VALUE_0=$WORK/repo" "$SCAN_CALLS"
expect_failure 'running Docker daemon' env SCAN_DOCKER_STATUS=1 "$WORK/repo/scripts/secret-scan.sh"
expect_failure 'docker pull zricethezav/gitleaks@sha256:' \
  env SCAN_IMAGE_STATUS=1 "$WORK/repo/scripts/secret-scan.sh"
SCAN_IMAGE_STATUS=1 scan --pull
grep -Fxq pull "$SCAN_CALLS"
expect_failure '' env SCAN_RESULT=23 "$WORK/repo/scripts/secret-scan.sh"
expect_failure 'Usage:' scan --unknown

# Staged credential containers fail before Docker runs, including case and newline filenames.
for filename in google-services.json team-service-account.json TEST.PEM debug.keystore.base64 \
  $'line\nbreak.p12'; do
  : > "$WORK/repo/$filename"
  git -C "$WORK/repo" add -- "$filename"
  : > "$SCAN_CALLS"
  expect_failure 'Credential-like files must never be committed:' scan
  [[ ! -s "$SCAN_CALLS" ]]
  git -C "$WORK/repo" reset -q -- "$filename"
  rm -- "$WORK/repo/$filename"
done

git -C "$WORK/repo" worktree add -q --detach "$WORK/linked checkout"
mkdir -p "$WORK/linked checkout/scripts"
cp "$ROOT/scripts/secret-scan.sh" "$WORK/linked checkout/scripts/"
: > "$SCAN_CALLS"
"$WORK/linked checkout/scripts/secret-scan.sh"
grep -Fxq "$WORK/linked checkout:$WORK/linked checkout:ro" "$SCAN_CALLS"
grep -Fxq "$WORK/repo/.git:$WORK/repo/.git:ro" "$SCAN_CALLS"
git clone -q --depth=1 "file://$WORK/repo" "$WORK/shallow"
mkdir -p "$WORK/shallow/scripts"
cp "$ROOT/scripts/secret-scan.sh" "$WORK/shallow/scripts/"
expect_failure 'git fetch --unshallow' "$WORK/shallow/scripts/secret-scan.sh"

# All security gates call the wrapper; the image pin has a single source of truth.
for caller in scripts/local-pr-check.sh .github/workflows/secret-scan.yml .github/workflows/codeql.yml; do
  grep -Fq './scripts/secret-scan.sh' "$ROOT/$caller"
  if grep -Fq 'zricethezav/gitleaks@' "$ROOT/$caller"; then
    echo "secret-scan: duplicate image pin in $caller" >&2
    exit 1
  fi
done
echo 'Secret scanner checks passed.'
