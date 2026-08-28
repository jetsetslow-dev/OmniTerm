#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export OMNITERM_TEST_FORWARD_STATE="$TEST_DIR/forwards"
export OMNITERM_TEST_REVERSE_STATE="$TEST_DIR/reverses"
export OMNITERM_TEST_ADB_LOG="$TEST_DIR/adb.log"
export OMNITERM_TEST_FLUTTER_APP="$TEST_DIR/flutter_app"

mkdir -p "$OMNITERM_TEST_FLUTTER_APP/integration_test"
printf 'void main() {}\n' >"$OMNITERM_TEST_FLUTTER_APP/integration_test/app_surface_stress_test.dart"

printf '%s\n' \
  'daily-device tcp:1111 tcp:2222' \
  'other-device tcp:7777 tcp:8888' >"$OMNITERM_TEST_FORWARD_STATE"
printf '%s\n' 'UsbFfs tcp:3333 tcp:4444' >"$OMNITERM_TEST_REVERSE_STATE"
: >"$OMNITERM_TEST_ADB_LOG"

adb() {
  printf '%q ' "$@" >>"$OMNITERM_TEST_ADB_LOG"
  printf '\n' >>"$OMNITERM_TEST_ADB_LOG"

  if [[ "${1:-}" == -s ]]; then shift 2; fi
  case "${1:-} ${2:-}" in
    'forward --list') cat "$OMNITERM_TEST_FORWARD_STATE" ;;
    'forward --remove')
      awk -v socket="${3:-}" '$2 != socket' "$OMNITERM_TEST_FORWARD_STATE" \
        >"$OMNITERM_TEST_FORWARD_STATE.next"
      mv "$OMNITERM_TEST_FORWARD_STATE.next" "$OMNITERM_TEST_FORWARD_STATE"
      ;;
    'reverse --list') cat "$OMNITERM_TEST_REVERSE_STATE" ;;
    'reverse --remove')
      awk -v socket="${3:-}" '$2 != socket' "$OMNITERM_TEST_REVERSE_STATE" \
        >"$OMNITERM_TEST_REVERSE_STATE.next"
      mv "$OMNITERM_TEST_REVERSE_STATE.next" "$OMNITERM_TEST_REVERSE_STATE"
      ;;
    'shell pm')
      if [[ "${4:-}" == com.jetsetslow.omniterm.app.flutter ]]; then
        printf 'package:/data/app/omniterm-flutter/base.apk\n'
      else
        return 1
      fi
      ;;
    'shell settings') printf '600000\n' ;;
    'shell wm') printf 'Physical size: 1080x2400\n' ;;
    'shell id') printf 'uid=2000(shell)\n' ;;
    'shell getprop'|'shell am'|'shell dumpsys'|'wait-for-device '|'logcat -d') ;;
    *) ;;
  esac
}

flutter() {
  case "${1:-}" in
    build)
      mkdir -p build/app/outputs/flutter-apk
      printf 'normal-main-apk\n' >build/app/outputs/flutter-apk/app-debug.apk
      ;;
    test)
      printf '%s\n' 'daily-device tcp:5555 tcp:6666' >>"$OMNITERM_TEST_FORWARD_STATE"
      printf '%s\n' 'UsbFfs tcp:8181 tcp:8181' >>"$OMNITERM_TEST_REVERSE_STATE"
      printf 'All tests passed!\n'
      ;;
    devices) printf '[{"id":"daily-device","targetPlatform":"android-arm64"}]\n' ;;
    *) printf 'fake Flutter\n' ;;
  esac
}

unzip() {
  printf 'file:///workspace/flutter_app/lib/main.dart\n'
}

export -f adb flutter unzip

FLUTTER_BIN=flutter OMNITERM_DEVICE_ARTIFACTS="$TEST_DIR/artifacts" \
  OMNITERM_FLUTTER_APP_ROOT="$OMNITERM_TEST_FLUTTER_APP" \
  "$ROOT/scripts/flutter-device-test.sh" \
    --device daily-device --platform android --profile surface --no-fixtures --preserve-device \
    >"$TEST_DIR/runner.log" 2>&1

expected_forward="$TEST_DIR/expected-forward"
expected_reverse="$TEST_DIR/expected-reverse"
printf '%s\n' \
  'daily-device tcp:1111 tcp:2222' \
  'other-device tcp:7777 tcp:8888' >"$expected_forward"
printf '%s\n' 'UsbFfs tcp:3333 tcp:4444' >"$expected_reverse"

cmp "$expected_forward" "$OMNITERM_TEST_FORWARD_STATE"
cmp "$expected_reverse" "$OMNITERM_TEST_REVERSE_STATE"
grep -Fq -- 'forward --remove tcp:5555' "$OMNITERM_TEST_ADB_LOG"
grep -Fq -- 'reverse --remove tcp:8181' "$OMNITERM_TEST_ADB_LOG"
grep -Eq -- '-s daily-device install -r .*/app-debug\.apk' "$OMNITERM_TEST_ADB_LOG"
grep -Fq -- '-s daily-device shell am force-stop com.jetsetslow.omniterm.app.flutter' \
  "$OMNITERM_TEST_ADB_LOG"
if grep -Eq 'logcat -c|settings put|KEYCODE_WAKEUP|dismiss-keyguard|--remove-all' \
  "$OMNITERM_TEST_ADB_LOG"; then
  echo 'preserve mode changed global device state' >&2
  cat "$OMNITERM_TEST_ADB_LOG" >&2
  exit 1
fi

echo 'Flutter physical-device preservation tests passed'
