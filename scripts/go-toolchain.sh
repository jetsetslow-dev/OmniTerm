#!/usr/bin/env bash
# The repository's own Go toolchain: a pinned release from go.dev, checked against its published
# SHA-256 before it is unpacked under .go-toolchain/ (gitignored). Nothing is installed on the host,
# and CI runs this same script. Prints the environment to evaluate:
#   eval "$(./scripts/go-toolchain.sh)"
# or, in a GitHub Actions step, `./scripts/go-toolchain.sh --github` for the steps after it.
set -euo pipefail

GO_VERSION=1.27.4
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/.go-toolchain"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) PLATFORM=linux-amd64 SHA256=7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840 ;;
  Linux-aarch64 | Linux-arm64) PLATFORM=linux-arm64 SHA256=3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92 ;;
  Darwin-arm64) PLATFORM=darwin-arm64 SHA256=91a44a2b8a716600ad94a4f143e156116620db8828086a6e3602291be9bd0bb4 ;;
  Darwin-x86_64) PLATFORM=darwin-amd64 SHA256=2b799377704ef12db39bd254995d5c348c9cc8d86562ca817724390e56c38f43 ;;
  *) echo "go-toolchain: no pinned Go $GO_VERSION for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

GOROOT_DIR="$DEST/go$GO_VERSION-$PLATFORM"
if [[ ! -x "$GOROOT_DIR/bin/go" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  archive="go$GO_VERSION.$PLATFORM.tar.gz"
  curl -fsSL --retry 3 --max-time 600 -o "$tmp/$archive" "https://go.dev/dl/$archive"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$tmp/$archive" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$tmp/$archive" | cut -d' ' -f1)"
  fi
  if [[ "$actual" != "$SHA256" ]]; then
    echo "go-toolchain: $archive has SHA-256 $actual, expected $SHA256; not unpacked" >&2
    exit 1
  fi
  mkdir -p "$tmp/unpacked" "$DEST"
  tar -xzf "$tmp/$archive" -C "$tmp/unpacked"
  mv "$tmp/unpacked/go" "$GOROOT_DIR"
fi

# Everything Go writes stays under .go-toolchain/ too. GOTOOLCHAIN=local stops Go fetching another
# toolchain on its own; modules are checked against go.sum and the public checksum database.
ENV=(
  "GOROOT=$GOROOT_DIR"
  "GOPATH=$DEST/gopath"
  "GOMODCACHE=$DEST/gopath/pkg/mod"
  "GOCACHE=$DEST/cache"
  "GOTOOLCHAIN=local"
  "GOFLAGS=-mod=readonly"
)
BIN=("$GOROOT_DIR/bin" "$DEST/gopath/bin")

if [[ "${1:-}" == "--github" ]]; then
  # For the later steps of a GitHub Actions job. Run it before CodeQL's init: CodeQL wraps the go it
  # finds on PATH to watch the build, and a step that put this go in front of the wrapper afterwards
  # left CodeQL seeing no Go at all (PR #147).
  printf '%s\n' "${ENV[@]}" >> "${GITHUB_ENV:?--github runs only inside GitHub Actions}"
  printf '%s\n' "${BIN[@]}" >> "${GITHUB_PATH:?--github runs only inside GitHub Actions}"
  exit 0
fi
for entry in "${ENV[@]}"; do
  printf "export %s='%s'\n" "${entry%%=*}" "${entry#*=}"
done
printf "export PATH='%s:%s':\"\$PATH\"\n" "${BIN[@]}"
