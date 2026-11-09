#!/usr/bin/env bash
# The repository's own Go toolchain: a pinned release from go.dev, checked against its published
# SHA-256 before it is unpacked under .go-toolchain/ (gitignored). Nothing is installed on the host,
# and CI runs this same script. Prints the environment to evaluate:
#   eval "$(./scripts/go-toolchain.sh)"
set -euo pipefail

GO_VERSION=1.27.3
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/.go-toolchain"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) PLATFORM=linux-amd64 SHA256=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40 ;;
  Linux-aarch64 | Linux-arm64) PLATFORM=linux-arm64 SHA256=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49 ;;
  Darwin-arm64) PLATFORM=darwin-arm64 SHA256=dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2 ;;
  Darwin-x86_64) PLATFORM=darwin-amd64 SHA256=b6f8e931e4ab497fcde6da8ae4499a58f9d258e55c8a80824a516eae5950a750 ;;
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
cat <<EOF
export GOROOT='$GOROOT_DIR'
export GOPATH='$DEST/gopath'
export GOMODCACHE='$DEST/gopath/pkg/mod'
export GOCACHE='$DEST/cache'
export GOTOOLCHAIN=local
export GOFLAGS=-mod=readonly
export PATH='$GOROOT_DIR/bin:$DEST/gopath/bin':"\$PATH"
EOF
