#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER_ROOT="$ROOT/flutter_app"
OUTPUT_DIR="${1:?usage: $0 OUTPUT_DIR RELEASE_LABEL}"
RELEASE_LABEL="${2:?usage: $0 OUTPUT_DIR RELEASE_LABEL}"
NATIVE_SBOM="$OUTPUT_DIR/OmniTerm-Flutter-Android-${RELEASE_LABEL}.cdx.json"
DART_SBOM="$OUTPUT_DIR/OmniTerm-Flutter-Dart-${RELEASE_LABEL}.cdx.json"
PUB_DEPS="$(mktemp)"
GIT_LOCK_ROWS="$(mktemp)"

cleanup() {
  rm -f "$PUB_DEPS" "$GIT_LOCK_ROWS"
}
trap cleanup EXIT

command -v dart >/dev/null || { echo "dart is required to generate the Flutter SBOM" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required to generate the Flutter SBOM" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"

# Pub's JSON graph distinguishes the root's runtime dependencies from devDependencies. Walk only
# the runtime closure so test/analyzer/build packages are not attributed to the shipped binary.
(cd "$FLUTTER_ROOT" && dart pub deps --json) > "$PUB_DEPS"
# `dart pub deps --json` reports only `source: git`; the immutable URL and resolved commit live in
# pubspec.lock. Preserve them in the SBOM so a reviewed fork is traceable to the exact source that
# produced the binary rather than looking like an unidentified package named "dartssh2".
awk '
  /^  [A-Za-z0-9_]+:$/ {
    name=$1; sub(/:$/, "", name); url=""; resolved=""; source=""; next
  }
  /^      url: / { url=$0; sub(/^      url: /, "", url); gsub(/^"|"$/, "", url); next }
  /^      resolved-ref: / {
    resolved=$0; sub(/^      resolved-ref: /, "", resolved); gsub(/^"|"$/, "", resolved); next
  }
  /^    source: / {
    source=$0; sub(/^    source: /, "", source)
    if (source == "git") print name "\t" url "\t" resolved
  }
' "$FLUTTER_ROOT/pubspec.lock" > "$GIT_LOCK_ROWS"
GIT_LOCKS="$(jq -Rn '
  [inputs | split("\t") | select(length == 3) |
    {key: .[0], value: {url: .[1], resolvedRef: .[2]}}] | from_entries
' "$GIT_LOCK_ROWS")"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SERIAL_NUMBER="urn:uuid:$(cat /proc/sys/kernel/random/uuid)"
DART_VERSION="$(dart --version 2>&1 | sed -E 's/^Dart SDK version: ([^ ]+).*/\1/')"
jq \
  --arg release_version "${RELEASE_LABEL#v}" \
  --arg timestamp "$TIMESTAMP" \
  --arg serial_number "$SERIAL_NUMBER" \
  --arg dart_version "$DART_VERSION" \
  --argjson git_locks "$GIT_LOCKS" \
  -f "$ROOT/scripts/flutter-pub-cyclonedx.jq" \
  "$PUB_DEPS" > "$DART_SBOM"

# The Android half comes from the exact Gradle runtime configuration embedded in the AAB. The
# direct task avoids aggregating build/test configurations from every Flutter plugin project.
(
  cd "$FLUTTER_ROOT/android"
  SBOM_CONFIGURATION=releaseRuntimeClasspath \
    SBOM_COMPONENT_NAME="OmniTerm Flutter Play Store" \
    RELEASE_LABEL="$RELEASE_LABEL" \
    ./gradlew :app:cyclonedxDirectBom \
      --init-script "$ROOT/.github/cyclonedx.init.gradle.kts" \
      --no-daemon
)
cp "$FLUTTER_ROOT/build/app/reports/cyclonedx-direct/bom.json" "$NATIVE_SBOM"

# Fail closed on empty or dev-contaminated dependency inventories. These checks also make output
# path changes in either upstream tool visible before a release is staged.
jq -e '
  .bomFormat == "CycloneDX" and
  .metadata.component.name == "OmniTerm Flutter" and
  ((.components // []) | length >= 50) and
  ([.components[] | select(.properties[]? | .name == "omniterm:dart:source" and .value == "git") |
    (.purl | contains("vcs_url="))] | all) and
  ([.components[].name] | any(. == "patrol" or . == "mocktail" or . == "flutter_test") | not)
' "$DART_SBOM" >/dev/null
jq -e '
  .bomFormat == "CycloneDX" and
  .metadata.component.name == "OmniTerm Flutter Play Store" and
  ((.components // []) | length >= 20)
' "$NATIVE_SBOM" >/dev/null

echo "Generated Flutter runtime SBOMs:"
echo "  $DART_SBOM"
echo "  $NATIVE_SBOM"
