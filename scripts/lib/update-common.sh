#!/bin/zsh

BUNDLE_ID="com.ilyavasiliev.voicepaste"
PROCESS_NAME="voicepaste"
BUILD_KEYCHAIN="${VOICEPASTE_BUILD_KEYCHAIN:-$HOME/Library/Keychains/voicepaste-local-signing.keychain-db}"
BUILD_IDENTITY="VoicePaste Local Build"
BUILD_KEYCHAIN_SECRET="${VOICEPASTE_BUILD_KEYCHAIN_SECRET:-$HOME/.depo-lab/secrets/VOICEPASTE_BUILD_KEYCHAIN_PASSWORD_FILE}"

fail_loudly() {
    local exit_code=$?
    local line="${1:-?}"
    print -u2 ""
    print -u2 "${ZSH_ARGZERO:t}: отказ на строке ${line} (код ${exit_code}), скрипт остановлен."
    print -u2 "FIX: причину обычно уже назвала команда в выводе выше; почини её и запусти скрипт заново."
    exit "$exit_code"
}

read_fingerprint() {
    local plist="$1/Contents/Info.plist"
    [[ -f "$plist" ]] || return 0
    /usr/libexec/PlistBuddy -c "Print :VoicePasteBuildFingerprint" "$plist" 2>/dev/null || true
}

read_bundle_id() {
    local plist="$1/Contents/Info.plist"
    [[ -f "$plist" ]] || return 0
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true
}

build_debug() {
    local project_root="$1" derived_data="$2"
    local source_packages="${SOURCE_PACKAGES_DIR:-$HOME/Library/Caches/VoicePaste/SourcePackages}"
    xcodebuild \
        -project "$project_root/VoicePaste.xcodeproj" -scheme VoicePaste \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$source_packages" \
        -disableAutomaticPackageResolution -jobs 2 \
        build CODE_SIGNING_ALLOWED=NO >&2
    print -r -- "$derived_data/Build/Products/Debug/VoicePaste.app"
}

stable_signing_ready() {
    [[ -f "$BUILD_KEYCHAIN" && -f "$BUILD_KEYCHAIN_SECRET" ]]
}

is_stably_signed() {
    codesign -dr - "$1" 2>&1 | grep -q 'certificate root = H"'
}

trap 'fail_loudly $LINENO' ERR
