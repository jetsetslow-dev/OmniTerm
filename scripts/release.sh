#!/usr/bin/env bash
# One-command release: derive the version from the commit count exactly the way
# .github/workflows/android-release.yml does, then push main and the matching tag
# so the release workflow fires. No hand-picked tag numbers, no "tag already exists".
#
#   versionName = MAJOR.MINOR.(FLOOR + git commit count)   -> tag = v<versionName>
#
# These three must stay in lockstep with the workflow's resolve-version step.
#
# Channels — the workflow decides prerelease vs production from the TAG NAME (see
# android-release.yml: "a SemVer pre-release suffix … means prerelease"):
#
#   ./scripts/release.sh                 -> tag v0.9.156          (production release)
#   ./scripts/release.sh --prerelease    -> tag v0.9.156-Alpha    (GitHub PRE-release)
#   ./scripts/release.sh --prerelease rc1 -> tag v0.9.156-rc1     (custom suffix)
#
# The suffix is cosmetic to Android: the workflow builds versionName from
# MAJOR.MINOR.CODE and never parses the suffix, so versionName stays a clean
# "0.9.156" either way. The suffix only names the GitHub Release and flags it
# prerelease. A suffix must be a valid SemVer pre-release identifier
# ([0-9A-Za-z-] plus dots) so the resulting tag is well-formed.
set -euo pipefail

MAJOR="${VERSION_MAJOR:-0}"
MINOR="${VERSION_MINOR:-9}"
FLOOR="${VERSION_CODE_FLOOR:-140}"

# ── Parse args: optional --prerelease [LABEL] (default LABEL=Alpha) ──
PRERELEASE=0
PRERELEASE_LABEL="Alpha"
while [ $# -gt 0 ]; do
  case "$1" in
    --prerelease|--pre|-p)
      PRERELEASE=1
      # An optional next arg that isn't another flag is the suffix label.
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then
        PRERELEASE_LABEL="$2"
        shift
      fi
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "release: unknown argument '$1'. Use --prerelease [LABEL] or --help." >&2
      exit 1
      ;;
  esac
  shift
done

# A SemVer pre-release identifier is a dot-separated series of [0-9A-Za-z-] parts.
if [ "$PRERELEASE" = "1" ] && ! printf '%s' "$PRERELEASE_LABEL" | grep -Eq '^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$'; then
  echo "release: invalid prerelease label '$PRERELEASE_LABEL' (allowed: letters, digits, '-', '.')." >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

# Always sync tags first so the collision check below sees CI-created tags too.
git fetch origin --tags --prune --prune-tags --quiet

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" != "main" ]; then
  echo "release: on '$BRANCH', not 'main'. Releases tag main. Aborting." >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "release: working tree is dirty. Commit or stash first." >&2
  git status --short >&2
  exit 1
fi

COMMIT_COUNT="$(git rev-list --count HEAD)"
CODE="$((FLOOR + COMMIT_COUNT))"
BASE_TAG="v${MAJOR}.${MINOR}.${CODE}"

if [ "$PRERELEASE" = "1" ]; then
  # Prereleases at the same commit count are legitimately re-cut (e.g. after a failed CI run),
  # so instead of hard-failing on a collision we auto-bump a numeric ".N" so each push is a fresh
  # tag: v0.9.156-Alpha, then -Alpha.2, -Alpha.3, … This keeps the version reproducible while not
  # forcing a throwaway commit just to retry a prerelease.
  TAG="${BASE_TAG}-${PRERELEASE_LABEL}"
  n=2
  while git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; do
    TAG="${BASE_TAG}-${PRERELEASE_LABEL}.${n}"
    n=$((n + 1))
  done
else
  # Production: the plain tag is pinned to the commit count, so a collision means "nothing new to
  # release". Bumping silently would ship a second production build of the same code — refuse instead.
  TAG="$BASE_TAG"
  if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "release: tag ${TAG} already exists for this commit count." >&2
    echo "         Add a commit (the count, and thus the version, advances by one) and re-run." >&2
    exit 1
  fi
fi

if [ "$PRERELEASE" = "1" ]; then
  echo "release: PRERELEASE versionName ${MAJOR}.${MINOR}.${CODE} (${FLOOR} + ${COMMIT_COUNT} commits) -> tag ${TAG}"
else
  echo "release: versionName ${MAJOR}.${MINOR}.${CODE} (${FLOOR} + ${COMMIT_COUNT} commits) -> tag ${TAG}"
fi

# Make sure the tag's commit is actually on the remote before tagging it.
git push origin main

git tag "${TAG}"
git push origin "${TAG}"

echo "release: pushed ${TAG}. The android-release workflow is now building."
echo "         Watch it: gh run watch \$(gh run list --workflow=android-release.yml -L1 --json databaseId -q '.[0].databaseId')"
