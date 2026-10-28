#!/usr/bin/env bash
# Pins scripts/check-duplicates.py: a copied block fails, a known one passes, and copying a known
# block once more fails again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-duplicates.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

block() {
  cat <<KOTLIN
// $1
fun total(values: List<Int>): Int {
    var total = 0
    for (value in values) {
        if (value > 10) total += value * 2 else total -= value
        if (total > 1000) return total / 3 + values.size
    }
    return total + values.size * 4 - values.count { it % 2 == 0 }
}
KOTLIN
}

expect() {
  local want="$1"; shift
  local got=0
  python3 "$CHECK" --baseline "$WORK/baseline.json" "$@" "$WORK/src" > "$WORK/out" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    echo "check-duplicates: expected exit $want, got $got" >&2
    cat "$WORK/out" >&2
    exit 1
  fi
}

mkdir -p "$WORK/src"
block "The original." > "$WORK/src/A.kt"
expect 0
# Comments do not make a copy any different.
block "A copy with its own comment." > "$WORK/src/B.kt"
expect 1
grep -q "New duplicated block" "$WORK/out"
expect 0 --update-baseline
expect 0
cp "$WORK/src/B.kt" "$WORK/src/C.kt"
expect 1
grep -q "3 copies" "$WORK/out"

echo "check-duplicates tests passed."
