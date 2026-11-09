#!/usr/bin/env bash
# Builds the Go tunnel library (tunnel/) into an Android library for the app, with the repository's
# pinned Go toolchain (scripts/go-toolchain.sh), gomobile at the version tunnel/go.mod pins, and the
# NDK below. Gradle runs this when tunnel/ changes; it can also be run by hand:
#   ./scripts/build-tunnel.sh [output.aar]
# OMNITUNNEL_TARGETS narrows the ABIs for a quicker local build (for example android/amd64).
set -euo pipefail

NDK_VERSION=28.2.13676358
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/tunnel/build/omnitunnel.aar}"
TARGETS="${OMNITUNNEL_TARGETS:-android/arm64,android/arm,android/amd64,android/386}"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK" && -f "$ROOT/local.properties" ]]; then
  SDK="$(sed -n 's/^sdk\.dir=//p' "$ROOT/local.properties" | tail -1)"
fi
if [[ -z "$SDK" || ! -d "$SDK" ]]; then
  echo "build-tunnel: set ANDROID_HOME (or sdk.dir in local.properties) to the Android SDK" >&2
  exit 1
fi
export ANDROID_HOME="$SDK"
export ANDROID_NDK_HOME="$SDK/ndk/$NDK_VERSION"
if [[ ! -d "$ANDROID_NDK_HOME" && -n "${CI:-}" && -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]]; then
  # CI runners start without an NDK; a developer's machine is never changed behind their back.
  "$SDK/cmdline-tools/latest/bin/sdkmanager" --install "ndk;$NDK_VERSION" >/dev/null
fi
if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "build-tunnel: NDK $NDK_VERSION is missing; install it with" >&2
  echo "  sdkmanager --install \"ndk;$NDK_VERSION\"" >&2
  exit 1
fi

eval "$("$ROOT/scripts/go-toolchain.sh")"
cd "$ROOT/tunnel"
mkdir -p "$GOPATH/bin" "$(dirname "$OUT")"
# The versions come from go.mod and go.sum, so these are the same binaries everywhere.
go build -trimpath -o "$GOPATH/bin/gomobile" golang.org/x/mobile/cmd/gomobile
go build -trimpath -o "$GOPATH/bin/gobind" golang.org/x/mobile/cmd/gobind

tmp="$OUT.tmp.aar"
rm -f "$tmp" "${tmp%.aar}-sources.jar"
gomobile bind \
  -target="$TARGETS" \
  -androidapi 24 \
  -javapkg com.jetsetslow.omniterm.gotunnel \
  -trimpath \
  -ldflags="-s -w -buildid=" \
  -o "$tmp" \
  ./omnitunnel
mv "$tmp" "$OUT"
rm -f "${tmp%.aar}-sources.jar"
echo "build-tunnel: wrote $OUT ($TARGETS)"
