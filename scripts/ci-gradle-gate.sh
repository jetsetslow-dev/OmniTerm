#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GRADLEW="${OMNITERM_GRADLEW:-$ROOT/gradlew}"

# CodeQL instrumentation and Compose/Kotlin compilation need more compiler headroom than the
# environment-neutral defaults in gradle.properties. Keep these limits CI-local: 4 GiB for Gradle
# and the Kotlin daemon still leaves ample space for CodeQL on a standard 16 GiB hosted runner.
COMMON_ARGS=(
  --no-daemon
  --no-build-cache
  --no-configuration-cache
  --max-workers=2
  "-Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8"
  -Pkotlin.daemon.jvmargs=-Xmx4g
  -Domniterm.publishScan=true
)

run_gradle() {
  "$GRADLEW" "$@" "${COMMON_ARGS[@]}"
}

# This compile invocation is deliberately identical on pull requests and main. CodeQL needs
# uncached compiler execution for both variants so its extractor observes all production sources.
run_gradle \
  :app:assembleOpenSourceDebug \
  :app:assemblePlayStoreDebug

# Pull requests run these tasks in the required PR Check workflow. Main repeats the exact gate for
# the merge SHA, but in a fresh Gradle process so compiler analysis and lint do not accumulate in
# the same constrained heap as both CodeQL-instrumented flavor assemblies.
if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
  run_gradle \
    :app:testOpenSourceDebugUnitTest \
    :app:testPlayStoreDebugUnitTest \
    :app:lintOpenSourceDebug \
    :app:lintPlayStoreDebug
fi
