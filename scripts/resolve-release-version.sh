#!/usr/bin/env bash
set -euo pipefail

# Resolve one immutable Android version identity for either release engine. Callers provide the
# GitHub event context through the standard GITHUB_* variables plus BUILD_SHA and
# PUBLISH_EXTERNAL. Results are written to GITHUB_ENV/GITHUB_OUTPUT so Kotlin and Flutter cannot
# drift in allocation, retry, promotion, or Play monotonicity behavior.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/release-version.sh"

: "${BUILD_SHA:?BUILD_SHA is required}"
: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

INPUT_RELEASE_TAG="${INPUT_RELEASE_TAG:-}"
INPUT_RELEASE_CHANNEL="${INPUT_RELEASE_CHANNEL:-}"
INPUT_VERSION_CODE="${INPUT_VERSION_CODE:-}"
PUBLISH_EXTERNAL="${PUBLISH_EXTERNAL:-false}"

# The REST endpoint includes drafts. A failed run's draft must remain the high-water mark so a
# queued main push cannot allocate the same version while the retry is pending.
API_RELEASE_TAGS="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
  --jq '.[].tag_name')"
RELEASE_TAGS="$({
  git tag --list 'v*'
  printf '%s\n' "$API_RELEASE_TAGS"
} | sort -u)"
LAST_TAG="$(printf '%s\n' "$RELEASE_TAGS" | version_highest)"

# Play versionCodes from before the approved history reset remain consumed even though those old
# release objects are no longer provenance inputs.
LAST_TAG="${LAST_TAG:-v0.9.239}"

if [ -n "$INPUT_RELEASE_TAG" ]; then
  RELEASE_LABEL="$INPUT_RELEASE_TAG"
elif [ "$GITHUB_EVENT_NAME" != "workflow_dispatch" ] && [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
  RELEASE_LABEL="${GITHUB_REF_NAME}"
elif [ "$GITHUB_EVENT_NAME" = "workflow_run" ]; then
  # Reruns reuse the prerelease pinned to this exact SHA. Draft releases may not have materialized
  # a git tag, so inspect both tags and release targetCommitish values.
  SHA_RELEASE_TAGS="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
    --jq '.[] | select(.target_commitish == env.BUILD_SHA) | .tag_name')"
  RELEASE_LABEL="$({
    git tag --points-at "$BUILD_SHA"
    printf '%s\n' "$SHA_RELEASE_TAGS"
  } | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-' | version_highest || true)"
  if [ -z "$RELEASE_LABEL" ]; then
    RELEASE_LABEL="$(version_next_prerelease "$LAST_TAG" main.1)" || {
      echo "Could not allocate a prerelease after $LAST_TAG" >&2
      exit 1
    }
  fi
else
  if [ "$INPUT_RELEASE_CHANNEL" = "production" ]; then
    RELEASE_LABEL="$(version_next_production "$LAST_TAG")" || {
      echo "Could not allocate a production version after $LAST_TAG" >&2
      exit 1
    }
  else
    RELEASE_LABEL="$(version_next_prerelease "$LAST_TAG" manual.1)" || {
      echo "Could not allocate a prerelease after $LAST_TAG" >&2
      exit 1
    }
  fi
fi

VERSION_CODE_RESOLVED="$(version_pack "$RELEASE_LABEL")" || {
  echo "Release tag '$RELEASE_LABEL' must be vMAJOR.MINOR.PATCH[-SuffixN]" >&2
  echo "(major<=200, minor<=99, patch<=999, suffix build number 1-98)." >&2
  exit 1
}
COLLISIONS="$(printf '%s\n' "$RELEASE_TAGS" | version_collisions "$RELEASE_LABEL")"
if [ -n "$COLLISIONS" ]; then
  echo "Release tag $RELEASE_LABEL aliases an Android versionCode already owned by:" >&2
  printf '%s\n' "$COLLISIONS" >&2
  exit 1
fi

if [ "$GITHUB_EVENT_NAME" = "workflow_dispatch" ]; then
  if [ "$INPUT_RELEASE_CHANNEL" = "production" ] && [[ "$RELEASE_LABEL" == *-* ]]; then
    echo "Production releases must use a suffix-free tag" >&2
    exit 1
  fi
  if [ "$INPUT_RELEASE_CHANNEL" = "prerelease" ] && [[ "$RELEASE_LABEL" != *-* ]]; then
    echo "Prereleases must use a tag suffix so build slots 1-98 remain promotable" >&2
    exit 1
  fi
fi

# Production is promotion of a published prerelease for this exact source SHA, never an
# independent build path that bypasses the main-branch gate.
if [[ "$RELEASE_LABEL" != *-* && "$PUBLISH_EXTERNAL" = "true" ]]; then
  MATCHING_PRERELEASE=""
  while IFS= read -r prerelease_tag; do
    [[ "$prerelease_tag" == "$RELEASE_LABEL"-* ]] || continue
    prerelease_sha="$(git rev-list -n 1 "$prerelease_tag" 2>/dev/null || true)"
    if [ "$prerelease_sha" = "$BUILD_SHA" ]; then
      MATCHING_PRERELEASE="$prerelease_tag"
      break
    fi
  done < <(gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
    --jq '.[] | select(.prerelease == true and .draft == false) | .tag_name')
  test -n "$MATCHING_PRERELEASE" || {
    echo "Production $RELEASE_LABEL requires a published ${RELEASE_LABEL}-* prerelease for $BUILD_SHA" >&2
    exit 1
  }
fi

# Never build one commit and publish it under an existing tag for another commit.
if git rev-parse -q --verify "refs/tags/$RELEASE_LABEL" >/dev/null; then
  TAG_SHA="$(git rev-list -n 1 "$RELEASE_LABEL")"
  test "$TAG_SHA" = "$BUILD_SHA" || {
    echo "Tag $RELEASE_LABEL points to $TAG_SHA, not this build's $BUILD_SHA" >&2
    exit 1
  }
fi

RELEASE_ALREADY_PUBLISHED=false
RELEASE_JSON="$(capture_stdout_on_success gh api \
  "repos/${GITHUB_REPOSITORY}/releases/tags/${RELEASE_LABEL}" 2>/dev/null)"
if [ -n "$RELEASE_JSON" ] && ! git rev-parse -q --verify "refs/tags/$RELEASE_LABEL" >/dev/null; then
  RELEASE_TARGET="$(jq -r '.target_commitish' <<<"$RELEASE_JSON")"
  test "$RELEASE_TARGET" = "$BUILD_SHA" || {
    echo "Draft $RELEASE_LABEL targets $RELEASE_TARGET, not this build's $BUILD_SHA" >&2
    exit 1
  }
fi
if [ -n "$RELEASE_JSON" ] && [ "$(jq -r '.draft' <<<"$RELEASE_JSON")" = "false" ]; then
  RELEASE_ALREADY_PUBLISHED=true
fi

if [ -n "$INPUT_VERSION_CODE" ]; then
  [[ "$INPUT_VERSION_CODE" =~ ^[1-9][0-9]*$ ]] && [ "$INPUT_VERSION_CODE" -le 2100000000 ] || {
    echo "version_code must be an integer from 1 through 2100000000" >&2
    exit 1
  }
  VERSION_CODE_RESOLVED="$INPUT_VERSION_CODE"
else
  PRIOR_TAG="$(printf '%s\n' "$RELEASE_TAGS" | grep -Fxv "$RELEASE_LABEL" | \
    version_highest || true)"
  PRIOR_CODE="$(version_pack "$PRIOR_TAG" 2>/dev/null || echo 0)"
  if [ "$RELEASE_ALREADY_PUBLISHED" != "true" ] && \
    [ "$VERSION_CODE_RESOLVED" -le "$PRIOR_CODE" ]; then
    echo "versionCode $VERSION_CODE_RESOLVED ($RELEASE_LABEL) does not exceed the prior release $PRIOR_TAG (code $PRIOR_CODE)." >&2
    echo "Play requires strictly increasing codes; pick a higher version." >&2
    exit 1
  fi
fi

case "${INPUT_RELEASE_CHANNEL:-auto}" in
  production) RELEASE_PRERELEASE=false ;;
  prerelease) RELEASE_PRERELEASE=true ;;
  *)
    if [ "$GITHUB_EVENT_NAME" = "workflow_run" ] || [[ "$RELEASE_LABEL" == *-* ]]; then
      RELEASE_PRERELEASE=true
    else
      RELEASE_PRERELEASE=false
    fi
    ;;
esac

echo "Resolved $RELEASE_LABEL -> versionName=${RELEASE_LABEL#v}, versionCode=$VERSION_CODE_RESOLVED (latest release: $LAST_TAG)"
{
  echo "VERSION_CODE=$VERSION_CODE_RESOLVED"
  echo "VERSION_NAME=${RELEASE_LABEL#v}"
  echo "RELEASE_LABEL=$RELEASE_LABEL"
  echo "RELEASE_ALREADY_PUBLISHED=$RELEASE_ALREADY_PUBLISHED"
} >> "$GITHUB_ENV"
{
  echo "release_label=$RELEASE_LABEL"
  echo "release_already_published=$RELEASE_ALREADY_PUBLISHED"
  echo "release_prerelease=$RELEASE_PRERELEASE"
  echo "publish_external=$PUBLISH_EXTERNAL"
  # Compatibility names used by the Flutter build arguments.
  echo "tag=$RELEASE_LABEL"
  echo "name=${RELEASE_LABEL#v}"
  echo "code=$VERSION_CODE_RESOLVED"
} >> "$GITHUB_OUTPUT"
