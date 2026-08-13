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
./scripts/test-secret-scan-coverage.sh

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

# The secret gate, run the way CI runs it. Two properties of that job are easy to get wrong locally
# and both cost this repository real time:
#
#   1. It scans ALL refs, not the current branch. `actions/checkout` with fetch-depth 0 fetches every
#      ref, so a finding on any branch fails the scan on all of them. A plain `gitleaks git` walks
#      HEAD's ancestry only, which can report clean while CI reports six.
#   2. It scans history, so removing a secret from the working tree never clears a past commit.
#      Fix the cause first, then baseline the fingerprint in .gitleaksignore.
run_secret_scan() {
  local -a cmd
  if command -v gitleaks >/dev/null 2>&1; then
    cmd=(gitleaks)
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    cmd=(docker run --rm -v "$PWD:/repo" -w /repo zricethezav/gitleaks:latest)
  else
    echo "WARNING: neither gitleaks nor a working docker found — the secret gate was NOT run." >&2
    echo "         CI will still run it over every ref. Install gitleaks to catch this locally." >&2
    return 0
  fi
  echo "Scanning every ref for committed secrets"
  "${cmd[@]}" git --log-opts="--all" --redact --no-banner --no-color .
}

run_secret_scan

# The Flutter app is the branch under migration, and until now this script did not look at it at
# all: `grep -c flutter` was zero, so "the required gate passed" meant only that the Kotlin app
# passed. These are the same three commands `.github/workflows/flutter-pr-check.yml` runs, in the
# same order, so a green local run and a green PR mean the same thing.
#
# The line length is not optional: `dart format` defaults to 80, `flutter analyze` says nothing
# about it, and a tree formatted at the default fails CI with every touched file marked changed.
run_flutter_checks() {
  if [[ ! -d "$PWD/flutter_app" ]]; then
    echo "No flutter_app directory; skipping the Flutter gate."
    return
  fi
  if ! command -v flutter >/dev/null 2>&1; then
    echo "WARNING: flutter is not on PATH — the Flutter gate was NOT run." >&2
    echo "         Put it on PATH or set FLUTTER_BIN, then re-run." >&2
    return 1
  fi
  (
    cd flutter_app
    echo "Resolving Flutter dependencies"
    flutter pub get
    echo "Checking Flutter formatting (line length 100)"
    dart format --output=none --set-exit-if-changed --line-length 100 .
    echo "Analyzing the Flutter app"
    flutter analyze --fatal-infos
    echo "Running the Flutter test suite"
    flutter test
  )
}

# `flutter` may be installed only as FLUTTER_BIN; put its directory on PATH so `dart` resolves too.
if [[ -n "${FLUTTER_BIN:-}" && -x "${FLUTTER_BIN}" ]]; then
  PATH="$(dirname "$FLUTTER_BIN"):$PATH"
  export PATH
fi

run_flutter_checks

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
  # are absent, so this stays runnable on a bare emulator; the host profile exercises them for real.
  ./gradlew connectedOpenSourceDebugAndroidTest "${GRADLE_ARGS[@]}"
else
  echo "Device matrix (Room migrations + UI instrumentation): no Android device/emulator available; deferred to PR CI"
fi

echo "Local PR preflight passed ($MODE)."
