#!/usr/bin/env bash
# Create exactly one release trigger for the current, already-pushed main commit.
#
#   ./scripts/release.sh                     # promote latest prerelease, or bump patch
#   ./scripts/release.sh --prerelease        # next patch as -Alpha
#   ./scripts/release.sh --prerelease rc.2   # next patch with a custom suffix
#   ./scripts/release.sh --tag v1.2.3-rc.2   # explicit packed-SemVer tag
#
# This command intentionally never pushes main. A main push already triggers the
# branch prerelease workflow; pushing main and a tag here would race two Play uploads.
set -euo pipefail

PRERELEASE=false
PRERELEASE_LABEL="Alpha"
EXPLICIT_TAG=""

while (( $# > 0 )); do
  case "$1" in
    --prerelease|--pre|-p)
      PRERELEASE=true
      if (( $# > 1 )) && [[ "$2" != -* ]]; then
        PRERELEASE_LABEL="$2"
        shift
      fi
      ;;
    --tag|-t)
      (( $# > 1 )) || { echo "release: --tag requires a value" >&2; exit 64; }
      EXPLICIT_TAG="$2"
      shift
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "release: unknown argument '$1'" >&2
      exit 64
      ;;
  esac
  shift
done

if [[ -n "$EXPLICIT_TAG" && "$PRERELEASE" == true ]]; then
  echo "release: use either --tag or --prerelease, not both" >&2
  exit 64
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
# shellcheck source=release-version.sh
source "$ROOT/scripts/release-version.sh"

[[ "$(git branch --show-current)" == "main" ]] || {
  echo "release: releases must be cut from main" >&2
  exit 1
}
[[ -z "$(git status --porcelain)" ]] || {
  echo "release: working tree is dirty; commit or stash first" >&2
  git status --short >&2
  exit 1
}

git fetch origin main --tags --prune --quiet
LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse refs/remotes/origin/main)"
[[ "$LOCAL_SHA" == "$REMOTE_SHA" ]] || {
  echo "release: HEAD is not the already-pushed origin/main commit" >&2
  echo "         Push main first and let its automatic prerelease finish; then rerun this command." >&2
  exit 1
}

command -v gh >/dev/null || { echo "release: GitHub CLI (gh) is required" >&2; exit 1; }
GH_REPO="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
LATEST_TAG="$({
  git ls-remote --tags --refs origin 'refs/tags/v*' | awk '{sub("refs/tags/", "", $2); print $2}'
  gh api --paginate "repos/${GH_REPO}/releases?per_page=100" --jq '.[].tag_name'
} | sort -u | version_highest)"
if [[ -z "$LATEST_TAG" && -z "$EXPLICIT_TAG" ]]; then
  echo "release: no packed-SemVer GitHub release exists; pass an initial --tag" >&2
  exit 1
fi

if [[ -n "$EXPLICIT_TAG" ]]; then
  TAG="$EXPLICIT_TAG"
elif [[ "$PRERELEASE" == true ]]; then
  TAG="$(version_next_prerelease "$LATEST_TAG" "$PRERELEASE_LABEL")" || {
    echo "release: cannot derive a prerelease after $LATEST_TAG with label '$PRERELEASE_LABEL'" >&2
    exit 1
  }
else
  TAG="$(version_next_production "$LATEST_TAG")" || {
    echo "release: cannot derive a production release after $LATEST_TAG" >&2
    exit 1
  }
fi

version_validate "$TAG" || {
  echo "release: '$TAG' is not vMAJOR.MINOR.PATCH[-SUFFIX] within packed-version limits" >&2
  exit 1
}
TAG_CODE="$(version_pack "$TAG")"

# A production tag is a promotion, never a second release path started alongside the main push.
# Require the automatic prerelease for this exact SHA and base version to be fully published first.
if [[ "$TAG" != *-* ]]; then
  SHA_PRERELEASES="$(gh api --paginate "repos/${GH_REPO}/releases?per_page=100" \
    --jq '.[] | select(.prerelease == true and .draft == false) | .tag_name')"
  MATCHING_PRERELEASE=""
  while IFS= read -r prerelease_tag; do
    [[ -n "$prerelease_tag" ]] || continue
    PRERELEASE_SHA="$(git rev-list -n 1 "$prerelease_tag" 2>/dev/null || true)"
    if [[ "$prerelease_tag" == "$TAG"-* && "$PRERELEASE_SHA" == "$LOCAL_SHA" ]]; then
      MATCHING_PRERELEASE="$prerelease_tag"
      break
    fi
  done <<< "$SHA_PRERELEASES"
  [[ -n "$MATCHING_PRERELEASE" ]] || {
    echo "release: $TAG requires a published ${TAG}-* prerelease for $LOCAL_SHA" >&2
    echo "         Wait for (or rerun) the automatic main workflow before promoting production." >&2
    exit 1
  }
fi

if [[ -n "$LATEST_TAG" ]]; then
  LATEST_CODE="$(version_pack "$LATEST_TAG")"
  (( TAG_CODE > LATEST_CODE )) || {
    echo "release: $TAG (versionCode $TAG_CODE) must exceed $LATEST_TAG (versionCode $LATEST_CODE)" >&2
    exit 1
  }
fi

if git show-ref --verify --quiet "refs/tags/$TAG" || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "release: tag $TAG already exists; refusing to move or recreate it" >&2
  exit 1
fi

echo "release: $TAG -> versionName=${TAG#v}, versionCode=$TAG_CODE at $LOCAL_SHA"
git tag "$TAG" "$LOCAL_SHA"
if ! git push origin "refs/tags/$TAG"; then
  git tag -d "$TAG" >/dev/null
  echo "release: tag push failed; removed the unpushed local tag" >&2
  exit 1
fi

echo "release: pushed only $TAG; android-release.yml will publish it after tests and Play upload succeed"
echo "         gh run list --workflow=android-release.yml --limit=1"
