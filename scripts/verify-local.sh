#!/bin/zsh
set -euo pipefail
source "${0:A:h}/lib/update-common.sh"
APP="/Applications/VoicePaste.app"
[[ -d "$APP" ]] || { print -u2 "VoicePaste не установлен"; exit 1; }
codesign --verify --deep --strict "$APP"
ACTUAL=$(read_fingerprint "$APP")
if [[ -z "$ACTUAL" || ( -n "${1:-}" && "$ACTUAL" != "$1" ) ]]; then
    print -u2 "Отпечаток установленной сборки не совпадает"; exit 1
fi
[[ "$(read_bundle_id "$APP")" == "$BUNDLE_ID" ]] || exit 1
COUNT=$(pgrep -f '^/Applications/VoicePaste.app/Contents/MacOS/VoicePaste($| )' | wc -l | tr -d ' ')
[[ "$COUNT" == 1 ]] || { print -u2 "Ожидался один запущенный VoicePaste, найдено: $COUNT"; exit 1; }
print "OK: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($( /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")), $ACTUAL — одна установленная и запущенная копия"
