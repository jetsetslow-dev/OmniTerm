#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:---verify}"
case "$MODE" in
  --write|--verify) ;;
  *)
    echo "Usage: $0 [--write|--verify]" >&2
    exit 2
    ;;
esac

JVM_ARGS="${OMNITERM_DEPENDENCY_JVMARGS:--Xmx4g -Dfile.encoding=UTF-8}"
COMMON_ARGS=(
  --no-daemon
  --no-configuration-cache
  --refresh-dependencies
  --max-workers=2
  "-Dorg.gradle.jvmargs=$JVM_ARGS"
)

resolve_project_graphs() {
  local -a metadata_args=("$@")
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/omniterm-project-graphs.XXXXXX.log")"
  echo "Resolving buildscript, app, test, lint, instrumentation, and benchmark graphs"
  if ! ./gradlew \
      buildEnvironment \
      :app:buildEnvironment \
      :benchmark:buildEnvironment \
      :app:dependencies \
      :benchmark:dependencies \
      "${COMMON_ARGS[@]}" \
      "${metadata_args[@]}" >"$log_file" 2>&1; then
    cat "$log_file" >&2
    rm -f -- "$log_file"
    return 1
  fi
  rm -f -- "$log_file"
}

resolve_release_sboms() {
  local -a metadata_args=("$@")
  local config log_file
  for config in playStoreReleaseRuntimeClasspath openSourceReleaseRuntimeClasspath; do
    echo "Resolving CycloneDX release graph: $config"
    log_file="$(mktemp "${TMPDIR:-/tmp}/omniterm-${config}.XXXXXX.log")"
    if ! SBOM_CONFIGURATION="$config" \
      ./gradlew cyclonedxBom \
        --init-script .github/cyclonedx.init.gradle.kts \
        "${COMMON_ARGS[@]}" \
        "${metadata_args[@]}" >"$log_file" 2>&1; then
      cat "$log_file" >&2
      rm -f -- "$log_file"
      return 1
    fi
    rm -f -- "$log_file"
  done
}

# Dependency *graphs* are not everything the build resolves. Plugins that run at execution time --
# KSP is the one that caught us -- pull artifacts into detached configurations that `dependencies`
# and `buildEnvironment` never report. `symbol-processing-aa-embeddable` was missing from the
# metadata for exactly this reason, and only CI found it, because only CI compiled.
#
# These are the tasks scripts/ci-gradle-gate.sh runs. Keep them in step: anything CI assembles has
# to be resolved here, or the metadata is verified against a smaller graph than the one that ships.
resolve_compile_graph() {
  local -a metadata_args=("$@")
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/omniterm-compile-graph.XXXXXX.log")"
  echo "Resolving the compile graph (assemble, as CI does)"
  if ! ./gradlew \
      :app:assembleOpenSourceDebug \
      :app:assemblePlayStoreDebug \
      "${COMMON_ARGS[@]}" \
      "${metadata_args[@]}" >"$log_file" 2>&1; then
    cat "$log_file" >&2
    rm -f -- "$log_file"
    return 1
  fi
  rm -f -- "$log_file"
}

if [[ "$MODE" == "--write" ]]; then
  resolve_project_graphs --write-verification-metadata sha256,sha512
  resolve_release_sboms --write-verification-metadata sha256,sha512
  resolve_compile_graph --write-verification-metadata sha256,sha512
fi

# A separate forced-refresh pass without write mode proves the resulting metadata works under
# strict verification. In --verify mode this is the only pass and never modifies the metadata.
resolve_project_graphs
resolve_release_sboms
resolve_compile_graph

echo "Gradle dependency verification passed for the project, release SBOM and compile graphs ($MODE)."
