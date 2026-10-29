#!/usr/bin/env bash
# Runs the CodeQL analysis of .github/workflows/codeql.yml on this working tree, so an alert shows
# up before a push instead of on the pull request. main has no open java-kotlin alerts, so any
# result fails.
#
# The CLI version follows the workflow's github/codeql-action pin (its src/defaults.json
# "cliVersion"); bump CODEQL_VERSION and CODEQL_JAVA_BUNDLE_SHA256 together with that pin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CODEQL_VERSION=2.27.3
CODEQL_JAVA_BUNDLE_SHA256=8ba44c5caf0906f477163946bf4c16811e494ed43a717731a8bd226ab29f7065
CODEQL="${OMNITERM_CODEQL:-$HOME/sdks/codeql-$CODEQL_VERSION/codeql/codeql}"

if [[ ! -x "$CODEQL" ]]; then
  cat >&2 <<EOF
CodeQL $CODEQL_VERSION is not installed at $CODEQL. Install the Java bundle the workflow uses:
  mkdir -p ~/sdks/codeql-$CODEQL_VERSION && cd ~/sdks/codeql-$CODEQL_VERSION
  curl -fsSLO https://github.com/github/codeql-action/releases/download/codeql-bundle-v$CODEQL_VERSION/codeql-bundle-java-linux64.tar.zst
  echo "$CODEQL_JAVA_BUNDLE_SHA256  codeql-bundle-java-linux64.tar.zst" | sha256sum -c -
  tar --zstd -xf codeql-bundle-java-linux64.tar.zst && rm codeql-bundle-java-linux64.tar.zst
or point OMNITERM_CODEQL at an existing $CODEQL_VERSION CLI.
EOF
  exit 1
fi
installed="$("$CODEQL" version --format=terse)"
if [[ "$installed" != "$CODEQL_VERSION" ]]; then
  echo "CodeQL $installed found at $CODEQL; the workflow runs $CODEQL_VERSION." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The extractor sees only what the compiler actually runs, and a fresh CI checkout compiles
# everything. Without the clean, up-to-date Kotlin tasks would leave the database nearly empty.
./gradlew clean --no-daemon --quiet
# The workflow traces scripts/ci-gradle-gate.sh; on a pull request that is the compile of both
# variants and nothing else.
GITHUB_EVENT_NAME=pull_request "$CODEQL" database create "$work/db" \
  --language=java-kotlin --source-root="$ROOT" --overwrite \
  --command="$ROOT/scripts/ci-gradle-gate.sh"
"$CODEQL" database analyze "$work/db" codeql/java-queries:codeql-suites/java-security-extended.qls \
  --format=sarif-latest --output="$work/results.sarif" --threads=0 --ram=8192

# Green with nothing extracted would mean no analysis ran, not that the code is clean.
baseline="$("$CODEQL" database print-baseline "$work/db" | grep -oE '[0-9]+ lines of code' | head -1)"
if [[ -z "$baseline" || "$baseline" == "0 lines of code" ]]; then
  echo "CodeQL extracted no Kotlin or Java code; the analysis did not run." >&2
  exit 1
fi

python3 - "$work/results.sarif" "$baseline" <<'PY'
import json, sys
results = [r for run in json.load(open(sys.argv[1]))["runs"] for r in run.get("results", [])]
for r in results:
    loc = r["locations"][0]["physicalLocation"]
    line = loc.get("region", {}).get("startLine", "?")
    print(f'{r["ruleId"]}: {loc["artifactLocation"]["uri"]}:{line}\n  {r["message"]["text"]}')
if results:
    sys.exit(f"CodeQL: {len(results)} alert(s) the pull request would add.")
print(f"CodeQL: no alerts ({sys.argv[2]} analysed).")
PY
