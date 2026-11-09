#!/usr/bin/env bash
# Checks the Go tunnel library (tunnel/) with the repository's pinned Go toolchain: formatting, go
# vet, and its tests, which run real WireGuard handshakes over loopback against an in-process peer.
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
go vet ./...
go test -count=1 ./...
echo "test-tunnel: Go tunnel library checks passed"
