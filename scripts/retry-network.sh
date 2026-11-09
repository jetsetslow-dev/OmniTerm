#!/usr/bin/env bash
# Runs a command, and runs it again (twice at most) when it failed and its output shows a network
# failure: a module proxy or checksum server dropping one connection should not fail a build whose
# code is fine. Any other failure ends at once, with the command's own status and output.
#   scripts/retry-network.sh <command> [args...]
# The command's stderr is folded into its stdout. RETRY_NETWORK_SLEEP sets the seconds before the
# first retry (doubled before the second); 15 by default.
#
# Why: gomobile's own `go mod tidy` checks the tunnel's whole module graph with sum.golang.org on
# every clean build, and one HTTP/2 stream reset there failed main's release of #147 (2026-11-09).
set -uo pipefail

PATTERN='stream error: stream ID [0-9]+; (INTERNAL_ERROR|PROTOCOL_ERROR)|[Cc]onnection reset by peer|i/o timeout|TLS handshake timeout|[Tt]emporary failure in name resolution|dial tcp: lookup|50[234] (Bad Gateway|Service Unavailable|Gateway Time-?out)'
pause="${RETRY_NETWORK_SLEEP:-15}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for attempt in 1 2 3; do
  "$@" 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  [[ $status -eq 0 ]] && exit 0
  if [[ $attempt -lt 3 ]] && grep -qE "$PATTERN" "$log"; then
    echo "retry-network: a network failure; trying again in ${pause}s ($attempt of 2)" >&2
    sleep "$pause"
    pause=$((pause * 2))
    continue
  fi
  exit "$status"
done
