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
mkdir -p "$DMG_ROOT/.background"
ditto "$APP_PATH" "$DMG_ROOT/VoicePaste.app"
ln -s /Applications "$DMG_ROOT/Applications"
swift "$PROJECT_ROOT/scripts/make-dmg-background.swift" \
  "$DMG_ROOT/.background/background.tiff" >/dev/null

# The installer window is laid out explicitly. `hdiutil create` alone produces
# an unstyled Finder window — whatever list/icon view and window size the
# person happens to have as their default — which is the difference between an
# installer that looks made and one that looks emitted.
#
# Layout can only be applied to a *writable*, mounted image, so the DMG is
# built read/write, dressed through Finder, then converted to the compressed
# read-only artifact that ships.
VOLUME_NAME="VoicePaste"
RW_DMG="$DERIVED_DATA/VoicePaste-rw.dmg"
APP_MEGABYTES=$(du -sm "$APP_PATH" | cut -f1)
rm -f "$RW_DMG"
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$DMG_ROOT" \
  -fs HFS+ -format UDRW -size $((APP_MEGABYTES + 48))m -ov "$RW_DMG"

# Must live under /Volumes: Finder addresses a disk by name and cannot see one
# mounted anywhere else, which is why a custom mountpoint fails with -1728.
MOUNT_POINT="/Volumes/$VOLUME_NAME"
if [[ -d "$MOUNT_POINT" ]]; then
  hdiutil detach "$MOUNT_POINT" -quiet -force || true
fi
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_POINT" -quiet

# Icon centres must match `make-dmg-background.swift`, which draws the arrow
# between exactly these two points.
# Ordering here is not stylistic, and the missing `close` is deliberate.
# Closing the window makes Finder rewrite `.DS_Store` with defaults: measured
# directly, the styled record shrank from 10244 bytes to 6148 on unmount, and
# the shipped installer opened with default icon size and no background even
# though every option had been applied. The window is therefore left open and
# the volume detached under it, after `update` plus a pause long enough for the
# record to reach the image.
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {240, 140, 880, 560}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to POSIX file "$MOUNT_POINT/.background/background.tiff"
    set position of item "VoicePaste.app" of container window to {160, 200}
    set position of item "Applications" of container window to {480, 200}
    update without registering applications
    delay 3
  end tell
end tell
APPLESCRIPT

sync
sleep 3
hdiutil detach "$MOUNT_POINT" -quiet -force

rm -f "$OUTPUT_DIR/$ARTIFACT_NAME"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 \
  -o "$OUTPUT_DIR/$ARTIFACT_NAME"
rm -f "$RW_DMG"

if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" != "-" ]]; then
  xcrun notarytool submit "$OUTPUT_DIR/$ARTIFACT_NAME" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT_DIR/$ARTIFACT_NAME"
  xcrun stapler validate "$OUTPUT_DIR/$ARTIFACT_NAME"
fi

print "$OUTPUT_DIR/$ARTIFACT_NAME"
