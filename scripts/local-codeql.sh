#!/usr/bin/env bash
# Runs the CodeQL analyses of .github/workflows/codeql.yml on this working tree, Java/Kotlin and the
# Go tunnel library, so an alert or a broken analysis shows up before a push instead of on the pull
# request or, for test code, on main. main has no open alerts, so any result fails.
#
# The CLI version follows the workflow's github/codeql-action pin (its src/defaults.json
# "cliVersion"); bump CODEQL_VERSION and both bundle digests together with that pin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CODEQL_VERSION=2.27.4
CODEQL_JAVA_BUNDLE_SHA256=dbeb8e2f4454bf4aad35fe16d8770dcc4a4ce0c3585d8952d57e41905396aff8
CODEQL_GO_BUNDLE_SHA256=d79b33f86ec8b20af73d3456041349a2780c1081ee8c0eca624b9a25c5cb2e15
CODEQL="${OMNITERM_CODEQL:-$HOME/sdks/codeql-$CODEQL_VERSION/codeql/codeql}"
# The Go bundle is fetched here on first use, beside the repository's Go toolchain (gitignored, and
# outside what the Java extractor indexes).
CODEQL_GO_DIR="$ROOT/.go-toolchain/codeql-$CODEQL_VERSION"
CODEQL_GO="${OMNITERM_CODEQL_GO:-$CODEQL_GO_DIR/codeql/codeql}"

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
if [[ ! -x "$CODEQL_GO" ]]; then
  if [[ -n "${OMNITERM_CODEQL_GO:-}" || "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]]; then
    echo "CodeQL $CODEQL_VERSION for Go is not at $CODEQL_GO; point OMNITERM_CODEQL_GO at one." >&2
    exit 1
  fi
  fetch="$(mktemp -d)"
  bundle="codeql-bundle-go-linux64.tar.zst"
  curl -fsSL --retry 3 --max-time 900 -o "$fetch/$bundle" \
    "https://github.com/github/codeql-action/releases/download/codeql-bundle-v$CODEQL_VERSION/$bundle"
  actual="$(sha256sum "$fetch/$bundle" | cut -d' ' -f1)"
  if [[ "$actual" != "$CODEQL_GO_BUNDLE_SHA256" ]]; then
    rm -rf "$fetch"
    echo "$bundle has SHA-256 $actual, expected $CODEQL_GO_BUNDLE_SHA256; not unpacked." >&2
    exit 1
  fi
  mkdir -p "$fetch/unpacked"
  tar --zstd -xf "$fetch/$bundle" -C "$fetch/unpacked"
  rm -rf "$CODEQL_GO_DIR"
  mkdir -p "$(dirname "$CODEQL_GO_DIR")"
  mv "$fetch/unpacked" "$CODEQL_GO_DIR"
  rm -rf "$fetch"
fi
for cli in "$CODEQL" "$CODEQL_GO"; do
  installed="$("$cli" version --format=terse)"
  if [[ "$installed" != "$CODEQL_VERSION" ]]; then
    echo "CodeQL $installed found at $cli; the workflow runs $CODEQL_VERSION." >&2
    exit 1
  fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The extractor sees only what the compiler actually runs, and a fresh CI checkout compiles
# everything. Without the clean, up-to-date Kotlin tasks would leave the database nearly empty.
./gradlew clean --no-daemon --quiet
# The workflow traces scripts/ci-gradle-gate.sh; on a pull request that is the compile of both
# variants and nothing else. main's run also compiles the tests: its unit tests, lint and the Room
# migration suite run under the same tracer. So an alert in test code showed only after a merge,
# and alert 39 (ssh-keygen by relative path in SshSignInLiveTest) sat on main for six days. This
# traces the pull request's compile and then the test sources main's run compiles.
cat > "$work/build.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
GITHUB_EVENT_NAME=pull_request "$ROOT/scripts/ci-gradle-gate.sh"
"$ROOT/gradlew" --no-daemon --no-build-cache --no-configuration-cache --quiet \\
  :app:compileOpenSourceDebugUnitTestKotlin :app:compilePlayStoreDebugUnitTestKotlin \\
  :app:compileOpenSourceDebugAndroidTestKotlin
EOF
chmod +x "$work/build.sh"
# The repo-local Go toolchain's module cache (.go-toolchain/, ignored by git) holds gomobile's
# example apps, whose manifests would read as five alerts of our own. The Java extractor indexes
# XML files by these filters (its own `exclude` option does not reach XML); the workflow sets the
# same.
export LGTM_INDEX_FILTERS='exclude:.go-toolchain/**'
"$CODEQL" database create "$work/db" \
  --language=java-kotlin --source-root="$ROOT" --overwrite \
  --command="$work/build.sh"
"$CODEQL" database analyze "$work/db" codeql/java-queries:codeql-suites/java-security-extended.qls \
  --format=sarif-latest --output="$work/results.sarif" --threads=0 --ram=8192

# Green with nothing extracted would mean no analysis ran, not that the code is clean.
lines_of_code() {
  local found
  found="$("$1" database print-baseline "$2" | grep -oE '[0-9]+ lines of code' | head -1)"
  if [[ -z "$found" || "$found" == "0 lines of code" ]]; then
    echo "CodeQL extracted no $3 code; the analysis did not run." >&2
    exit 1
  fi
  echo "$found"
}
java_baseline="$(lines_of_code "$CODEQL" "$work/db" "Kotlin or Java")"

# The Go job as the workflow runs it: the pinned toolchain on PATH before CodeQL starts, the source
# root limited to tunnel/, and `go build ./...` traced with a cold build cache, as on a fresh runner.
(
  eval "$("$ROOT/scripts/go-toolchain.sh")"
  export GOCACHE="$work/go-cache"
  "$CODEQL_GO" database create "$work/go-db" \
    --language=go --source-root="$ROOT/tunnel" --working-dir="$ROOT/tunnel" --overwrite \
    --command="go build ./..."
)
"$CODEQL_GO" database analyze "$work/go-db" codeql/go-queries:codeql-suites/go-security-extended.qls \
  --format=sarif-latest --output="$work/go-results.sarif" --threads=0 --ram=8192
go_baseline="$(lines_of_code "$CODEQL_GO" "$work/go-db" "Go")"

python3 -I - "$work/results.sarif" "$work/go-results.sarif" "$java_baseline of Kotlin/Java" "$go_baseline of Go" <<'PY'
import json, sys
results = [r for f in sys.argv[1:3] for run in json.load(open(f))["runs"] for r in run.get("results", [])]
for r in results:
    loc = r["locations"][0]["physicalLocation"]
    line = loc.get("region", {}).get("startLine", "?")
    print(f'{r["ruleId"]}: {loc["artifactLocation"]["uri"]}:{line}\n  {r["message"]["text"]}')
if results:
    sys.exit(f"CodeQL: {len(results)} alert(s) the pull request would add.")
print(f"CodeQL: no alerts ({sys.argv[3]} and {sys.argv[4]} analysed).")
PY
