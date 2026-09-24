#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTOR="$ROOT/.github/release-engine"
KOTLIN_WORKFLOW="$ROOT/.github/workflows/android-release.yml"
FLUTTER_WORKFLOW="$ROOT/.github/workflows/flutter-release.yml"
RESOLVER="$ROOT/scripts/resolve-release-version.sh"
SBOM_GENERATOR="$ROOT/scripts/generate-flutter-sboms.sh"

fail() {
  echo "release-engine test: $*" >&2
  exit 1
}

[ -f "$SELECTOR" ] || fail "missing .github/release-engine"
[ -x "$RESOLVER" ] || fail "shared release resolver is missing or not executable"
[ -x "$SBOM_GENERATOR" ] || fail "Flutter SBOM generator is missing or not executable"
ENGINE="$(tr -d '[:space:]' < "$SELECTOR")"
case "$ENGINE" in kotlin|flutter) ;; *) fail "selector must be kotlin or flutter, got '$ENGINE'" ;; esac

for workflow in "$KOTLIN_WORKFLOW" "$FLUTTER_WORKFLOW"; do
  grep -q '^  release-engine:$' "$workflow" || fail "$(basename "$workflow") has no selector job"
  grep -q '^    needs: release-engine$' "$workflow" || fail "$(basename "$workflow") release does not depend on selector"
  [[ "$(grep -c 'run: ./scripts/resolve-release-version.sh' "$workflow")" == "1" ]] ||
    fail "$(basename "$workflow") must invoke the shared resolver exactly once"
  ! grep -q 'source scripts/release-version.sh' "$workflow" ||
    fail "$(basename "$workflow") reimplements release allocation inline"
done

grep -q "needs.release-engine.outputs.selected == 'kotlin'" "$KOTLIN_WORKFLOW" ||
  fail "Kotlin publisher is not gated on the Kotlin selector"
grep -q "needs.release-engine.outputs.selected == 'flutter'" "$FLUTTER_WORKFLOW" ||
  fail "Flutter publisher is not gated on the Flutter selector"
grep -q '^  workflow_run:$' "$FLUTTER_WORKFLOW" ||
  fail "Flutter publisher does not inherit the successful-main aggregate trigger"
grep -q "github.event.workflow_run.head_branch == 'main'" "$FLUTTER_WORKFLOW" ||
  fail "Flutter automatic publication is not restricted to main"

bash -n "$RESOLVER" "$SBOM_GENERATOR" "$ROOT/scripts/test-release-resolution.sh"
"$ROOT/scripts/test-release-resolution.sh"

echo "release-engine test: $ENGINE is the sole publisher"
