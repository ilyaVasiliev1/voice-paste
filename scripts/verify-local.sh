#!/bin/zsh
set -euo pipefail

# Отвечает нулём ровно тогда, когда установленная в /Applications копия
# VoicePaste собрана из заданного отпечатка, несёт объявленный идентификатор
# пакета и запущена и отвечает. Расхождение в любом из трёх условий — явный
# отказ с причиной и ненулевым кодом; «команда не упала» здесь не считается
# «установлено» (spec/logic.md#L-019).
#
#   scripts/verify-local.sh <отпечаток>
#
# Отпечаток текущего дерева даёт тот же расчёт, что делает install-local.sh:
#   git rev-parse --short=12 HEAD   (плюс «-dirty» при незакоммиченных правках)

source "${0:A:h}/lib/update-common.sh"

EXPECTED_FINGERPRINT="${1:-}"
if [[ -z "$EXPECTED_FINGERPRINT" ]]; then
    print -u2 "Нужен отпечаток: scripts/verify-local.sh <отпечаток>"
    print -u2 "FIX: узнай отпечаток текущего дерева — git rev-parse --short=12 HEAD."
    exit 2
fi

TARGET_APP="/Applications/VoicePaste.app"

if [[ ! -d "$TARGET_APP" ]]; then
    print -u2 "VoicePaste не установлен: $TARGET_APP не найден."
    print -u2 "FIX: поставь его — scripts/install-local.sh."
    exit 1
fi

ACTUAL_FINGERPRINT=$(read_fingerprint "$TARGET_APP")
if [[ "$ACTUAL_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]]; then
    print -u2 "Отпечаток не совпадает: установлен «${ACTUAL_FINGERPRINT:-нет}», ожидался «$EXPECTED_FINGERPRINT»."
    print -u2 "FIX: собери и поставь заново — scripts/install-local.sh — либо сверь отпечаток нужного коммита."
    exit 1
fi

ACTUAL_BUNDLE_ID=$(read_bundle_id "$TARGET_APP")
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
    print -u2 "Идентификатор пакета не совпадает: «${ACTUAL_BUNDLE_ID:-нет}», ожидался «$BUNDLE_ID»."
    print -u2 "FIX: установлен чужой или повреждённый бандл — переустанови scripts/install-local.sh."
    exit 1
fi

if ! pgrep -ix "$PROCESS_NAME" >/dev/null 2>&1; then
    print -u2 "VoicePaste не запущен."
    print -u2 "FIX: запусти — open \"$TARGET_APP\" — либо переустанови заново."
    exit 1
fi

if ! osascript -e "with timeout of 5 seconds
tell application id \"$BUNDLE_ID\" to return name
end timeout" >/dev/null 2>&1; then
    print -u2 "VoicePaste запущен, но не отвечает за 5 с."
    print -u2 "FIX: процесс завис — перезапусти его через scripts/install-local.sh."
    exit 1
fi

print "OK: $TARGET_APP — отпечаток $EXPECTED_FINGERPRINT, идентификатор $BUNDLE_ID, запущен и отвечает."
