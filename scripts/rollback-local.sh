#!/bin/zsh
set -euo pipefail

# Откатывает установленную копию VoicePaste на машине владельца на заданный
# отпечаток тем же порядком, что и обновление (spec/logic.md#L-019): погасить
# → собрать отпечаток → поставить → запустить. Между шагами работающей копии
# нет ни секунды.
#
#   scripts/rollback-local.sh <отпечаток>
#
# T-0007: резервной копии на диске больше нет — на устройстве живёт ровно одна
# установленная копия (L-019), и откат не подменяет файлы, а собирает
# указанный отпечаток заново из истории git, во временном рабочем дереве, тем
# же порядком, что и обычная установка. Это точнее, чем скопированный бандл:
# копия стареет и молча расходится с историей, а отпечаток — нет.
#
# Отпечаток — то, что называет `git log --oneline` (полный или короткий хэш
# коммита, ветка, тег). Метка -dirty из вывода verify-local.sh к самому
# коммиту не относится и в доводе не нужна: незакоммиченные правки вне истории
# git этот откат не восстановит — он воспроизводит только то, что закоммичено.
#
# Без довода команда отказывает явно, не трогая и не гася работающую копию
# понапрасну. Временное рабочее дерево убирается за собой при любом исходе —
# удачной сборке, неудачной сборке или отказе где-либо между ними.
#
# Отдельной беты у продукта нет: испытуемая и рабочая копия — одна и та же,
# поэтому у обновления обязан быть путь назад — на воспроизводимый отпечаток,
# а не на угадывание, что где-то рядом лежит старая копия.

PROJECT_ROOT="${0:A:h:h}"
source "${0:A:h}/lib/update-common.sh"

TARGET_APP="/Applications/VoicePaste.app"
DERIVED_DATA="${DELTA_DERIVED_DATA:-$PROJECT_ROOT/.tmp/delta-verify}"
REQUESTED="${1:-}"

if [[ -z "$REQUESTED" ]]; then
    print -u2 "Нужен отпечаток: scripts/rollback-local.sh <отпечаток>"
    print -u2 "FIX: узнай доступные отпечатки — git log --oneline."
    exit 2
fi

# Метка -dirty (если её скопировали прямо из вывода verify-local.sh) относится
# не к коммиту, а к состоянию рабочего дерева на момент той сборки — у самого
# отпечатка-коммита её нет, и git её не знает.
COMMITISH="${REQUESTED%-dirty}"
COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --verify "${COMMITISH}^{commit}" 2>/dev/null) || {
    print -u2 "Отпечаток «$REQUESTED» не найден в истории git."
    print -u2 "FIX: узнай доступные отпечатки — git log --oneline."
    exit 2
}

# T-0010: удостоверение подписи проверяется до того, как погашена работающая
# копия и до того, как заведено временное рабочее дерево — отказ здесь не
# должен стоить владельцу ни работающего приложения, ни лишней сборки.
print "Проверяю удостоверение подписи…"
IDENTITY=$(resolve_codesign_identity "$PROJECT_ROOT") || {
    print -u2 "Не задано удостоверение для подписи локальной установки."
    print -u2 "Настройка: переменная среды $CODESIGN_IDENTITY_ENV_VAR — либо поле \"$CODESIGN_IDENTITY_JSON_KEY\" окружения local в $CODESIGN_IDENTITY_ENV_FILE."
    print -u2 "Сейчас не задано ни одно из двух."
    print -u2 "FIX: задай одно из двух и запусти откат заново. Работающая копия не тронута."
    exit 2
}
if ! codesign_identity_available "$IDENTITY"; then
    print -u2 "Удостоверение «$IDENTITY» не найдено среди действующих на этой машине."
    print -u2 "Настройка: переменная среды $CODESIGN_IDENTITY_ENV_VAR — либо поле \"$CODESIGN_IDENTITY_JSON_KEY\" окружения local в $CODESIGN_IDENTITY_ENV_FILE — сейчас даёт «$IDENTITY»."
    print_available_identities
    print -u2 "FIX: заведи нужный сертификат в связке ключей либо поправь настройку — и запусти откат заново. Работающая копия не тронута."
    exit 1
fi
print "    удостоверение: $IDENTITY"

print "1/5 Убираю резервные копии прежней реализации обновления…"
cleanup_legacy_backups "${TARGET_APP:h}"

print "2/5 Гашу работающую копию…"
quit_and_wait

WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/voicepaste-rollback.XXXXXX")
cleanup_worktree() {
    git -C "$PROJECT_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
    rm -rf "$WORKTREE"
}
trap cleanup_worktree EXIT INT TERM

print "3/5 Собираю отпечаток $COMMIT во временном рабочем дереве…"
git -C "$PROJECT_ROOT" worktree add --detach "$WORKTREE" "$COMMIT" >/dev/null
SOURCE_APP=$(build_debug "$WORKTREE" "$DERIVED_DATA")
if [[ ! -d "$SOURCE_APP" ]]; then
    print -u2 "Сборка отпечатка $REQUESTED прошла, но не оставила $SOURCE_APP."
    print -u2 "FIX: тот же отпечаток собирает scripts/install-local.sh — проверь схему и конфигурацию Debug там же."
    exit 2
fi

FINGERPRINT=$(compute_fingerprint "$WORKTREE")

print "4/5 Ставлю собранную копию…"
install_app "$SOURCE_APP" "$TARGET_APP" "$FINGERPRINT" "$IDENTITY"

print "5/5 Запускаю…"
open "$TARGET_APP"

print "Откачено: $TARGET_APP ($FINGERPRINT)"
print "Проверка: scripts/verify-local.sh $FINGERPRINT"
