#!/usr/bin/env bash
# Checks scripts/retry-network.sh: a network failure is tried again, any other failure is not, and
# a third network failure gives up with the command's own status.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RETRY="$ROOT/scripts/retry-network.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export RETRY_NETWORK_SLEEP=0

# A command that prints $2 and exits 7 for its first $1 calls, then succeeds.
fake() {
  rm -f "$work/count"
  cat > "$work/fake" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$work/count" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$work/count"
if [ "\$n" -le $1 ]; then echo "$2" >&2; exit 7; fi
echo done
EOF
  chmod +x "$work/fake"
}

failed=0
expect() {
  local name="$1" want="$2" status=0
  "$RETRY" "$work/fake" > "$work/out" 2>&1 || status=$?
  local got="$status:$(cat "$work/count")"
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected status:calls $want, got $got" >&2
    sed 's/^/     /' "$work/out" >&2
    failed=1
  fi
}

fake 0 ''
expect "a command that works runs once" "0:1"

# The line main's release failed on.
fake 1 'go: verifying go.mod: reading https://sum.golang.org/tile/8/0/x014/284: stream error: stream ID 1477; INTERNAL_ERROR; received from peer'
expect "a dropped checksum-server stream is tried again" "0:2"

fake 2 'dial tcp: lookup proxy.golang.org on 127.0.0.53:53: server misbehaving'
expect "two network failures in a row are tried again" "0:3"

fake 3 'read tcp 10.1.0.4:443: connection reset by peer'
expect "a third network failure gives up with the command's status" "7:3"

fake 1 'omnitunnel/tunnel.go:12:2: undefined: wgConfig'
expect "a compile error is not tried again" "7:1"

fake 1 'syntax error: unexpected EOF'
expect "a truncated source file is not mistaken for the network" "7:1"

exit "$failed"
