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
GENERATED_THROWAWAY_KEYSTORE=false
cleanup() {
  # Only a throwaway generated key is removed. A keystore restored from the repo's committed
  # debug.keystore.base64 is kept so repeat runs — and the test device — keep the same signature.
  # (debug.keystore is gitignored, so keeping it never risks committing a credential.)
  if [[ "$CREATED_DEBUG_KEYSTORE" == "true" && "$GENERATED_THROWAWAY_KEYSTORE" == "true" ]]; then
    rm -f "$ROOT/debug.keystore"
  fi
}
trap cleanup EXIT

if [[ ! -f "$ROOT/debug.keystore" ]]; then
  umask 077
  if [[ -f "$ROOT/debug.keystore.base64" ]]; then
    # Prefer the repo's stable debug key. Generating a throwaway key instead gives every run a
    # DIFFERENT signature, so an APK already installed on a test device can no longer be updated
    # (INSTALL_FAILED_UPDATE_INCOMPATIBLE) and has to be uninstalled — losing its data — every time.
    #
    # This intentionally DIFFERS from android-pr-check.yml, which always generates an ephemeral key:
    # CI runs untrusted PR code and must not expose a stable signing key, and its verification APKs
    # never need signing continuity. Locally the opposite is true — the same trusted developer keeps
    # re-installing onto one test device, so continuity is the whole point.
    base64 -d "$ROOT/debug.keystore.base64" > "$ROOT/debug.keystore"
  else
    keytool -genkeypair -keystore "$ROOT/debug.keystore" -storepass android -keypass android \
      -alias androiddebugkey -dname CN=Android-Debug -keyalg RSA -keysize 2048 -validity 1 \
      >/dev/null 2>&1
    GENERATED_THROWAWAY_KEYSTORE=true
  fi
  CREATED_DEBUG_KEYSTORE=true
fi

echo "Preflight host: $OS_NAME/$ARCH_NAME"
git diff --check
./scripts/test-release-version.sh
./scripts/test-ci-gradle-gate.sh

GRADLE_ARGS=(
  --no-daemon
  --no-configuration-cache
  -Pomniterm.lowResourceBuild=false
)

if [[ "$LINUX_ARM64" == "true" ]]; then
  # Stay inside a Raspberry Pi-class host's memory budget. build.gradle.kts automatically excludes
  # only the Robolectric classes whose native runtime is unavailable on Linux ARM64.
  GRADLE_ARGS+=(--max-workers=2 "-Dorg.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8")
  echo "Robolectric native-runtime classes: unsupported on Linux ARM64; deferred to x86_64 CI"
else
  # Match the hosted PR/release test gate (scripts/ci-gradle-gate.sh): 4 workers and 4 GiB, the
  # shape of a public-repo standard runner (4 vCPU / 16 GiB). The 2 GiB default has previously made
  # coroutine-heavy Robolectric tests miss their wall-clock budgets under GC pressure.
  GRADLE_ARGS+=(--max-workers=4 "-Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8")
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
  # Run the WHOLE instrumentation package, not just `...data`. Filtering to the data layer meant no
  # UI instrumentation test ever ran here, so a screen could crash on first open with the preflight
  # still green -- exactly how an ICU-only regex defect in ComposeBuilder reached a release. The
  # lab-dependent `E2e*` suites self-skip through `assumeTrue` when their instrumentation arguments
  # are absent, so this stays runnable on a bare emulator; see AGENTS.md for running them for real.
  ./gradlew connectedOpenSourceDebugAndroidTest "${GRADLE_ARGS[@]}"
else
  echo "Device matrix (Room migrations + UI instrumentation): no Android device/emulator available; deferred to PR CI"
fi

echo "Local PR preflight passed ($MODE)."
