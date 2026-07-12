#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command> [args...]" >&2
  exit 64
fi

delay_seconds="${RETRY_DELAY_SECONDS:-3600}"
max_attempts="${RETRY_MAX_ATTEMPTS:-0}"
[[ "$delay_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "retry-hourly: RETRY_DELAY_SECONDS must be a positive integer" >&2
  exit 64
}
[[ "$max_attempts" =~ ^[0-9]+$ ]] || {
  echo "retry-hourly: RETRY_MAX_ATTEMPTS must be a non-negative integer" >&2
  exit 64
}
attempt=1
log=""
cleanup() { [ -z "$log" ] || rm -f "$log"; }
trap cleanup EXIT INT TERM

while true; do
  # Do not echo arguments: commands may legitimately receive tokens, passphrases, or key paths.
  echo "retry-hourly: attempt ${attempt}: $(basename -- "$1") ($# argument(s))" >&2
  umask 077
  log="$(mktemp)"
  set +e
  "$@" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e

  if [ "$status" -eq 0 ]; then
    cleanup
    log=""
    exit 0
  fi

  if ! grep -Eiq 'rate limit|rate-limit|usage limit|quota|too many requests|try again later|429' "$log"; then
    cleanup
    log=""
    echo "retry-hourly: command failed with status ${status}; not retrying because this does not look like a usage/rate limit." >&2
    exit "$status"
  fi
  cleanup
  log=""

  if [ "$max_attempts" -gt 0 ] && [ "$attempt" -ge "$max_attempts" ]; then
    echo "retry-hourly: reached RETRY_MAX_ATTEMPTS=${max_attempts}" >&2
    exit "$status"
  fi

  echo "retry-hourly: usage/rate limit detected; sleeping ${delay_seconds}s before retry." >&2
  sleep "$delay_seconds"
  attempt=$((attempt + 1))
done
