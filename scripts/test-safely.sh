#!/bin/zsh
set -euo pipefail

# Headless unit gate for a developer's daily Mac. The XCTest host detects
# VOICEPASTE_TEST_HOST and disables activation, global hotkeys, user storage
# and the single-instance handoff, so an installed VoicePaste may keep running.

PROJECT_ROOT="${0:A:h:h}"
DERIVED_DATA="$PROJECT_ROOT/.tmp/safe-tests"
CACHE_ROOT="$PROJECT_ROOT/.tmp/test-caches"
TEST_APP_EXECUTABLE="$DERIVED_DATA/Build/Products/Debug/VoicePaste.app/Contents/MacOS/VoicePaste"

function matching_processes() {
  local pattern="$1"
  pgrep -fl "$pattern" 2>/dev/null || true
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

assert_clean_test_environment
trap cleanup_test_host EXIT INT TERM

cd "$PROJECT_ROOT"
mkdir -p "$CACHE_ROOT/clang" "$CACHE_ROOT/swiftpm" "$CACHE_ROOT/xdg"
VOICEPASTE_TEST_HOST=1 \
CLANG_MODULE_CACHE_PATH="$CACHE_ROOT/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_ROOT/swiftpm" \
XDG_CACHE_HOME="$CACHE_ROOT/xdg" \
nice -n 15 xcodebuild \
  -project VoicePaste.xcodeproj \
  -scheme VoicePaste \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$DERIVED_DATA/SourcePackages" \
  -packageCachePath "$CACHE_ROOT/packages" \
  -disablePackageRepositoryCache \
  -disableAutomaticPackageResolution \
  -jobs 2 \
  test "$@"
