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
read_fingerprint() {
    /usr/libexec/PlistBuddy -c "Print :VoicePasteBuildFingerprint" "$1/Contents/Info.plist" 2>/dev/null
    return 0
}

read_bundle_id() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null
    return 0
}

# Переименовывает установленную копию рядом с собой, под именем с её
# отпечатком и временем, и обрезает список сохранённых копий до предела
# (INV-014, не больше трёх). Перемещает `mv`, а не копирует и удаляет:
# переименование не читает и не пишет данные заново, поэтому не может оставить
# каталог наполовину скопированным.
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

    mv "$target" "$backup"
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
