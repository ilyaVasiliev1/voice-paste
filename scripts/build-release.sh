#!/bin/zsh
set -euo pipefail

# Builds the distributable VoicePaste application without a speech model.
# The model is installed once by the explicit onboarding step into
# ~/Library/Application Support/VoicePaste/Models and survives app updates.
#
# Optional professional release:
#   SIGN_IDENTITY="Developer ID Application: …"
#   SIGN_KEYCHAIN=/path/to/signing.keychain-db
#   NOTARY_PROFILE=voicepaste-notary
#
# Without Developer ID the script intentionally produces a development DMG.
# It is suitable for local/friend installation through Privacy & Security but
# does not satisfy notarized public distribution.

PROJECT_ROOT="${0:A:h:h}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DERIVED_DATA="$PROJECT_ROOT/.tmp/release"
OUTPUT_DIR="$PROJECT_ROOT/.tmp/release-artifacts"
APP_PATH="$DERIVED_DATA/Build/Products/Release/VoicePaste.app"
PACKAGE_CACHE="${SOURCE_PACKAGES_DIR:-$PROJECT_ROOT/.tmp/safe-tests/SourcePackages}"
BUILD_CACHE="$PROJECT_ROOT/.tmp/release-caches"

mkdir -p "$OUTPUT_DIR" "$BUILD_CACHE/clang" "$BUILD_CACHE/swiftpm" "$BUILD_CACHE/xdg" "$BUILD_CACHE/user-home"
# Foundation-backed SwiftPM manifest caches otherwise escape to ~/Library.
# CFFIXED_USER_HOME redirects only this build process's Apple-framework caches;
# the actual user HOME, app data and signing inputs are untouched.

XCODEBUILD_ARGS=(
  -project "$PROJECT_ROOT/VoicePaste.xcodeproj" \
  -scheme VoicePaste \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -packageCachePath "$BUILD_CACHE/swiftpm" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  -jobs 2 \
  build CODE_SIGNING_ALLOWED=NO
)

# Reuse a verified local SPM checkout when available. This keeps release builds
# reproducible in an offline environment and avoids resolving the same pinned
# Package.resolved graph twice. A clean developer Mac can omit the cache and let
# Xcode fetch build-time dependencies normally; they are never runtime traffic.
if [[ -d "$PACKAGE_CACHE/checkouts" ]]; then
  XCODEBUILD_ARGS=(
    -clonedSourcePackagesDirPath "$PACKAGE_CACHE"
    "${XCODEBUILD_ARGS[@]}"
  )
fi

CLANG_MODULE_CACHE_PATH="$BUILD_CACHE/clang" \
SWIFT_MODULE_CACHE_PATH="$BUILD_CACHE/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_CACHE/clang" \
XDG_CACHE_HOME="$BUILD_CACHE/xdg" \
CFFIXED_USER_HOME="$BUILD_CACHE/user-home" \
xcodebuild "${XCODEBUILD_ARGS[@]}"

# A model in the app bundle is a release failure, not something the script
# should silently ship. This guards against stale build resources.
if [[ -e "$APP_PATH/Contents/Resources/VoicePasteModels" ]]; then
  print -u2 "Release rejected: VoicePasteModels must not be embedded in VoicePaste.app."
  exit 3
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP_PATH"
  ARTIFACT_NAME="VoicePaste-development.dmg"
else
  SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY")
  if [[ -n "$SIGN_KEYCHAIN" ]]; then
    SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
  fi
  if [[ "$SIGN_IDENTITY" == "Developer ID Application:"* ]]; then
    SIGN_ARGS+=(
      --options runtime --timestamp
      --entitlements "$PROJECT_ROOT/VoicePaste/Resources/VoicePaste.entitlements"
    )
    ARTIFACT_NAME="VoicePaste.dmg"
  else
    ARTIFACT_NAME="VoicePaste-development.dmg"
  fi
  codesign "${SIGN_ARGS[@]}" "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

DMG_ROOT="$DERIVED_DATA/dmg-root"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/VoicePaste.app"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$OUTPUT_DIR/$ARTIFACT_NAME"
hdiutil create -quiet -volname VoicePaste -srcfolder "$DMG_ROOT" \
  -ov -format UDZO "$OUTPUT_DIR/$ARTIFACT_NAME"

if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" != "-" ]]; then
  xcrun notarytool submit "$OUTPUT_DIR/$ARTIFACT_NAME" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT_DIR/$ARTIFACT_NAME"
  xcrun stapler validate "$OUTPUT_DIR/$ARTIFACT_NAME"
fi

print "$OUTPUT_DIR/$ARTIFACT_NAME"
