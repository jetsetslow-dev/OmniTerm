#!/usr/bin/env bash
# Shared packed-SemVer helpers for the local release command and GitHub Actions.
#
# Android versionCode layout:
#   major * 10_000_000 + minor * 100_000 + patch * 100 + build
# A prerelease uses build 1..98 (its trailing decimal number, or 1 when absent);
# the final release uses build 99. Limits keep the result inside Android's signed
# 32-bit versionCode range and reserve room for promotion without changing the base.

# Capture a command's stdout only when the command succeeds. Some clients (notably `gh api`)
# emit a structured error body to stdout on failure; treating that body as a successful response
# can turn a normal 404 into false release state.
capture_stdout_on_success() {
  local output
  if output="$("$@")"; then
    printf '%s' "$output"
  fi
  return 0
}

version_validate() {
  local tag="${1:-}"
  [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+)(\.[0-9A-Za-z-]+)*)?$ ]] || return 1

  local major="${BASH_REMATCH[1]}"
  local minor="${BASH_REMATCH[2]}"
  local patch="${BASH_REMATCH[3]}"
  # Bound digit counts before Bash arithmetic. Otherwise an attacker-controlled, extremely
  # long decimal can wrap the shell's signed integer and incorrectly pass the upper-bound test.
  [[ ${#major} -le 3 && ${#minor} -le 2 && ${#patch} -le 3 ]] || return 1
  (( 10#$major <= 200 && 10#$minor <= 99 && 10#$patch <= 999 )) || return 1

  if [[ "$tag" == *-* ]]; then
    local suffix="${tag#*-}"
    local identifier
    while IFS= read -r identifier; do
      [[ ! "$identifier" =~ ^0[0-9]+$ ]] || return 1
    done < <(printf '%s\n' "$suffix" | tr '.' '\n')
    local build=1
    if [[ "$suffix" =~ ([0-9]+)$ ]]; then
      (( ${#BASH_REMATCH[1]} <= 2 )) || return 1
      build=$((10#${BASH_REMATCH[1]}))
    fi
    (( build >= 1 && build <= 98 )) || return 1
  fi
}

# Print every valid tag from stdin that aliases [candidate]'s Android versionCode, excluding the
# candidate itself. Distinct immutable tags must never own the same Play versionCode.
version_collisions() {
  local candidate="${1:-}"
  local candidate_code tag code
  candidate_code="$(version_pack "$candidate")" || return 1
  while IFS= read -r tag; do
    [[ "$tag" != "$candidate" ]] || continue
    code="$(version_pack "$tag")" || continue
    [[ "$code" != "$candidate_code" ]] || printf '%s\n' "$tag"
  done
}

version_pack() {
  local tag="${1:-}"
  version_validate "$tag" || return 1

  local value="${tag#v}"
  local base="${value%%-*}"
  local major="${base%%.*}"
  local rest="${base#*.}"
  local minor="${rest%%.*}"
  local patch="${rest#*.}"
  local build=99
  if [[ "$value" == *-* ]]; then
    local suffix="${value#*-}"
    build=1
    if [[ "$suffix" =~ ([0-9]+)$ ]]; then
      (( ${#BASH_REMATCH[1]} <= 2 )) || return 1
      build=$((10#${BASH_REMATCH[1]}))
    fi
  fi
  printf '%d\n' "$((major * 10000000 + minor * 100000 + patch * 100 + build))"
}

version_highest() {
  local tag code
  while IFS= read -r tag; do
    code="$(version_pack "$tag")" || continue
    printf '%s %s\n' "$code" "$tag"
  done | sort -n -k1,1 | tail -1 | cut -d' ' -f2-
}

version_next_production() {
  local latest="${1:-}"
  version_validate "$latest" || return 1
  local base="${latest#v}"
  if [[ "$base" == *-* ]]; then
    printf 'v%s\n' "${base%%-*}"
    return
  fi
  local major="${base%%.*}"
  local rest="${base#*.}"
  local minor="${rest%%.*}"
  local patch="${rest#*.}"
  (( patch < 999 )) || return 1
  printf 'v%d.%d.%d\n' "$major" "$minor" "$((patch + 1))"
}

version_next_prerelease() {
  local latest="${1:-}"
  local label="${2:-Alpha}"
  version_validate "$latest" || return 1
  [[ "$label" =~ ^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$ ]] || return 1

  local base="${latest#v}"
  base="${base%%-*}"
  local major="${base%%.*}"
  local rest="${base#*.}"
  local minor="${rest%%.*}"
  local patch="${rest#*.}"
  (( patch < 999 )) || return 1
  local candidate="v${major}.${minor}.$((patch + 1))-${label}"
  version_validate "$candidate" || return 1
  printf '%s\n' "$candidate"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  command="${1:-}"
  shift || true
  case "$command" in
    validate) version_validate "${1:-}" ;;
    pack) version_pack "${1:-}" ;;
    highest) version_highest ;;
    collisions) version_collisions "${1:-}" ;;
    next-production) version_next_production "${1:-}" ;;
    next-prerelease) version_next_prerelease "${1:-}" "${2:-Alpha}" ;;
    *)
      echo "usage: $0 {validate|pack|highest|collisions|next-production|next-prerelease} [args]" >&2
      exit 64
      ;;
  esac
fi
