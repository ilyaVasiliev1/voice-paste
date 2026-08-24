#!/bin/zsh
set -euo pipefail

# Возвращает последнюю сохранённую копию VoicePaste на машине владельца тем же
# порядком, что и обновление (spec/logic.md#L-019): погасить → вернуть →
# запустить. Между шагами работающей копии нет ни секунды.
#
#   scripts/rollback-local.sh
#
# Сохранённые копии оставляет scripts/install-local.sh при каждом обновлении,
# рядом с установленным приложением, под именем с отпечатком и временем.
# Без сохранённой копии откатывать нечего — команда откажет явно, а не
# погасит рабочую копию просто так.
#
# Отдельной беты у продукта нет: испытуемая и рабочая копия — одна и та же,
# поэтому у обновления обязан быть путь назад именно на прежнюю установленную
# копию, а не на исходники или сборку заново.

source "${0:A:h}/lib/update-common.sh"

TARGET_APP="/Applications/VoicePaste.app"
APP_DIR="${TARGET_APP:h}"

BACKUP=$(latest_backup "$APP_DIR")
if [[ -z "$BACKUP" ]]; then
    print -u2 "Нет сохранённых копий для отката в $APP_DIR."
    print -u2 "FIX: откат возможен только после хотя бы одного обновления — scripts/install-local.sh."
    exit 2
fi

print "1/3 Гашу работающую копию…"
quit_and_wait

print "2/3 Возвращаю $BACKUP…"
rm -rf "$TARGET_APP"
mv "$BACKUP" "$TARGET_APP"

print "3/3 Запускаю…"
open "$TARGET_APP"

FINGERPRINT=$(read_fingerprint "$TARGET_APP")
print "Откачено: $TARGET_APP (${FINGERPRINT:-неизвестный отпечаток})"
if [[ -n "$FINGERPRINT" ]]; then
    print "Проверка: scripts/verify-local.sh $FINGERPRINT"
fi
