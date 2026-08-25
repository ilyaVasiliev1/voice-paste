#!/bin/zsh
#
# Общие приёмы обновления и отката установленной копии VoicePaste на машине
# владельца: наблюдаемое погашение процесса, сборка Debug-копии, установка и
# отпечаток сборки в Info.plist. Источник для install-local.sh,
# rollback-local.sh и verify-local.sh — величины и порядок написаны один раз
# и больше нигде не повторяются.
#
# Правило: spec/logic.md#L-019 — на устройстве живёт ровно одна установленная
# копия, резервные копии рядом с ней не заводятся (T-0007). Величина:
# spec/_invariants.md#INV-013 (сколько ждать погашения).
#
# Не исполняемый файл сам по себе — подключается через `source`.

BUNDLE_ID="com.ilyavasiliev.voicepaste"
PROCESS_NAME="voicepaste"
QUIT_BUDGET=15           # INV-013, секунд
MIN_FINGERPRINT_LEN=7    # INV-015

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

# Отделяет метку -dirty от хэша отпечатка. Печатает "хэш метка" одной строкой
# через пробел, метка — "1" при незакоммиченных правках, иначе "0". Единственное
# место, где известен формат "<хэш>[-dirty]" — остальной код сравнения им не
# интересуется напрямую (T-0004).
_fingerprint_parts() {
    local fp="$1"
    if [[ "$fp" == *-dirty ]]; then
        print -r -- "${fp%-dirty} 1"
    else
        print -r -- "$fp 0"
    fi
}

# Число знаков хэша в отпечатке, без учёта метки -dirty. Используется отдельно
# от сравнения — вызывающий отвергает слишком короткое ожидание сам, до того,
# как дело дойдёт до самого сравнения (spec/_invariants.md#INV-015).
fingerprint_hash_length() {
    local hash
    hash="${1%-dirty}"
    print -r -- ${#hash}
}

# Совпадают ли два отпечатка сборки — по началу, а не побуквенно
# (T-0004, spec/logic.md#L-019): у Git короткий хэш не имеет единственной
# длины, её выбирает вызывающий, поэтому более короткий из двух хэшей обязан
# быть началом более длинного. Метка -dirty сравнивается отдельно от хэша и
# обязана совпадать всегда, независимо от того, чей хэш короче. Пустой хэш
# (нет ключа в Info.plist, компоновка ещё не поставила отпечаток) ни с чем не
# совпадает — иначе отсутствие всякого значения проходило бы проверку при
# любом ожидании, а это не «установлено», а отсутствие ответа.
#
# Возвращает 0 при совпадении, 1 иначе — обычное условие вызывающего скрипта,
# не отдельная проверка ошибки довода: за отпечаток короче нижнего предела
# отвечает fingerprint_hash_length, вызванный до этой функции.
fingerprints_match() {
    local actual="$1" expected="$2"
    local actual_hash actual_dirty expected_hash expected_dirty
    read -r actual_hash actual_dirty <<< "$(_fingerprint_parts "$actual")"
    read -r expected_hash expected_dirty <<< "$(_fingerprint_parts "$expected")"

    [[ -n "$actual_hash" && -n "$expected_hash" ]] || return 1
    [[ "$actual_dirty" == "$expected_dirty" ]] || return 1

    if (( ${#actual_hash} <= ${#expected_hash} )); then
        [[ "$expected_hash" == "$actual_hash"* ]]
    else
        [[ "$actual_hash" == "$expected_hash"* ]]
    fi
}

# T-0007: решение человека — копий не заводить вовсе (spec/logic.md#L-019).
# Прежние версии install-local.sh/rollback-local.sh (T-0001…T-0004) оставляли
# рядом с установленной копией резервные `VoicePaste-<отпечаток>-<время>.app` —
# система обходит /Applications и показывает каждую как отдельное приложение,
# о котором человек не знает и не заводил. Эта функция убирает уже
# накопившийся мусор один раз, при первом запуске обновлённых скриптов, и
# молчать об удалении нельзя — человек должен видеть, что чужой мусор убран.
# Глоб-квалификатор `(N)` даёт пустой список вместо ошибки zsh «no matches
# found», когда копий уже нет, — штатный случай на второй и последующий
# запуск.
cleanup_legacy_backups() {
    local dir="$1"
    local -a stray
    stray=("$dir"/VoicePaste-*.app(N))
    local app
    for app in "${stray[@]}"; do
        rm -rf "$app"
        print "Удалена резервная копия прежней реализации обновления: $app"
    done
}

# Собирает Debug-сборку продукта из указанного корня дерева (обычного или
# временного рабочего дерева отката) и печатает путь до собранного .app на
# stdout. Вывод самой сборки идёт в stderr — не в перехват `$(...)`, которым
# вызывающий забирает путь.
#
# derived data передаётся отдельно от корня дерева и по умолчанию у install
# и rollback общий (каталог гейта Delta OS): рабочее дерево отката получает
# другой исходный код, но уже разрешённые SPM-зависимости (SourcePackages) от
# дерева исходников не зависят, и разрешать их заново незачем.
build_debug() {
    local project_root="$1" derived_data="$2"
    xcodebuild \
        -project "$project_root/VoicePaste.xcodeproj" -scheme VoicePaste \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$derived_data" \
        -disableAutomaticPackageResolution -jobs 2 \
        build CODE_SIGNING_ALLOWED=NO >&2
    print -r -- "$derived_data/Build/Products/Debug/VoicePaste.app"
}

# Ставит собранную копию в целевое место, штампует отпечаток и подписывает
# ad-hoc — общий хвост install-local.sh и rollback-local.sh после того, как
# каждый из них получил свою сборку (готовую или собранную из отпечатка).
#
# Прежняя копия по целевому пути убирается перед установкой, не
# перезаписывается копированием поверх: копирование поверх существующего
# бандла оставляет файлы, которых в новой сборке уже нет.
#
# Подпись ad-hoc: без неё macOS отказывает приложению в правах доступности и
# микрофона, а без них продукт не работает вовсе. Подписывается после
# стемпинга отпечатка — печать в Info.plist меняет бандл и обязана произойти
# до подписи, иначе подпись окажется недействительной для изменённого
# содержимого.
install_app() {
    local source="$1" target="$2" fingerprint="$3"
    rm -rf "$target"
    ditto "$source" "$target"
    stamp_fingerprint "$target" "$fingerprint"
    codesign --force --deep --sign - "$target" >/dev/null 2>&1 || true
}
