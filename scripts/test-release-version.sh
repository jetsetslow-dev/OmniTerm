#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=release-version.sh
source "$ROOT/scripts/release-version.sh"

assert_eq() {
  [[ "$1" == "$2" ]] || { echo "expected '$2', got '$1'" >&2; exit 1; }
}

assert_eq "$(version_pack v1.2.3-Alpha)" "10200301"
assert_eq "$(version_pack v1.2.3-rc.2)" "10200302"
assert_eq "$(version_pack v1.2.3)" "10200399"
assert_eq "$(printf '%s\n' v1.2.3 v1.2.4-Alpha v1.2.4-rc.2 invalid | version_highest)" "v1.2.4-rc.2"
assert_eq "$(version_next_production v1.2.3-rc.2)" "v1.2.3"
assert_eq "$(version_next_production v1.2.3)" "v1.2.4"
assert_eq "$(version_next_prerelease v1.2.3 rc.2)" "v1.2.4-rc.2"
assert_eq "$(printf '%s\n' v1.2.3-Alpha v1.2.3-Beta v1.2.3-main.1 v1.2.3-rc.2 | version_collisions v1.2.3-main.1)" $'v1.2.3-Alpha\nv1.2.3-Beta'

for invalid in v1.2 v1.2.3-rc.0 v1.2.3-rc.99 v1.2.3-rc.99999999999999999999 \
  v201.0.0 v999999999999999999999999999999.0.0 v1.999999999999999999999999999999.0 \
  v1.2.999999999999999999999999999999 v1.100.0 v1.2.1000 v01.2.3 v1.02.3 \
  v1.2.3-01 v1.2.3-rc.02; do
  if version_validate "$invalid"; then
    echo "expected '$invalid' to be invalid" >&2
    exit 1
  fi
done

echo "release-version tests passed"
