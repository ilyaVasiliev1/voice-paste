#!/bin/zsh
set -euo pipefail
source "${0:A:h}/lib/update-common.sh"

PROJECT_ROOT="${0:A:h:h}"
TARGET_APP="/Applications/VoicePaste.app"
SOURCE_APP="${1:-}"
DERIVED_DATA="${VOICEPASTE_INSTALL_DERIVED_DATA:-$HOME/Library/Caches/VoicePaste/Build/install}"

# A failed signing preflight must leave the installed app and its permissions intact.
if ! stable_signing_ready; then
    print -u2 "Локальная подпись не готова. Установленная копия и разрешения не изменены."
    exit 2
fi
if [[ -z "$SOURCE_APP" ]]; then
    SOURCE_APP=$(build_debug "$PROJECT_ROOT" "$DERIVED_DATA")
    python3 "$PROJECT_ROOT/scripts/build-info.py" stamp "$SOURCE_APP" "$PROJECT_ROOT" >/dev/null
fi
if [[ ! -d "$SOURCE_APP" ]]; then
    print -u2 "Сборка не найдена: $SOURCE_APP"
    exit 2
fi
FINGERPRINT=$(read_fingerprint "$SOURCE_APP")
if [[ -z "$FINGERPRINT" ]] || ! /usr/libexec/PlistBuddy -c 'Print :VoicePasteSourceDigest' "$SOURCE_APP/Contents/Info.plist" >/dev/null 2>&1; then
    print -u2 "У сборки нет точного отпечатка исходников. Пересоберите её перед установкой."
    exit 2
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/VoicePaste-install.XXXXXX")
INSTALLED=0
cleanup() {
    if (( ! INSTALLED )) && [[ -d "$STAGE/previous.app" ]]; then
        rm -rf "$TARGET_APP"
        mv "$STAGE/previous.app" "$TARGET_APP"
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT

ditto "$SOURCE_APP" "$STAGE/VoicePaste.app"
if ! security unlock-keychain -p "$(cat "$BUILD_KEYCHAIN_SECRET")" "$BUILD_KEYCHAIN" >/dev/null 2>&1; then
    print -u2 "Не удалось открыть служебную подпись. Установленная копия и разрешения не изменены."
    exit 3
fi
if ! codesign --force --deep --sign "$BUILD_IDENTITY" --keychain "$BUILD_KEYCHAIN" "$STAGE/VoicePaste.app" >/dev/null 2>&1; then
    print -u2 "Подписание не удалось. Установленная копия и разрешения не изменены."
    exit 3
fi
codesign --verify --deep --strict "$STAGE/VoicePaste.app"
if ! is_stably_signed "$STAGE/VoicePaste.app"; then
    print -u2 "Подпись не подтверждена; установленная копия не изменена."
    exit 3
fi
if pgrep -ix "$PROCESS_NAME" >/dev/null 2>&1; then
    print -u2 "Перед обновлением закройте VoicePaste. Установленная копия не изменена."
    exit 4
fi

[[ ! -d "$TARGET_APP" ]] || mv "$TARGET_APP" "$STAGE/previous.app"
mv "$STAGE/VoicePaste.app" "$TARGET_APP"
codesign --verify --deep --strict "$TARGET_APP"
python3 "$PROJECT_ROOT/scripts/build-info.py" receipt "$TARGET_APP"     "$HOME/Library/Application Support/VoicePaste/installations.json" >/dev/null
INSTALLED=1
print "Установлено: $TARGET_APP — $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist") ($( /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist")), $FINGERPRINT"
print "Модель, история и настройки сохранены. Разрешения автоматически не сбрасывались."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" >/dev/null 2>&1
open "$TARGET_APP"
