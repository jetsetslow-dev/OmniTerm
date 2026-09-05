#!/usr/bin/env bash
# Run the repeatable Flutter device matrix and retain enough evidence to diagnose a failure on a
# different Android release or an iOS simulator later.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER_APP="${OMNITERM_FLUTTER_APP_ROOT:-$ROOT/flutter_app}"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
PROFILE="core"
PLATFORM="auto"
DEVICE=""
ARTIFACT_ROOT="${OMNITERM_DEVICE_ARTIFACTS:-$ROOT/artifacts/device-tests}"
USE_FIXTURES=true
FAIL_ON_WARNING=true
PRESERVE_DEVICE=false
PLAIN_TRANSPORT_ATTEMPTS=2
PLAIN_TEST_TIMEOUT="${OMNITERM_PLAIN_TEST_TIMEOUT:-12m}"
ANDROID_PREVIOUS_STAY=""
ANDROID_STALE_FORWARD_COUNT=0
ANDROID_BASELINE_FORWARDS_FILE=""
ANDROID_BASELINE_REVERSES_FILE=""
ANDROID_MAIN_APP_TEMP_DIR=""
ANDROID_MAIN_APP_APK=""

remove_android_test_forwards() {
  if [ "$PLATFORM" != android ]; then return; fi
  if [ "$PRESERVE_DEVICE" != true ]; then
    adb -s "$DEVICE" forward --remove-all >/dev/null 2>&1 || true
    return
  fi
  if [ -z "$ANDROID_BASELINE_FORWARDS_FILE" ] || [ ! -f "$ANDROID_BASELINE_FORWARDS_FILE" ]; then
    return
  fi

  local serial local_socket remote_socket
  while read -r serial local_socket remote_socket; do
    [ "$serial" = "$DEVICE" ] || continue
    if ! grep -Fqx "$serial $local_socket $remote_socket" "$ANDROID_BASELINE_FORWARDS_FILE"; then
      adb -s "$DEVICE" forward --remove "$local_socket" >/dev/null 2>&1 || true
    fi
  done < <(adb -s "$DEVICE" forward --list 2>/dev/null)
}

remove_android_test_reverses() {
  if [ "$PLATFORM" != android ] || [ "$PRESERVE_DEVICE" != true ]; then return; fi
  if [ -z "$ANDROID_BASELINE_REVERSES_FILE" ] || [ ! -f "$ANDROID_BASELINE_REVERSES_FILE" ]; then
    return
  fi

  local transport device_socket host_socket
  while read -r transport device_socket host_socket; do
    # Unlike `adb forward --list`, `adb -s <serial> reverse --list` identifies USB transports as
    # `UsbFfs` rather than echoing the selected serial. The `-s` already scopes these rows to the
    # requested device, so compare the socket pair and treat the transport label as informational.
    if ! grep -Fqx "$device_socket $host_socket" "$ANDROID_BASELINE_REVERSES_FILE"; then
      adb -s "$DEVICE" reverse --remove "$device_socket" >/dev/null 2>&1 || true
    fi
  done < <(adb -s "$DEVICE" reverse --list 2>/dev/null)
}

restore_android_device() {
  if [ "$PLATFORM" != android ]; then return; fi
  # Flutter allocates an adb forward for every test APK it starts. Interrupted runs can leave those
  # mappings behind; after enough accumulate, a later APK reaches the Dart VM but the host tool
  # never attaches and Android leaves the launch splash on screen indefinitely. This runner owns
  # the selected device for its duration, so clean up the forwards it may have allocated.
  remove_android_test_forwards
  remove_android_test_reverses
  if [ "$PRESERVE_DEVICE" = true ]; then
    # A Flutter integration test compiles its test entrypoint into the ordinary app-debug.apk path.
    # Once the host-side harness and adb forward disappear, that APK waits for localhost forever
    # and looks like a black-screen app. Restore the independently snapshotted lib/main.dart build,
    # never the mutable Gradle output the last test happened to leave behind.
    if [ -n "$ANDROID_MAIN_APP_APK" ] && [ -f "$ANDROID_MAIN_APP_APK" ]; then
      adb -s "$DEVICE" install -r "$ANDROID_MAIN_APP_APK" >/dev/null 2>&1 ||
        echo "warning: could not restore the normal OmniTerm Flutter debug APK" >&2
      adb -s "$DEVICE" shell am force-stop com.jetsetslow.omniterm.app.flutter \
        >/dev/null 2>&1 || true
    fi
    if [ -n "$ANDROID_MAIN_APP_TEMP_DIR" ]; then
      rm -rf -- "$ANDROID_MAIN_APP_TEMP_DIR"
    fi
    return
  fi
  if [ -z "$ANDROID_PREVIOUS_STAY" ]; then return; fi
  adb -s "$DEVICE" shell settings put global stay_on_while_plugged_in \
    "$ANDROID_PREVIOUS_STAY" >/dev/null 2>&1 || true
  if [ "$(adb -s "$DEVICE" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')" != "$ANDROID_PREVIOUS_STAY" ]; then
    adb -s "$DEVICE" shell su -c \
      "settings put global stay_on_while_plugged_in $ANDROID_PREVIOUS_STAY" >/dev/null 2>&1 || true
  fi
}
trap restore_android_device EXIT

snapshot_android_main_app() {
  if [ "$PLATFORM" != android ] || [ "$PRESERVE_DEVICE" != true ]; then return; fi

  # Preserve the user's side-by-side Flutter installation only when it existed on entry. A test on
  # an otherwise clean device should leave that device clean, not install a development app as a
  # side effect.
  if ! adb -s "$DEVICE" shell pm path com.jetsetslow.omniterm.app.flutter 2>/dev/null |
    grep -q '^package:'; then
    return
  fi

  ANDROID_MAIN_APP_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/omniterm-main-apk.XXXXXXXX")"
  echo "Building a normal Flutter entrypoint to restore after the device suite"
  (
    cd "$FLUTTER_APP"
    "$FLUTTER_BIN" build apk --debug --target=lib/main.dart
  ) >"$RUN_DIR/main-app-restore-build.log" 2>&1

  local built_apk="$FLUTTER_APP/build/app/outputs/flutter-apk/app-debug.apk"
  [ -s "$built_apk" ] || {
    echo "normal Flutter debug APK was not produced at $built_apk" >&2
    return 1
  }
  cp "$built_apk" "$ANDROID_MAIN_APP_TEMP_DIR/app-debug.apk"
  unzip -p "$ANDROID_MAIN_APP_TEMP_DIR/app-debug.apk" assets/flutter_assets/kernel_blob.bin \
    >"$ANDROID_MAIN_APP_TEMP_DIR/kernel_blob.bin"
  if grep -aEq 'patrol_test/test_bundle\.dart|localhost:8181' \
    "$ANDROID_MAIN_APP_TEMP_DIR/kernel_blob.bin"; then
    echo "refusing to restore an APK that contains the Patrol test entrypoint" >&2
    return 1
  fi
  ANDROID_MAIN_APP_APK="$ANDROID_MAIN_APP_TEMP_DIR/app-debug.apk"
}

# Each integration-test entrypoint gets its own APK/harness connection. Flutter normally tears the
# previous pair down before starting the next one, but Android's package manager can transiently
# return DELETE_FAILED_INTERNAL_ERROR. Flutter then carries on, and the next APK launches while the
# host is still attached to a stale forwarded VM-service port; the run sits on that launch until
# the outer CI timeout. Own the boundary explicitly, retry the failed uninstall, and never let one
# entrypoint's transport leak into the next.
reset_android_flutter_harness() {
  if [ "$PLATFORM" != android ]; then return 0; fi

  adb -s "$DEVICE" wait-for-device
  remove_android_test_forwards

  local package attempt removed
  for package in \
    com.jetsetslow.omniterm \
    com.jetsetslow.omniterm.app.flutter.test \
    com.jetsetslow.omniterm.app.flutter; do
    adb -s "$DEVICE" shell am force-stop "$package" >/dev/null 2>&1 || true
    if ! adb -s "$DEVICE" shell pm path "$package" 2>/dev/null | grep -q '^package:'; then
      continue
    fi

    removed=false
    for attempt in 1 2 3; do
      if adb -s "$DEVICE" uninstall "$package" >/dev/null 2>&1; then
        removed=true
        break
      fi
      adb -s "$DEVICE" shell am force-stop "$package" >/dev/null 2>&1 || true
      sleep 1
    done
    if [ "$removed" != true ]; then
      echo "could not remove stale Flutter test package $package after 3 attempts" >&2
      return 1
    fi
  done
}

recover_android_flutter_transport() {
  if [ "$PLATFORM" != android ] || [ "$PRESERVE_DEVICE" = true ] || [[ "$DEVICE" != emulator-* ]]; then
    return 1
  fi

  echo "Rebooting the disposable emulator after Flutter test transport failed before tests started"
  adb -s "$DEVICE" reboot >/dev/null
  adb -s "$DEVICE" wait-for-device

  local attempt boot_completed=false
  for attempt in $(seq 1 180); do
    if [ "$(adb -s "$DEVICE" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then
      boot_completed=true
      break
    fi
    sleep 1
  done
  if [ "$boot_completed" != true ]; then
    echo "disposable emulator did not finish rebooting after Flutter test transport failure" >&2
    return 1
  fi

  adb -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  adb -s "$DEVICE" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  remove_android_test_forwards
}

is_android_flutter_transport_failure() {
  local rc="$1"
  local attempt_log="$2"

  if grep -Fq 'Failed to start Dart Development Service' "$attempt_log"; then
    return 0
  fi

  # A hosted emulator can also accept the APK and then never expose the VM service. GNU timeout
  # interrupts Flutter before its own DDS error is emitted; Flutter's exact terminal result is
  # then exit 124 plus "No tests ran." This is still a pre-test transport failure, not an app
  # assertion. Require both signals so an ordinary test timeout or failure is never retried.
  [ "$rc" -eq 124 ] && grep -Fq 'No tests ran.' "$attempt_log"
}

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
  --preserve-device             Preserve system logs, global settings, lock state, and pre-existing
                                adb mappings on a daily-use physical device
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
    --preserve-device) PRESERVE_DEVICE=true; shift ;;
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
  echo "preserve_device=$PRESERVE_DEVICE"
} >"$RUN_DIR/metadata.txt"
git -C "$ROOT" status --short >"$RUN_DIR/git-status.txt" 2>&1 || true
"$FLUTTER_BIN" --version >"$RUN_DIR/flutter-version.txt" 2>&1 || true
"$FLUTTER_BIN" doctor -v >"$RUN_DIR/flutter-doctor.txt" 2>&1 || true
"$FLUTTER_BIN" devices --machine >"$RUN_DIR/flutter-devices.json" 2>&1 || true

if [ "$PLATFORM" = android ]; then
  command -v adb >/dev/null || { echo "adb is required for Android" >&2; exit 2; }
  adb -s "$DEVICE" wait-for-device
  ANDROID_STALE_FORWARD_COUNT="$(
    adb -s "$DEVICE" forward --list 2>/dev/null |
      awk -v device="$DEVICE" '$1 == device { count++ } END { print count + 0 }'
  )"
  if [ "$PRESERVE_DEVICE" = true ]; then
    ANDROID_BASELINE_FORWARDS_FILE="$RUN_DIR/android-forwards-before.txt"
    ANDROID_BASELINE_REVERSES_FILE="$RUN_DIR/android-reverses-before.txt"
    adb -s "$DEVICE" forward --list 2>/dev/null |
      awk -v device="$DEVICE" '$1 == device { print $1, $2, $3 }' \
      >"$ANDROID_BASELINE_FORWARDS_FILE"
    adb -s "$DEVICE" reverse --list 2>/dev/null |
      awk '{ print $2, $3 }' \
      >"$ANDROID_BASELINE_REVERSES_FILE"
  else
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
  fi
  remove_android_test_forwards
  adb -s "$DEVICE" shell getprop >"$RUN_DIR/android-getprop.txt" 2>&1 || true
  {
    adb -s "$DEVICE" shell wm size
    adb -s "$DEVICE" shell wm density
    adb -s "$DEVICE" shell settings get system font_scale
    adb -s "$DEVICE" shell settings get system screen_off_timeout
    echo "stale_adb_forwards_removed=$ANDROID_STALE_FORWARD_COUNT"
    echo "stay_on_while_plugged_in_before=$ANDROID_PREVIOUS_STAY"
    echo "stay_on_while_plugged_in_during=$(adb -s "$DEVICE" shell settings get global stay_on_while_plugged_in 2>/dev/null | tr -d '\r')"
    adb -s "$DEVICE" shell id
  } >"$RUN_DIR/android-display-and-access.txt" 2>&1 || true
  if [ "$PRESERVE_DEVICE" != true ]; then
    adb -s "$DEVICE" logcat -c >/dev/null 2>&1 || true
  fi
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
  snapshot_android_main_app
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
# Hosted Android runners can leave the emulator's VM-service transport half-open before DDS starts.
# Retrying against that same device state can hang after APK installation until the outer job
# timeout. Keep every entrypoint bounded and reboot only the repository-owned disposable emulator
# before the one permitted transport retry. App assertions and physical devices are never retried.
if [ "${#PLAIN_TESTS[@]}" -gt 0 ]; then
  for test_file in "${PLAIN_TESTS[@]}"; do
    for attempt in $(seq 1 "$PLAIN_TRANSPORT_ATTEMPTS"); do
      reset_android_flutter_harness
      rc=$?
      if [ "$rc" -ne 0 ]; then
        TEST_RC=$rc
        break
      fi

      safe_test_name="$(printf '%s' "$test_file" | tr -c '[:alnum:]_.-' '_')"
      attempt_log="$RUN_DIR/plain-${safe_test_name}-attempt-${attempt}.log"
      if [ "$PLATFORM" = android ] && [ "$PLAIN_TEST_TIMEOUT" != 0 ] && command -v timeout >/dev/null; then
        (
          cd "$FLUTTER_APP" &&
            timeout --foreground --signal=INT --kill-after=30s "$PLAIN_TEST_TIMEOUT" \
              "$FLUTTER_BIN" test "$test_file" -d "$DEVICE" --reporter expanded \
                "${TEST_ARGS[@]}"
        ) 2>&1 | tee -a "$RUN_DIR/test.log" "$attempt_log"
      else
        (
          cd "$FLUTTER_APP" &&
            "$FLUTTER_BIN" test "$test_file" -d "$DEVICE" --reporter expanded "${TEST_ARGS[@]}"
        ) 2>&1 | tee -a "$RUN_DIR/test.log" "$attempt_log"
      fi
      rc=${PIPESTATUS[0]}
      reset_android_flutter_harness
      cleanup_rc=$?
      if [ "$rc" -eq 0 ]; then
        if [ "$cleanup_rc" -ne 0 ]; then
          TEST_RC=$cleanup_rc
        fi
        break
      fi

      if [ "$cleanup_rc" -eq 0 ] && [ "$attempt" -lt "$PLAIN_TRANSPORT_ATTEMPTS" ] &&
        is_android_flutter_transport_failure "$rc" "$attempt_log" &&
        recover_android_flutter_transport; then
        echo "Retrying $test_file after rebooting the disposable emulator ($attempt/$PLAIN_TRANSPORT_ATTEMPTS)" \
          | tee -a "$RUN_DIR/test.log"
        continue
      fi

      TEST_RC=$rc
      break
    done
    if [ "$TEST_RC" -ne 0 ]; then
      break
    fi
  done
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
if [ "$TEST_RC" -eq 0 ] && [ "${#PATROL_TESTS[@]}" -gt 0 ]; then
  if [ -x "$PATROL_BIN" ]; then
    FLUTTER_DIR="$(dirname "$(command -v "$FLUTTER_BIN")")"
    for test_file in "${PATROL_TESTS[@]}"; do
      reset_android_flutter_harness
      rc=$?
      if [ "$rc" -ne 0 ]; then
        TEST_RC=$rc
        break
      fi
      (
        cd "$FLUTTER_APP" &&
          PATH="$FLUTTER_DIR:$FLUTTER_DIR/cache/dart-sdk/bin:$PATH" \
            "$PATROL_BIN" test --target "$test_file" -d "$DEVICE" \
              --test-server-port "$PATROL_TEST_PORT" --app-server-port "$PATROL_APP_PORT" \
              "${TEST_ARGS[@]}"
      ) 2>&1 | tee -a "$RUN_DIR/test-patrol.log"
      rc=${PIPESTATUS[0]}
      reset_android_flutter_harness
      cleanup_rc=$?
      if [ "$rc" -ne 0 ]; then
        TEST_RC=$rc
        break
      fi
      if [ "$cleanup_rc" -ne 0 ]; then
        TEST_RC=$cleanup_rc
        break
      fi
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
# 2. The Play Store build's current `google_mobile_ads` Android implementation calls APIs deprecated
#    by its own transitive AndroidX/Play Services versions, and some plugins still compile Java 8
#    sources. Keep these messages exact: warnings from OmniTerm source or a different API must still
#    fail the run. Dependency upgrades can remove entries when their upstream fixes land.
cat >"$RUN_DIR/warnings-allowed.txt" <<'ALLOWED'
plugins that apply Kotlin Gradle Plugin (KGP)
Future versions of Flutter will fail to build if your app uses plugins that apply KGP
getWebView(FlutterEngine,long) in WebViewFlutterAndroidExternalApi has been deprecated
setTagForChildDirectedTreatment(int) in Builder has been deprecated
setTagForUnderAgeOfConsent(int) in Builder has been deprecated
TAG_FOR_CHILD_DIRECTED_TREATMENT_UNSPECIFIED in RequestConfiguration has been deprecated
TAG_FOR_UNDER_AGE_OF_CONSENT_UNSPECIFIED in RequestConfiguration has been deprecated
warning: [options] source value 8 is obsolete and will be removed in a future release
warning: [options] target value 8 is obsolete and will be removed in a future release
warning: [options] To suppress warnings about obsolete options, use -Xlint:-options.
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
