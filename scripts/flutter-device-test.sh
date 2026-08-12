#!/usr/bin/env bash
# Run the repeatable Flutter device matrix and retain enough evidence to diagnose a failure on a
# different Android release or an iOS simulator later.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER_APP="$ROOT/flutter_app"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
PROFILE="core"
PLATFORM="auto"
DEVICE=""
ARTIFACT_ROOT="${OMNITERM_DEVICE_ARTIFACTS:-$ROOT/artifacts/device-tests}"
USE_FIXTURES=true
FAIL_ON_WARNING=true
ANDROID_PREVIOUS_STAY=""

restore_android_power() {
  if [ "$PLATFORM" != android ] || [ -z "$ANDROID_PREVIOUS_STAY" ]; then return; fi
  adb -s "$DEVICE" shell settings put global stay_on_while_plugged_in \
    "$ANDROID_PREVIOUS_STAY" >/dev/null 2>&1 || true
  if [ "$(adb -s "$DEVICE" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')" != "$ANDROID_PREVIOUS_STAY" ]; then
    adb -s "$DEVICE" shell su -c \
      "settings put global stay_on_while_plugged_in $ANDROID_PREVIOUS_STAY" >/dev/null 2>&1 || true
  fi
}
trap restore_android_power EXIT

usage() {
  cat <<'EOF'
Usage: ./scripts/flutter-device-test.sh --device <id> [options]

Options:
  --platform android|ios|auto   Override platform detection (default: auto)
  --profile core|surface|host|all
                                core = surface + walkthrough + actions (default)
                                host = live Docker/Podman/share fixture operations
  --artifacts <directory>       Artifact root (default: artifacts/device-tests)
  --no-fixtures                 Do not start/reverse the disposable host fleet
  --allow-warnings              Record compiler/test warnings without failing the run
  --help                        Show this help

Examples:
  ./scripts/flutter-device-test.sh --device ZF62224F8K --platform android
  ./scripts/flutter-device-test.sh --device emulator-5554 --profile surface
  ./scripts/flutter-device-test.sh --device ZF62224F8K --profile host
  ./scripts/flutter-device-test.sh --device <simulator-uuid> --platform ios

The iOS command is intended to run unchanged from a macOS checkout with a booted iPhone simulator.
It requires Flutter, Xcode command-line tools, CocoaPods, and (for host-backed tests) Docker Desktop.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --device)
      [ "$#" -ge 2 ] || { echo "--device requires a value" >&2; exit 2; }
      DEVICE="$2"; shift 2
      ;;
    --platform)
      [ "$#" -ge 2 ] || { echo "--platform requires a value" >&2; exit 2; }
      PLATFORM="$2"; shift 2
      ;;
    --profile)
      [ "$#" -ge 2 ] || { echo "--profile requires a value" >&2; exit 2; }
      PROFILE="$2"; shift 2
      ;;
    --artifacts)
      [ "$#" -ge 2 ] || { echo "--artifacts requires a value" >&2; exit 2; }
      ARTIFACT_ROOT="$2"; shift 2
      ;;
    --no-fixtures) USE_FIXTURES=false; shift ;;
    --allow-warnings) FAIL_ON_WARNING=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$DEVICE" ] || { echo "--device is required" >&2; usage >&2; exit 2; }
case "$PLATFORM" in auto|android|ios) ;; *) echo "unsupported platform: $PLATFORM" >&2; exit 2 ;; esac
case "$PROFILE" in core|surface|host|all) ;; *) echo "unsupported profile: $PROFILE" >&2; exit 2 ;; esac
command -v "$FLUTTER_BIN" >/dev/null || {
  echo "Flutter was not found. Put it on PATH or set FLUTTER_BIN=/absolute/path/to/flutter." >&2
  exit 2
}

# This Linux host may run a fixture-only daemon beside a blocked system daemon. Docker Desktop and
# ordinary Linux installs keep using their default context; an explicit DOCKER_HOST always wins.
if [ -z "${DOCKER_HOST:-}" ] && [ -S /run/omniterm-test-docker.sock ]; then
  export DOCKER_HOST=unix:///run/omniterm-test-docker.sock
fi

if [ "$PLATFORM" = auto ]; then
  if command -v adb >/dev/null && adb -s "$DEVICE" get-state >/dev/null 2>&1; then
    PLATFORM=android
  elif command -v xcrun >/dev/null && xcrun simctl list devices booted | grep -Fq "$DEVICE"; then
    PLATFORM=ios
  else
    echo "could not detect the platform for $DEVICE; pass --platform android or --platform ios" >&2
    exit 2
  fi
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SAFE_DEVICE="$(printf '%s' "$DEVICE" | tr -c '[:alnum:]_.-' '_')"
RUN_DIR="$ARTIFACT_ROOT/${STAMP}_${PLATFORM}_${SAFE_DEVICE}_${PROFILE}"
mkdir -p "$RUN_DIR"
ln -sfn "$(basename "$RUN_DIR")" "$ARTIFACT_ROOT/latest"

START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "started_utc=$START_ISO"
  echo "device=$DEVICE"
  echo "platform=$PLATFORM"
  echo "profile=$PROFILE"
  echo "git_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  if git -C "$ROOT" diff --quiet && git -C "$ROOT" diff --cached --quiet; then
    echo "git_worktree=clean"
  else
    echo "git_worktree=dirty"
  fi
  echo "host_uname=$(uname -a)"
  echo "docker_host=${DOCKER_HOST:-default-context}"
} >"$RUN_DIR/metadata.txt"
git -C "$ROOT" status --short >"$RUN_DIR/git-status.txt" 2>&1 || true
"$FLUTTER_BIN" --version >"$RUN_DIR/flutter-version.txt" 2>&1 || true
"$FLUTTER_BIN" doctor -v >"$RUN_DIR/flutter-doctor.txt" 2>&1 || true
"$FLUTTER_BIN" devices --machine >"$RUN_DIR/flutter-devices.json" 2>&1 || true

if [ "$PLATFORM" = android ]; then
  command -v adb >/dev/null || { echo "adb is required for Android" >&2; exit 2; }
  adb -s "$DEVICE" wait-for-device
  ANDROID_PREVIOUS_STAY="$(adb -s "$DEVICE" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')"
  case "$ANDROID_PREVIOUS_STAY" in ''|*[!0-9]*) ANDROID_PREVIOUS_STAY=0 ;; esac
  adb -s "$DEVICE" shell settings put global stay_on_while_plugged_in 7 >/dev/null 2>&1 || true
  if [ "$(adb -s "$DEVICE" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')" != 7 ]; then
    # A rooted development device can grant what some vendor builds withhold from the shell user.
    # Failure remains non-fatal for ordinary unrooted devices, but the captured value explains a
    # later sleep-related timeout instead of making it look like an app hang.
    adb -s "$DEVICE" shell su -c \
      'settings put global stay_on_while_plugged_in 7' >/dev/null 2>&1 || true
  fi
  adb -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb -s "$DEVICE" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  adb -s "$DEVICE" shell getprop >"$RUN_DIR/android-getprop.txt" 2>&1 || true
  {
    adb -s "$DEVICE" shell wm size
    adb -s "$DEVICE" shell wm density
    adb -s "$DEVICE" shell settings get system font_scale
    adb -s "$DEVICE" shell settings get system screen_off_timeout
    echo "stay_on_while_plugged_in_before=$ANDROID_PREVIOUS_STAY"
    echo "stay_on_while_plugged_in_during=$(adb -s "$DEVICE" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')"
    adb -s "$DEVICE" shell id
  } >"$RUN_DIR/android-display-and-access.txt" 2>&1 || true
  adb -s "$DEVICE" logcat -c >/dev/null 2>&1 || true
  if $USE_FIXTURES; then
    if ! "$ROOT/scripts/test-hosts.sh" up >"$RUN_DIR/fixture-startup.log" 2>&1; then
      echo "fixture startup failed; see $RUN_DIR/fixture-startup.log" >&2
      exit 2
    fi
    case "$DEVICE" in
      emulator-*) ;;
      *) "$ROOT/scripts/test-hosts.sh" android "$DEVICE" >>"$RUN_DIR/fixture-startup.log" 2>&1 ;;
    esac
  fi
else
  command -v xcrun >/dev/null || { echo "xcrun is required for iOS simulator tests" >&2; exit 2; }
  xcrun simctl list --json >"$RUN_DIR/ios-simulators.json" 2>&1 || true
  xcodebuild -version >"$RUN_DIR/xcode-version.txt" 2>&1 || true
  sw_vers >"$RUN_DIR/macos-version.txt" 2>&1 || true
  xcrun simctl spawn "$DEVICE" uname -a >"$RUN_DIR/ios-simulator-uname.txt" 2>&1 || true
  if $USE_FIXTURES; then
    if ! "$ROOT/scripts/test-hosts.sh" up >"$RUN_DIR/fixture-startup.log" 2>&1; then
      echo "fixture startup failed; see $RUN_DIR/fixture-startup.log" >&2
      exit 2
    fi
  fi
fi

case "$PROFILE" in
  surface)
    TESTS=(integration_test/app_surface_stress_test.dart)
    ;;
  # Everything that does not need the lab, discovered rather than listed.
  #
  # This was a hand-written list of three files, and the four it omitted -- app lock, key generate,
  # key import, back/exit -- were never run by any slice that used this profile. Two of them had
  # been failing since the flows they drive gained a confirmation dialog and a re-auth gate
  # (ledger 62 and 70): nobody saw it, because the profile everyone reached for did not include
  # them. A new integration test now joins `core` by existing, which is the only version of this
  # that cannot rot again.
  core)
    TESTS=()
    while IFS= read -r test_file; do TESTS+=("$test_file"); done < <(
      cd "$FLUTTER_APP" && find integration_test -name '*_test.dart' \
        ! -name 'host_backed_e2e_test.dart' -print | sort
    )
    ;;
  host)
    TESTS=(integration_test/host_backed_e2e_test.dart)
    ;;
  all)
    TESTS=()
    while IFS= read -r test_file; do TESTS+=("$test_file"); done < <(
      cd "$FLUTTER_APP" && find integration_test -name '*_test.dart' -print | sort
    )
    ;;
esac

TEST_ARGS=()
if [ "$PROFILE" = host ] || [ "$PROFILE" = all ]; then
  [ -f "$ROOT/scripts/test-hosts/.env" ] || {
    echo "host-backed tests require scripts/test-hosts/.env; run scripts/test-hosts.sh up" >&2
    exit 2
  }
  E2E_HOST=127.0.0.1
  if [ "$PLATFORM" = android ] && [[ "$DEVICE" = emulator-* ]]; then
    E2E_HOST=10.0.2.2
  fi
  TEST_ARGS+=(
    --dart-define-from-file="$ROOT/scripts/test-hosts/.env"
    --dart-define=OMNITERM_E2E_HOSTS=true
    --dart-define="OMNITERM_E2E_HOST=$E2E_HOST"
  )
fi

{
  printf 'command='
  printf '%q ' "$FLUTTER_BIN" test "${TESTS[@]}" -d "$DEVICE" --reporter expanded "${TEST_ARGS[@]}"
  printf '\n'
} >>"$RUN_DIR/metadata.txt"

# Patrol tests drive the *system* UI -- the document picker, the permission dialog -- which lives in
# another process. `flutter test` cannot see it, so those files need Patrol's own runner. They are
# split out by content rather than by directory: a file belongs to Patrol because it calls
# `patrolTest`, and putting them in a folder no profile looked at is how they went unrun for months.
PATROL_TESTS=()
PLAIN_TESTS=()
for test_file in "${TESTS[@]}"; do
  if grep -q 'patrolTest(' "$FLUTTER_APP/$test_file"; then
    PATROL_TESTS+=("$test_file")
  else
    PLAIN_TESTS+=("$test_file")
  fi
done

echo "Device test artifacts: $RUN_DIR"
set +e
TEST_RC=0
if [ "${#PLAIN_TESTS[@]}" -gt 0 ]; then
  (
    cd "$FLUTTER_APP" &&
      "$FLUTTER_BIN" test "${PLAIN_TESTS[@]}" -d "$DEVICE" --reporter expanded "${TEST_ARGS[@]}"
  ) 2>&1 | tee "$RUN_DIR/test.log"
  TEST_RC=${PIPESTATUS[0]}
fi

# Patrol needs `dart` on PATH; the CLI is a Dart snapshot wrapper and exits with "dart: not found"
# otherwise, which reads like a missing test rather than a missing toolchain.
# Patrol defaults its test and app servers to 8081 and 8082 -- both of which `test-hosts.sh android`
# reverses to this workstation for the fixture fleet (8082 is the WebDAV share, 8081 a scan target).
# A reverse claims the port *on the device*, which is precisely where Patrol's servers listen, so the
# handshake never lands: the run hangs in `waitForPatrolAppService` and Gradle reports "Test run
# failed to complete. No test results" with a total of zero. It only ever bit the phone, because the
# runner does not reverse ports to an emulator. Moved out of the fixture range rather than dropping
# the reverses, which the app's own tests need.
PATROL_TEST_PORT="${PATROL_TEST_PORT:-8181}"
PATROL_APP_PORT="${PATROL_APP_PORT:-8182}"
PATROL_BIN="${PATROL_BIN:-$HOME/.pub-cache/bin/patrol}"
if [ "${#PATROL_TESTS[@]}" -gt 0 ]; then
  if [ -x "$PATROL_BIN" ]; then
    FLUTTER_DIR="$(dirname "$(command -v "$FLUTTER_BIN")")"
    for test_file in "${PATROL_TESTS[@]}"; do
      (
        cd "$FLUTTER_APP" &&
          PATH="$FLUTTER_DIR:$FLUTTER_DIR/cache/dart-sdk/bin:$PATH" \
            "$PATROL_BIN" test --target "$test_file" -d "$DEVICE" \
              --test-server-port "$PATROL_TEST_PORT" --app-server-port "$PATROL_APP_PORT" \
              "${TEST_ARGS[@]}"
      ) 2>&1 | tee -a "$RUN_DIR/test-patrol.log"
      rc=${PIPESTATUS[0]}
      [ "$rc" -eq 0 ] || TEST_RC=$rc
    done
  else
    echo "patrol CLI not found at $PATROL_BIN; ${#PATROL_TESTS[@]} native test(s) were NOT run" \
      | tee -a "$RUN_DIR/test-patrol.log"
    TEST_RC=2
  fi
fi
set -e

if [ "$PLATFORM" = android ]; then
  adb -s "$DEVICE" logcat -d -v threadtime >"$RUN_DIR/android-logcat.txt" 2>&1 || true
  adb -s "$DEVICE" shell dumpsys package com.jetsetslow.omniterm.app.flutter \
    >"$RUN_DIR/android-package.txt" 2>&1 || true
else
  xcrun simctl spawn "$DEVICE" log show --style compact --start "$START_ISO" \
    --predicate 'process == "Runner"' >"$RUN_DIR/ios-runner.log" 2>&1 || true
fi

# Warning-free is part of the migration gate. Keep the complete log and a short, searchable index.
# Both logs: a warning only Patrol's run produced is still a warning, and scanning one file was how
# the native tests could have stayed silent even once they started running.
touch "$RUN_DIR/test.log" "$RUN_DIR/test-patrol.log"
grep -Ein '(^|[[:space:]])warning:|^WARNING:|deprecated|RenderFlex overflow' \
  "$RUN_DIR/test.log" "$RUN_DIR/test-patrol.log" >"$RUN_DIR/warnings.log" || true

# Known upstream warnings, listed one per line and matched literally.
#
# An allowlist rather than --allow-warnings: that flag suppresses *everything*, and a gate routinely
# passed with a suppression flag has stopped being a gate. Each entry here is a warning this app
# cannot fix from its own source, so failing on it teaches the reader to ignore the gate — which is
# the actual danger. Anything not on this list still fails the run.
#
# 1. Flutter warns that four plugins apply the Kotlin Gradle Plugin and that future Flutter versions
#    will refuse to build them. True, actionable only by upgrading `flutter_file_dialog`,
#    `flutter_foreground_task`, `home_widget` and `patrol`, and tracked in the parity ledger. It is
#    printed during `assembleDebug`, so a run that reuses a cached APK never sees it — which is why
#    this gate's history is inconsistent rather than clean.
cat >"$RUN_DIR/warnings-allowed.txt" <<'ALLOWED'
plugins that apply Kotlin Gradle Plugin (KGP)
Future versions of Flutter will fail to build if your app uses plugins that apply KGP
ALLOWED

if [ -s "$RUN_DIR/warnings.log" ]; then
  grep -Fvf "$RUN_DIR/warnings-allowed.txt" "$RUN_DIR/warnings.log" \
    >"$RUN_DIR/warnings-unexpected.log" || true
else
  : >"$RUN_DIR/warnings-unexpected.log"
fi

WARNING_RC=0
if [ -s "$RUN_DIR/warnings-unexpected.log" ]; then
  echo "Unexpected warnings were captured in $RUN_DIR/warnings-unexpected.log" >&2
  $FAIL_ON_WARNING && WARNING_RC=3
elif [ -s "$RUN_DIR/warnings.log" ]; then
  echo "Only known upstream warnings ($(wc -l <"$RUN_DIR/warnings.log") lines); see $RUN_DIR/warnings.log" >&2
fi

{
  echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "test_exit_code=$TEST_RC"
  echo "warning_gate_exit_code=$WARNING_RC"
} >>"$RUN_DIR/metadata.txt"

if [ "$TEST_RC" -ne 0 ]; then
  echo "Device suite failed (exit $TEST_RC). Evidence: $RUN_DIR" >&2
  exit "$TEST_RC"
fi
if [ "$WARNING_RC" -ne 0 ]; then
  echo "Device suite passed but the warning gate failed. Evidence: $RUN_DIR" >&2
  exit "$WARNING_RC"
fi
echo "Device suite passed with no unexpected warnings. Evidence: $RUN_DIR"
