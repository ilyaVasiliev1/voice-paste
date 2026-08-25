#!/bin/zsh
set -euo pipefail

# Отвечает нулём ровно тогда, когда установленная в /Applications копия
# VoicePaste собрана из заданного отпечатка, несёт объявленный идентификатор
# пакета, подписана не ad-hoc удостоверением, совпадающим с базовой линией
# (T-0010), и запущена и отвечает. Расхождение в любом из условий — явный
# отказ с причиной и ненулевым кодом; «команда не упала» здесь не считается
# «установлено» (spec/logic.md#L-019).
#
#   scripts/verify-local.sh <отпечаток>
#
# Отпечаток текущего дерева даёт тот же расчёт, что делает install-local.sh:
#   git rev-parse --short=12 HEAD   (плюс «-dirty» при незакоммиченных правках)
#
# T-0010: проверяет также назначенное требование подписи установленной копии —
# отказывает, если оно ad-hoc (составлено из отпечатка кода, а не из
# сертификата и якоря Apple), и отказывает, если оно разошлось с базовой
# линией `.codesign-requirement-baseline.txt`. Первый прогон, когда базовой
# линии ещё нет, записывает её и проходит — но только если требование не
# ad-hoc; сам бандл эта проверка не меняет — ни подписи, ни Info.plist, ни
# отпечатка, только чтение (spec/logic.md#L-019).

PROJECT_ROOT="${0:A:h:h}"
source "${0:A:h}/lib/update-common.sh"

EXPECTED_FINGERPRINT="${1:-}"
if [[ -z "$EXPECTED_FINGERPRINT" ]]; then
    print -u2 "Нужен отпечаток: scripts/verify-local.sh <отпечаток>"
    print -u2 "FIX: узнай отпечаток текущего дерева — git rev-parse --short=12 HEAD."
    exit 2
fi

# T-0004, INV-015: слишком короткое ожидание совпало бы почти с чем угодно при
# сравнении по началу — это ошибка довода вызывающего, а не факт несовпадения,
# поэтому у неё свой код выхода (2, как у отсутствующего довода), не 1.
if (( $(fingerprint_hash_length "$EXPECTED_FINGERPRINT") < MIN_FINGERPRINT_LEN )); then
    print -u2 "Ожидание «$EXPECTED_FINGERPRINT» короче ${MIN_FINGERPRINT_LEN} знаков — это ошибка довода, а не отпечаток, с которым есть смысл сравнивать."
    print -u2 "FIX: узнай отпечаток текущего дерева — git rev-parse --short=12 HEAD (не короче ${MIN_FINGERPRINT_LEN} знаков)."
    exit 2
fi

TARGET_APP="/Applications/VoicePaste.app"

if [[ ! -d "$TARGET_APP" ]]; then
    print -u2 "VoicePaste не установлен: $TARGET_APP не найден."
    print -u2 "FIX: поставь его — scripts/install-local.sh."
    exit 1
fi

ACTUAL_FINGERPRINT=$(read_fingerprint "$TARGET_APP")
if ! fingerprints_match "$ACTUAL_FINGERPRINT" "$EXPECTED_FINGERPRINT"; then
    print -u2 "Отпечаток не совпадает: установлен «${ACTUAL_FINGERPRINT:-нет}», ожидался «$EXPECTED_FINGERPRINT»."
    print -u2 "Сравнение идёт по началу (короче — это начало длиннее) и по метке -dirty отдельно; разошлось хотя бы одно из двух, не обязательно строка целиком."
    print -u2 "FIX: собери и поставь заново — scripts/install-local.sh — либо сверь отпечаток нужного коммита."
    exit 1
fi

ACTUAL_BUNDLE_ID=$(read_bundle_id "$TARGET_APP")
if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
    print -u2 "Идентификатор пакета не совпадает: «${ACTUAL_BUNDLE_ID:-нет}», ожидался «$BUNDLE_ID»."
    print -u2 "FIX: установлен чужой или повреждённый бандл — переустанови scripts/install-local.sh."
    exit 1
fi

# T-0010: назначенное требование подписи — не подменяет три прежних условия,
# добавляется к ним. Читает бандл, не меняет его: не переподписывает, не
# штампует, не трогает Info.plist.
REQUIREMENT=$(read_codesign_requirement "$TARGET_APP")
if [[ -z "$REQUIREMENT" ]]; then
    print -u2 "Не удалось снять назначенное требование подписи с $TARGET_APP."
    print -u2 "FIX: проверь, что бандл подписан — codesign -dvvv \"$TARGET_APP\"."
    exit 1
fi

if codesign_requirement_is_adhoc "$REQUIREMENT"; then
    print -u2 "Установленная копия подписана ad-hoc: $REQUIREMENT"
    print -u2 "Ad-hoc даёт требование из отпечатка кода — он меняется на каждой пересборке, и разрешения приватности слетают вместе с ним (spec/logic.md#L-019)."
    print -u2 "FIX: поставь заново удостоверением разработчика — scripts/install-local.sh."
    exit 1
fi

CODESIGN_BASELINE_PATH="$PROJECT_ROOT/$CODESIGN_BASELINE_FILE"
if [[ ! -f "$CODESIGN_BASELINE_PATH" ]]; then
    print -r -- "$REQUIREMENT" > "$CODESIGN_BASELINE_PATH"
    print "Базовой линии требования подписи не было — зафиксировал текущее в $CODESIGN_BASELINE_PATH:"
    print "    $REQUIREMENT"
else
    BASELINE_REQUIREMENT=$(<"$CODESIGN_BASELINE_PATH")
    if [[ "$REQUIREMENT" != "$BASELINE_REQUIREMENT" ]]; then
        print -u2 "Назначенное требование подписи разошлось с базовой линией."
        print -u2 "Установлено:    $REQUIREMENT"
        print -u2 "Базовая линия:  $BASELINE_REQUIREMENT"
        print -u2 "FIX: если удостоверение сменилось намеренно — удали $CODESIGN_BASELINE_PATH и запусти verify-local.sh заново, он запишет новую базовую линию."
        exit 1
    fi
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

print "OK: $TARGET_APP — отпечаток $EXPECTED_FINGERPRINT, идентификатор $BUNDLE_ID, подпись не ad-hoc и совпадает с базовой линией, запущен и отвечает."
