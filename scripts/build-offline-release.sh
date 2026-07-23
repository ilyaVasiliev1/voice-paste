#!/bin/zsh
set -euo pipefail

# Builds the only distributable VoicePaste flavor: model + tokenizer are
# embedded before the final signature, so runtime never needs the network.
#
# Required:
#   MODEL_SOURCE=/path/to/VoicePaste/Models
# Optional professional release:
#   SIGN_IDENTITY="Developer ID Application: …"
#   SIGN_KEYCHAIN=/path/to/signing.keychain-db
#   NOTARY_PROFILE=voicepaste-notary
#
# Without Developer ID the script intentionally produces a clearly named
# development artifact. It is useful locally but does not satisfy AT-103.

PROJECT_ROOT="${0:A:h:h}"
MODEL_SOURCE="${MODEL_SOURCE:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
DERIVED_DATA="$PROJECT_ROOT/.tmp/offline-release"
OUTPUT_DIR="$PROJECT_ROOT/.tmp/release-artifacts"
APP_PATH="$DERIVED_DATA/Build/Products/Release/VoicePaste.app"

if [[ -z "$MODEL_SOURCE" || ! -d "$MODEL_SOURCE" ]]; then
  print -u2 "MODEL_SOURCE must point to a prepared VoicePaste Models directory."
  exit 2
fi

MODEL_MIL_COUNT=$(find "$MODEL_SOURCE" -type f -name model.mil | wc -l | tr -d ' ')
MODEL_BYTES=$(du -sk "$MODEL_SOURCE" | awk '{ print $1 * 1024 }')
TOKENIZER_COUNT=$(find "$MODEL_SOURCE" -type f -name tokenizer.json | wc -l | tr -d ' ')
if (( MODEL_MIL_COUNT < 3 || MODEL_BYTES < 52428800 || TOKENIZER_COUNT < 1 )); then
  print -u2 "Model verification failed: need 3 model.mil files, >=50 MB, and tokenizer.json."
  exit 3
fi

mkdir -p "$OUTPUT_DIR"

xcodebuild \
  -project "$PROJECT_ROOT/VoicePaste.xcodeproj" \
  -scheme VoicePaste \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -jobs 2 \
  build CODE_SIGNING_ALLOWED=NO

rm -rf "$APP_PATH/Contents/Resources/VoicePasteModels"
ditto "$MODEL_SOURCE" "$APP_PATH/Contents/Resources/VoicePasteModels"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  # Local ad-hoc builds cannot be notarized. Keep Hardened Runtime disabled so
  # the microphone follows the ordinary TCC path used by development builds.
  codesign --force --deep --sign - "$APP_PATH"
  ARTIFACT_NAME="VoicePaste-development-offline.dmg"
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
    # A stable local/self-signed identity preserves the designated requirement,
    # but it cannot be notarized. Hardened Runtime remains off so microphone TCC
    # behaves like the already verified local development installation.
    ARTIFACT_NAME="VoicePaste-development-offline.dmg"
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
