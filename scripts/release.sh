#!/usr/bin/env bash
# One-command release: derive the version from the commit count exactly the way
# .github/workflows/android-release.yml does, then push main and the matching tag
# so the release workflow fires. No hand-picked tag numbers, no "tag already exists".
#
#   versionName = MAJOR.MINOR.(FLOOR + git commit count)   -> tag = v<versionName>
#
# These three must stay in lockstep with the workflow's resolve-version step.
set -euo pipefail

MAJOR="${VERSION_MAJOR:-0}"
MINOR="${VERSION_MINOR:-9}"
FLOOR="${VERSION_CODE_FLOOR:-140}"

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
TAG="v${MAJOR}.${MINOR}.${CODE}"

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "release: tag ${TAG} already exists for this commit count." >&2
  echo "         Add a commit (the count, and thus the version, advances by one) and re-run." >&2
  exit 1
fi

echo "release: versionName ${MAJOR}.${MINOR}.${CODE} (${FLOOR} + ${COMMIT_COUNT} commits) -> tag ${TAG}"

# Make sure the tag's commit is actually on the remote before tagging it.
git push origin main

git tag "${TAG}"
git push origin "${TAG}"

echo "release: pushed ${TAG}. The android-release workflow is now building."
echo "         Watch it: gh run watch \$(gh run list --workflow=android-release.yml -L1 --json databaseId -q '.[0].databaseId')"
