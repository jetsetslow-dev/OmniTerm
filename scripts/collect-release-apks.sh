#!/usr/bin/env bash
# Copies the open-source release APKs Gradle built (-Pomniterm.abiSplits=true) into a folder under
# the names a GitHub release gives them. The universal APK keeps the name the single APK always had,
# OmniTerm-OpenSource-<tag>.apk; each architecture's APK adds its architecture,
# OmniTerm-OpenSource-<tag>-arm64-v8a.apk and so on. A release that built no APK copies nothing.
# The release workflow and scripts/local-pr-check.sh --full collect through it; then
# scripts/verify-release-apks.py checks what was collected.
#   collect-release-apks.sh <tag> <folder>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
label="${1:?usage: collect-release-apks.sh <tag> <folder>}"
dest="${2:?usage: collect-release-apks.sh <tag> <folder>}"
mkdir -p "$dest"
for apk in "$ROOT"/app/build/outputs/apk/openSource/release/app-openSource-*-release.apk; do
  [ -e "$apk" ] || continue
  abi="${apk##*/app-openSource-}"
  abi="${abi%-release.apk}"
  case "$abi" in
    universal) cp "$apk" "$dest/OmniTerm-OpenSource-$label.apk" ;;
    *) cp "$apk" "$dest/OmniTerm-OpenSource-$label-$abi.apk" ;;
  esac
done
