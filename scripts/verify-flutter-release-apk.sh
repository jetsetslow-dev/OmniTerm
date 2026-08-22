#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK_PATH="${1:?usage: $0 APK_PATH}"
[[ -f "$APK_PATH" ]] || { echo "Release APK not found: $APK_PATH" >&2; exit 1; }

APK_ANALYZER="$(command -v apkanalyzer || true)"
if [[ -z "$APK_ANALYZER" ]]; then
  SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -z "$SDK_ROOT" && -d "$ROOT/.android-sdk" ]]; then
    SDK_ROOT="$ROOT/.android-sdk"
  fi
  [[ -n "$SDK_ROOT" ]] || {
    echo "apkanalyzer is not on PATH and no Android SDK root is configured" >&2
    exit 1
  }
  APK_ANALYZER="$SDK_ROOT/cmdline-tools/latest/bin/apkanalyzer"
fi
[[ -x "$APK_ANALYZER" ]] || {
  echo "apkanalyzer is unavailable at $APK_ANALYZER" >&2
  exit 1
}

PACKAGES="$(mktemp)"
cleanup() {
  rm -f "$PACKAGES"
}
trap cleanup EXIT

"$APK_ANALYZER" dex packages "$APK_PATH" > "$PACKAGES"
if grep -Eiq 'patrol|integration_test|flutter_test|test_api|mocktail' "$PACKAGES"; then
  echo "A development-only test package was compiled into the release APK:" >&2
  grep -Ei 'patrol|integration_test|flutter_test|test_api|mocktail' "$PACKAGES" >&2
  exit 1
fi

echo "Flutter release APK contains no development-only test packages."
