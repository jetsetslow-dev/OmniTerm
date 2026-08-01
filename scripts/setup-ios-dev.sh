#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  cat >&2 <<'MESSAGE'
OmniTerm iOS development requires macOS. This host can build common/Android code, but Apple does
not provide Xcode, iOS SDKs, Simulator runtimes, or signing tools for Linux. Run this script from a
Mac after installing the supported Xcode release documented in docs/IOS_BUILDING.md.
MESSAGE
  exit 2
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required. Install it from Apple, launch it once, then rerun this script." >&2
  exit 2
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh" >&2
  exit 2
fi

echo "Installing pinned iOS development tools from iosApp/Brewfile"
brew bundle --file iosApp/Brewfile

echo "Checking Xcode command-line selection and first-launch components"
xcode-select -p
xcodebuild -version
xcodebuild -checkFirstLaunchStatus

echo "Checking toolchain versions"
java -version
swift --version
pod --version
swiftformat --version
swiftlint version
xcbeautify --version
xcodegen --version

echo "Resolving shared dependencies and compiling common tests"
./gradlew :shared:allTests --no-daemon --no-configuration-cache

echo "Compiling the iOS Simulator framework"
./gradlew :shared:linkDebugFrameworkIosSimulatorArm64 --no-daemon --no-configuration-cache

echo "iOS command-line environment is ready. Configure your Apple Team in Xcode before device use."
