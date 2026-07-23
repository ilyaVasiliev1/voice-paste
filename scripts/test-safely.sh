#!/bin/zsh
set -euo pipefail

# The only supported entry point for VoicePaste tests on a developer's daily
# Mac. It prevents an installed app and an XCTest host from running together.

PROJECT_ROOT="${0:A:h:h}"
DERIVED_DATA="$PROJECT_ROOT/.tmp/safe-tests"
APP_PROCESS_NAME="VoicePaste"
TEST_APP_EXECUTABLE="$DERIVED_DATA/Build/Products/Debug/VoicePaste.app/Contents/MacOS/VoicePaste"

function matching_processes() {
  local pattern="$1"
  pgrep -fl "$pattern" 2>/dev/null || true
}

function stop_voicepaste() {
  local pids
  pids="$(pgrep -x "$APP_PROCESS_NAME" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    print "Closing running VoicePaste before tests: ${pids//$'\n'/, }"
    print -r -- "$pids" | while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done
  fi

  for _ in {1..30}; do
    pgrep -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || return 0
    sleep 0.1
  done

  print -u2 "VoicePaste did not quit. Close it manually; tests were not started."
  exit 3
}

function assert_clean_test_environment() {
  local stale
  stale="$(matching_processes '(^|/)(xctest|VoicePasteTests)( |$)|xcodebuild.*VoicePaste')"
  if [[ -n "$stale" ]]; then
    print -u2 "A previous VoicePaste build/test process is still running:"
    print -u2 -r -- "$stale"
    print -u2 "Tests were not started. Stop the stale process and retry."
    exit 4
  fi
}

function cleanup_test_host() {
  local pids
  pids="$(pgrep -f "$TEST_APP_EXECUTABLE" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    print -r -- "$pids" | while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done
  fi
}

stop_voicepaste
assert_clean_test_environment
trap cleanup_test_host EXIT INT TERM

cd "$PROJECT_ROOT"
VOICEPASTE_TEST_HOST=1 nice -n 15 xcodebuild \
  -project VoicePaste.xcodeproj \
  -scheme VoicePaste \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -jobs 2 \
  test "$@"
