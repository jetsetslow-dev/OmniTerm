#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---verify}"
case "$MODE" in
  --write|--verify) ;;
  *) echo "Usage: $0 [--write|--verify]" >&2; exit 2 ;;
esac
python3 "$ROOT/scripts/verify-flutter-android-toolchain.py"
cd "$ROOT/flutter_app/android"
[[ -f local.properties ]] || { echo "Run flutter pub get before Android dependency validation." >&2; exit 1; }
if [[ "$MODE" == "--verify" && ! -f gradle/verification-metadata.xml ]]; then
  echo "Missing strict Flutter Android verification metadata; write and inspect it first." >&2
  exit 1
fi

# Verification builds never consume the production signing key. Run this gate before creating
# final release artifacts, since its normal-main verification APKs are disposable.
unset KEYSTORE_PATH STORE_PASSWORD KEY_ALIAS KEY_PASSWORD
export ADMOB_APP_ID=ca-app-pub-3940256099942544~3347511713
COMMON_ARGS=(--no-daemon --no-configuration-cache --refresh-dependencies --max-workers=2
  "-Dorg.gradle.jvmargs=${OMNITERM_DEPENDENCY_JVMARGS:--Xmx4g -Dfile.encoding=UTF-8}")

prepare_mode() {
  # Flutter's generated Java registrant is shared by build modes. Its supported config-only
  # command excludes dev plugins for release, without starting an unverified Gradle build.
  # Keep pub enabled: Flutter also skips registrant regeneration when --no-pub is supplied.
  (cd "$ROOT/flutter_app" && "${FLUTTER_BIN:-flutter}" build apk "--$1" \
    --config-only --target=lib/main.dart)
}

resolve_graphs() {
  # Keep each mode's assembly and lint in the same invocation. Combining both modes would leave
  # release compilation reading the debug registrant's dev-only plugin imports.
  # This build provides debug unit-test compilation; no release unit-test task is defined.
  prepare_mode debug
  echo "Resolving Flutter Android plugin/project, debug assembly, instrumentation, debug unit-test compilation and lint graphs"
  ./gradlew buildEnvironment :app:buildEnvironment :app:dependencies \
    :app:assembleDebug :app:assembleDebugAndroidTest :app:compileDebugUnitTestKotlin \
    :app:lintDebug "${COMMON_ARGS[@]}" "$@"
  prepare_mode release
  echo "Resolving Flutter Android release assembly, lint and actual runtime SBOM graphs"
  SBOM_CONFIGURATION=releaseRuntimeClasspath SBOM_COMPONENT_NAME="OmniTerm Flutter Play Store" \
    ./gradlew :app:assembleRelease :app:lintRelease :app:cyclonedxDirectBom \
      --init-script "$ROOT/.github/cyclonedx.init.gradle.kts" \
      "${COMMON_ARGS[@]}" "$@"
  python3 "$ROOT/scripts/verify-native-sbom-baselines.py" \
    ../build/app/reports/cyclonedx-direct/bom.json --configuration releaseRuntimeClasspath
}

if [[ "$MODE" == "--write" ]]; then
  resolve_graphs --write-verification-metadata sha256,sha512
fi
resolve_graphs
echo "Strict Flutter Android dependency verification passed for project, assembly, debug unit/instrumentation compilation, lint and runtime SBOM graphs ($MODE)."
