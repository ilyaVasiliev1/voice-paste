#!/bin/zsh
set -euo pipefail

# Обновляет установленную копию VoicePaste на машине владельца целиком, одной
# командой, в порядке из spec/logic.md#L-019:
#
#   1. погасить работающую копию и дождаться, что процесса нет (INV-013)
#   2. собрать — либо принять готовую сборку доводом
#   3. сохранить прежнюю копию рядом, под именем с отпечатком и временем
#   4. поставить новую
#   5. запустить её
#
# Между шагом 1 и шагом 5 работающей копии нет ни секунды: приложение слушает
# глобальную горячую клавишу и пишет в чужие окна, и две живые копии — это два
# слушателя одной клавиши и два писателя в одно хранилище.
#
# Отдельной беты у продукта нет: испытуемая копия и рабочая — одна и та же,
# поэтому неудачная сборка оставляет владельца без диктовки. Прежняя копия
# сохраняется, а не перезаписывается, — есть куда откатиться:
# scripts/rollback-local.sh.
#
#   scripts/install-local.sh [путь/к/VoicePaste.app]
#
# Без аргумента собирается свежая Debug-сборка в каталог гейта Delta OS
# (`.tmp/delta-verify` — тот же, что использует `tools/verify.sh`), а не
# каталог прежней системы. С аргументом сборка не запускается — берётся
# указанный путь как есть (например, уже готовая сборка стека).

PROJECT_ROOT="${0:A:h:h}"
source "${0:A:h}/lib/update-common.sh"

TARGET_APP="/Applications/VoicePaste.app"
DERIVED_DATA="${DELTA_DERIVED_DATA:-$PROJECT_ROOT/.tmp/delta-verify}"
SOURCE_APP="${1:-}"

print "1/5 Гашу работающую копию…"
quit_and_wait

if [[ -n "$SOURCE_APP" ]]; then
    if [[ ! -d "$SOURCE_APP" ]]; then
        print -u2 "Нет сборки по пути: $SOURCE_APP"
        print -u2 "FIX: проверь путь доводом — либо запусти без аргумента, чтобы собрать самому."
        exit 2
    fi
    print "2/5 Использую готовую сборку: $SOURCE_APP"
else
    print "2/5 Собираю в $DERIVED_DATA…"
    xcodebuild \
        -project "$PROJECT_ROOT/VoicePaste.xcodeproj" -scheme VoicePaste \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED_DATA" \
        -disableAutomaticPackageResolution -jobs 2 \
        build CODE_SIGNING_ALLOWED=NO
    SOURCE_APP="$DERIVED_DATA/Build/Products/Debug/VoicePaste.app"
    if [[ ! -d "$SOURCE_APP" ]]; then
        print -u2 "Сборка прошла, но не оставила $SOURCE_APP."
        print -u2 "FIX: проверь схему сборки и конфигурацию Debug в VoicePaste.xcodeproj."
        exit 2
    fi
fi

FINGERPRINT=$(compute_fingerprint "$PROJECT_ROOT")
print "    отпечаток: $FINGERPRINT"

print "3/5 Сохраняю прежнюю копию…"
backup_previous "$TARGET_APP"

print "4/5 Ставлю новую копию…"
# Прежняя установка не перезаписывается копированием поверх: копирование поверх
# существующего бандла оставляет файлы, которых в новой сборке уже нет. Здесь
# перезаписывать и нечего — прежняя копия уже унесена шагом бэкапа.
ditto "$SOURCE_APP" "$TARGET_APP"
stamp_fingerprint "$TARGET_APP" "$FINGERPRINT"

# Подпись ad-hoc: без неё macOS отказывает приложению в правах доступности и
# микрофона, а без них продукт не работает вовсе. Подписывается после стемпинга
# отпечатка — печать в Info.plist меняет бандл и обязана произойти до подписи,
# иначе подпись окажется недействительной для изменённого содержимого.
codesign --force --deep --sign - "$TARGET_APP" >/dev/null 2>&1 || true

print "5/5 Запускаю…"
open "$TARGET_APP"

print "Поставлено: $TARGET_APP ($FINGERPRINT)"
print "Проверка:   scripts/verify-local.sh $FINGERPRINT"
