#!/usr/bin/env bash
# Keep local preflight and the PR/release security gates on the same complete-history scan.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
IMAGE=zricethezav/gitleaks@sha256:e1b35e12a8c6fa8901f060459cfb6b2fc4c484d3afbe3b029733a3bbfab07055
PULL=false
case "${1:-}" in
  '') ;;
  --pull) PULL=true ;;
  *) echo "Usage: $0 [--pull]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--pull]" >&2; exit 2; }

# Read the index, including additions not yet committed, and preserve filenames verbatim.
python3 - <<'PY'
import re
import subprocess
import sys

pattern = re.compile(
    r'(^|/)(google-services\.json|[^/]*(service.account|service-account)[^/]*\.json|'
    r'[^/]+\.(jks|keystore|p12|pfx|pem)|'
    r'[^/]*(keystore|private.key|service.account)[^/]*\.(base64|b64))$', re.I
)
tracked = subprocess.check_output(['git', 'ls-files', '-z']).decode('utf-8', 'surrogateescape')
rejected = [path for path in tracked.split('\0') if pattern.search(path)]
if rejected:
    print('Credential-like files must never be committed:', file=sys.stderr)
    for path in rejected:
        print(repr(path), file=sys.stderr)
    sys.exit(1)
PY

if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  echo "Secret scanning requires complete history. Run: git fetch --unshallow" >&2
  exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "Secret scanning requires a running Docker daemon accessible to this user." >&2
  exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  if [[ "$PULL" == true ]]; then
    docker pull "$IMAGE"
  else
    echo "The pinned secret scanner is missing. Install it with: docker pull $IMAGE" >&2
    exit 1
  fi
fi

# Linked worktrees have a .git FILE pointing outside the checkout. Mount their shared object
# store at its real absolute path as well, so Git follows that pointer inside the container.
COMMON_DIR="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
SCANNER=(
  docker run --rm --network none
  -v "$ROOT:$ROOT:ro" -v "$COMMON_DIR:$COMMON_DIR:ro" -w "$ROOT"
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e "GIT_CONFIG_VALUE_0=$ROOT"
  "$IMAGE" git --redact --no-banner --no-color
)
"${SCANNER[@]}" "$ROOT"
# History alone cannot catch a leak until after it is committed. Check both local diffs too;
# these are empty on CI's clean checkout. Newly created files enter this scan once staged.
"${SCANNER[@]}" --pre-commit "$ROOT"
"${SCANNER[@]}" --pre-commit --staged "$ROOT"
