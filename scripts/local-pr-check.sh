#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="${1:---full}"
case "$MODE" in
  --quick|--full) ;;
  *)
    echo "Usage: $0 [--quick|--full]" >&2
    exit 2
    ;;
esac

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"
LINUX_ARM64=false
if [[ "$OS_NAME" == "Linux" && ( "$ARCH_NAME" == "aarch64" || "$ARCH_NAME" == "arm64" ) ]]; then
  LINUX_ARM64=true
fi

CREATED_DEBUG_KEYSTORE=false
cleanup() {
  if [[ "$CREATED_DEBUG_KEYSTORE" == "true" ]]; then
    rm -f "$ROOT/debug.keystore"
  fi
}
trap cleanup EXIT

if [[ ! -f "$ROOT/debug.keystore" ]]; then
  umask 077
  keytool -genkeypair -keystore "$ROOT/debug.keystore" -storepass android -keypass android \
    -alias androiddebugkey -dname CN=Android-Debug -keyalg RSA -keysize 2048 -validity 1 \
    >/dev/null 2>&1
  CREATED_DEBUG_KEYSTORE=true
fi

echo "Preflight host: $OS_NAME/$ARCH_NAME"
git diff --check
./scripts/test-release-version.sh
./scripts/test-ci-gradle-gate.sh

GRADLE_ARGS=(
  --no-daemon
  --no-configuration-cache
  --max-workers=2
  -Pomniterm.lowResourceBuild=false
)

if [[ "$LINUX_ARM64" == "true" ]]; then
  # Stay inside a Raspberry Pi-class host's memory budget. build.gradle.kts automatically excludes
  # only the Robolectric classes whose native runtime is unavailable on Linux ARM64.
  GRADLE_ARGS+=("-Dorg.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8")
  echo "Robolectric native-runtime classes: unsupported on Linux ARM64; deferred to x86_64 CI"
else
  # Match the hosted PR/release test gate. The 2 GiB default has previously made coroutine-heavy
  # Robolectric tests miss their wall-clock budgets under GC pressure.
  GRADLE_ARGS+=("-Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8")
fi

./gradlew \
  testOpenSourceDebugUnitTest testPlayStoreDebugUnitTest \
  lintOpenSourceDebug lintPlayStoreDebug \
  "${GRADLE_ARGS[@]}"

if [[ "$MODE" == "--full" ]]; then
  if [[ "$LINUX_ARM64" == "true" ]]; then
    OMNITERM_DEPENDENCY_JVMARGS="-Xmx2g -Dfile.encoding=UTF-8" \
      ./scripts/refresh-verification-metadata.sh --verify
  else
    ./scripts/refresh-verification-metadata.sh --verify
  fi
fi

if command -v adb >/dev/null 2>&1 &&
  adb devices | awk 'NR > 1 && $2 == "device" { found=1 } END { exit !found }'; then
  ./gradlew connectedOpenSourceDebugAndroidTest \
    -Pandroid.testInstrumentationRunnerArguments.package=com.jetsetslow.omniterm.data \
    "${GRADLE_ARGS[@]}"
else
  echo "Room migration device matrix: no Android device/emulator available; deferred to PR CI"
fi

echo "Local PR preflight passed ($MODE)."
