#!/usr/bin/env bash
# Checks the Go tunnel library (tunnel/) with the repository's pinned Go toolchain: formatting, a
# build with the tags that ship (tunnel/build-tags.txt) for this machine and for Android, go vet,
# and its tests, which run real WireGuard handshakes over loopback against an in-process peer, and
# real Tailscale sign-ins against tailscale.com's in-process test control server, relay and peer.
# The local gate and PR Check both run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$("$ROOT/scripts/go-toolchain.sh")"
cd "$ROOT/tunnel"
unformatted="$(gofmt -l .)"
if [[ -n "$unformatted" ]]; then
  echo "test-tunnel: not gofmt-formatted (run gofmt -w on them):" >&2
  echo "$unformatted" >&2
  exit 1
fi
go mod verify
go build ./...
GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build ./...
# The test control server (tailscale.com/tstest/integration/testcontrol) needs tailnet-lock code
# to compile, and the tests' subnet router has to offer its routes; the app does neither, so only
# the tests are built with them.
tags="$(grep -v '^#' build-tags.txt | tr -d '[:space:]')"
test_tags="$(tr ',' '\n' <<<"$tags" | grep -vx -e ts_omit_tailnetlock -e ts_omit_advertiseroutes | paste -sd, -)"
GOFLAGS="-mod=readonly -tags=$test_tags" go vet ./...
GOFLAGS="-mod=readonly -tags=$test_tags" go test -count=1 ./...
echo "test-tunnel: Go tunnel library checks passed"
