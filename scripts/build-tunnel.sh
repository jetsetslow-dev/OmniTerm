#!/usr/bin/env bash
# Builds the Go tunnel library (tunnel/) into an Android library for the app, with the repository's
# pinned Go toolchain (scripts/go-toolchain.sh), gomobile at the version tunnel/go.mod pins, and the
# NDK below. Gradle runs this when tunnel/ changes; it can also be run by hand:
#   ./scripts/build-tunnel.sh [output.aar]
# OMNITUNNEL_TARGETS narrows the ABIs for a quicker local build (for example android/amd64).
#
#   ./scripts/build-tunnel.sh --access-fixture [output.aar]
# builds the Cloudflare Access device suite's test library instead (Go tag omniterm_access_fixture,
# scripts/test-hosts/fixtures/cloudflare-access), by default to
# tunnel/build/fixture/omnitunnel-access-fixture.aar, never to the app's own library. A test APK
# uses it through -Pomniterm.tunnelAar=<file>. Every build is checked with check-tunnel-seam.py:
# the fixture library must hold its seam, and every other build must not.
set -euo pipefail

NDK_VERSION=28.2.13676358
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTION="$ROOT/tunnel/build/omnitunnel.aar"
FIXTURE=""
if [[ "${1:-}" == "--access-fixture" ]]; then
  FIXTURE=1
  shift
  OUT="${1:-$ROOT/tunnel/build/fixture/omnitunnel-access-fixture.aar}"
  mkdir -p "$(dirname "$OUT")"
  if [[ "$(realpath -m "$OUT")" == "$(realpath -m "$PRODUCTION")" ]]; then
    echo "build-tunnel: the Access fixture library never goes to $PRODUCTION, which every app build uses" >&2
    exit 1
  fi
else
  OUT="${1:-$PRODUCTION}"
fi
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
# Each step that downloads or checks modules is tried again on a network failure only
# (scripts/retry-network.sh): gomobile's own `go mod tidy` asks sum.golang.org about the whole
# module graph on every clean build. The versions come from go.mod and go.sum, so these are the
# same binaries everywhere.
RETRY="$ROOT/scripts/retry-network.sh"
"$RETRY" go build -trimpath -o "$GOPATH/bin/gomobile" golang.org/x/mobile/cmd/gomobile
"$RETRY" go build -trimpath -o "$GOPATH/bin/gobind" golang.org/x/mobile/cmd/gobind

tmp="$OUT.tmp.aar"
rm -f "$tmp" "${tmp%.aar}-sources.jar"
# The tags that ship (tunnel/build-tags.txt): gomobile is given them itself too, not only in GOFLAGS.
TAGS="$(grep -v '^#' "$ROOT/tunnel/build-tags.txt" | tr -d '[:space:]')"
if [[ -n "$FIXTURE" ]]; then TAGS="$TAGS,omniterm_access_fixture"; fi
"$RETRY" gomobile bind \
  -target="$TARGETS" \
  -tags="$TAGS" \
  -androidapi 24 \
  -javapkg com.jetsetslow.omniterm.gotunnel \
  -trimpath \
  -ldflags="-s -w -buildid=" \
  -o "$tmp" \
  ./omnitunnel
# Checked before it takes the output's place: a library with the wrong seam is never left there.
if [[ -n "$FIXTURE" ]]; then
  python3 -I -B "$ROOT/scripts/check-tunnel-seam.py" --expect-fixture "$tmp"
else
  python3 -I -B "$ROOT/scripts/check-tunnel-seam.py" "$tmp"
fi
mv "$tmp" "$OUT"
rm -f "${tmp%.aar}-sources.jar"
echo "build-tunnel: wrote $OUT ($TARGETS${FIXTURE:+, Cloudflare Access fixture})"
