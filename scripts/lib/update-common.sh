#!/bin/zsh
#
# Общие приёмы обновления и отката установленной копии VoicePaste на машине
# владельца: наблюдаемое погашение процесса, отпечаток сборки в Info.plist,
# сохранение и обрезка резервных копий. Источник для install-local.sh,
# rollback-local.sh и verify-local.sh — величины и порядок написаны один раз
# и больше нигде не повторяются.
#
# Правило: spec/logic.md#L-019. Величины: spec/_invariants.md#INV-013 (сколько
# ждать погашения), #INV-014 (сколько копий хранить).
#
# Не исполняемый файл сам по себе — подключается через `source`.

BUNDLE_ID="com.ilyavasiliev.voicepaste"
PROCESS_NAME="voicepaste"
MAX_BACKUPS=3   # INV-014
QUIT_BUDGET=15  # INV-013, секунд

# T-0003: сеть на непредвиденный отказ. Места, где неудача команды ожидаема,
# допускают её явно рядом с местом, где она случается (`|| true`, проверка
# файла заранее, ветки `if`) — до этой ловушки они не доходят. Сюда попадает
# то, что заранее не предвидено: `set -e` в таком случае молча останавливает
# скрипт с кодом упавшей команды и без единого слова, а человек видит только
# остановку на шаге и не знает, продолжать ли (`spec/logic.md#L-019`).
# Файл подключается через `source`, поэтому ловушка, поставленная здесь,
# действует в самом вызывающем скрипте — ставить её в каждом из трёх отдельно
# не нужно.
fail_loudly() {
    local exit_code=$?
    local line="${1:-?}"
    print -u2 ""
    print -u2 "${ZSH_ARGZERO:t}: отказ на строке ${line} (код ${exit_code}), скрипт остановлен."
    print -u2 "FIX: причину обычно уже назвала команда в выводе выше; почини её и запусти скрипт заново."
    exit "$exit_code"
}
trap 'fail_loudly $LINENO' ERR

# Гасит работающую копию и не возвращает управление, пока процесс не исчез или
# не истёк бюджет ожидания. Пробует по нарастающей: штатный quit через Apple
# Event, затем SIGTERM, затем SIGKILL. По истечении бюджета — явный отказ:
# продолжать обновление под работающим процессом запрещено (L-019), а тихо
# слать SIGKILL с самого начала — терять несохранённое состояние без причины.
quit_and_wait() {
    if ! pgrep -ix "$PROCESS_NAME" >/dev/null 2>&1; then
        return 0
    fi

    print "Закрываю запущенный VoicePaste…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

    local waited=0
    while pgrep -ix "$PROCESS_NAME" >/dev/null 2>&1; do
        if (( waited >= QUIT_BUDGET )); then
            break
        fi
        if (( waited == 5 )); then
            pkill -TERM -ix "$PROCESS_NAME" 2>/dev/null || true
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if pgrep -ix "$PROCESS_NAME" >/dev/null 2>&1; then
        pkill -KILL -ix "$PROCESS_NAME" 2>/dev/null || true
        sleep 1
    fi

    if pgrep -ix "$PROCESS_NAME" >/dev/null 2>&1; then
        print -u2 "Не удалось погасить работающий VoicePaste за ${QUIT_BUDGET} с (INV-013)."
        print -u2 "FIX: закрой процесс вручную — Activity Monitor → VoicePaste → Force Quit — и запусти команду снова."
        exit 3
    fi
}

# Отпечаток дерева, из которого поставлена копия: короткий хэш HEAD, с
# пометкой -dirty при незакоммиченных изменениях. Не версия — версия ничего не
# говорит о том, какой именно код собран, а коммит говорит однозначно.
compute_fingerprint() {
    local root="$1"
    local hash
    hash=$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null) || hash="unknown"
    if [[ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]]; then
        hash="${hash}-dirty"
    fi
    print -r -- "$hash"
}

# Кладёт отпечаток в Info.plist устанавливаемой копии. Выполняется над копией
# в целевом месте, а не над сборкой в derived data: verify-local.sh проверяет
# ровно то, что физически стоит в /Applications.
stamp_fingerprint() {
    local app="$1" fingerprint="$2"
    local plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Delete :VoicePasteBuildFingerprint" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :VoicePasteBuildFingerprint string $fingerprint" "$plist" >/dev/null
}

# Пустая строка, если ключа нет или файла нет, — не отказ самой функции.
# Под `set -e` вызывающих скриптов `var=$(read_fingerprint …)` иначе прервал бы
# скрипт при первой же копии без отпечатка, не дав коду ниже решить, что
# с этим делать.
#
# T-0003: отдельный `return 0` строкой ниже эту защиту не давал — `set -e`
# прерывает функцию на неудачном `PlistBuddy` до того, как управление дойдёт
# до `return`, и делает это молча (`2>/dev/null` гасит только текст, не код
# возврата). Отказ обязан быть допущен явно там же, где случается, — прямо на
# самой команде через `||`, а не отдельной строкой после неё.
#
# Отсутствующий файл проверяется отдельно, до вызова PlistBuddy: на
# несуществующем пути он не просто отказывает — на стандартный вывод (не на
# stderr, `2>/dev/null` его не гасит) идёт «File Doesn't Exist, Will Create: …»,
# и это предупреждение попало бы в переменную вместо пустой строки.
read_fingerprint() {
    local plist="$1/Contents/Info.plist"
    [[ -f "$plist" ]] || return 0
    /usr/libexec/PlistBuddy -c "Print :VoicePasteBuildFingerprint" "$plist" 2>/dev/null || true
}

read_bundle_id() {
    local plist="$1/Contents/Info.plist"
    [[ -f "$plist" ]] || return 0
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true
}

# Копирует установленную копию рядом с собой, под именем с её отпечатком и
# временем, и обрезает список сохранённых копий до предела (INV-014, не
# больше трёх). Копирует `ditto`, затем убирает исходник `rm -rf` — не
# переименовывает `mv`: решение и его цена — memory/decisions.md, 2026-08-24
# («Резервная копия в backup_previous: ditto+rm вместо mv»). Исходник убирается
# только после того, как `ditto` завершился успешно — `set -e` вызывающих
# скриптов останавливает выполнение на неудачном `ditto` раньше, чем дойдёт до
# `rm`, поэтому сбой копирования не трогает реальную установленную копию;
# рискует остаться неполной только сама резервная копия.
backup_previous() {
    local target="$1"
    [[ -d "$target" ]] || return 0

    local old_fingerprint
    old_fingerprint=$(read_fingerprint "$target")
    [[ -n "$old_fingerprint" ]] || old_fingerprint="unknown"

    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    local dir="${target:h}"
    local backup="$dir/VoicePaste-${old_fingerprint}-${stamp}.app"

    ditto "$target" "$backup"
    rm -rf "$target"
    print "Прежняя копия сохранена: $backup"
    prune_backups "$dir"
}

# Оставляет не больше MAX_BACKUPS каталогов вида VoicePaste-*.app, удаляя
# самые старые по времени изменения. Глоб-квалификатор `(N)` даёт пустой
# список вместо ошибки zsh «no matches found», когда копий ещё нет — это
# штатный случай (первая установка), а не повод падать; `(Om)` сортирует по
# времени изменения от нового к старому.
prune_backups() {
    local dir="$1"
    local -a backups
    backups=("$dir"/VoicePaste-*.app(NOm))
    local count=${#backups[@]}
    if (( count > MAX_BACKUPS )); then
        local i
        for (( i = MAX_BACKUPS + 1; i <= count; i++ )); do
            print "Удалена старая копия сверх предела в $MAX_BACKUPS (INV-014): ${backups[$i]}"
            rm -rf "${backups[$i]}"
        done
    fi
}

# Самая свежая сохранённая копия рядом с установленным приложением; пустая
# строка, если сохранённых копий нет.
latest_backup() {
    local dir="$1"
    local -a backups
    backups=("$dir"/VoicePaste-*.app(NOm))
    (( ${#backups[@]} > 0 )) && print -r -- "${backups[1]}"
    return 0
}
