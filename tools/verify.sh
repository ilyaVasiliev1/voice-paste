#!/bin/sh
#
# Гейт стека macos-swift-app: один вход, два уровня.
#
#   fast   то, что отвечает за секунды: агент зовёт по ходу работы
#   full   всё, что есть: оркестратор зовёт перед сдачей
#
# Один вход, а не список команд в конфиге проекта. Проверка, которую зовут
# по-разному из разных мест, рано или поздно где-то зовётся неполной — и
# зелёный прогон перестаёт означать то, что означал.
#
# У каждой проверки свой предел времени. Проверка без предела однажды висит
# до конца прогона, и вместо отказа получается тишина. В macOS нет `timeout`,
# поэтому предел держится здесь руками.

set -u

TIER="${1:-full}"
case "$TIER" in
    fast|full) ;;
    *)
        echo "Уровень «$TIER» не бывает. Есть: fast, full." >&2
        exit 2
        ;;
esac

# ─── что за проект ───────────────────────────────────────────────────────
#
# Имя проекта и схемы не вшиваются: стек обслуживает любое приложение такой
# формы. Прежнее поколение вшивало «VoicePaste» прямо в команды стека — и стек
# переставал быть стеком, становясь настройками одного продукта.
XCPROJ="${DELTA_XCODEPROJ:-$(ls -d ./*.xcodeproj 2>/dev/null | head -1)}"
if [ -z "$XCPROJ" ] || [ ! -d "$XCPROJ" ]; then
    echo "Не найден .xcodeproj в $(pwd)." >&2
    echo "FIX: запусти из корня поверхности либо задай DELTA_XCODEPROJ=<путь>." >&2
    exit 2
fi
XCPROJ_BASE=$(basename "$XCPROJ" .xcodeproj)
SCHEME="${DELTA_SCHEME:-$XCPROJ_BASE}"
DERIVED="${DELTA_DERIVED_DATA:-.tmp/delta-verify}"

# Сколько потоков компиляции. Было зашито «2», и причина этого числа не была
# записана нигде — ни в правилах стека, ни в источниках.
#
# Замерено 25 августа 2026 на машине с 4 быстрыми и 6 экономичными ядрами:
# три пары прогонов вперемешку, кэш модулей прогрет одинаково.
#
#   jobs=2   58 с · 201 с · 32 с    медиана 58
#   jobs=8   38 с ·  75 с · 22 с    медиана 38
#
# Разброс велик, и одному числу верить нельзя — но направление одинаково во
# всех трёх парах, а это и есть сигнал. Медиана короче на треть.
#
# Считаем от машины, а не пишем восьмёрку: два ядра оставляем человеку, чтобы
# гейт не отбирал у него весь процессор, пока он работает.
JOBS="${DELTA_BUILD_JOBS:-$(( $(sysctl -n hw.ncpu 2>/dev/null || echo 4) - 2 ))}"
[ "$JOBS" -lt 1 ] && JOBS=1

XCB_COMMON="-project $XCPROJ -scheme $SCHEME -destination platform=macOS,arch=arm64 \
 -derivedDataPath $DERIVED -disableAutomaticPackageResolution -jobs $JOBS CODE_SIGNING_ALLOWED=NO"

# Исходники ищутся от корня, а не по перечню каталогов. Перечень однажды
# уже оказался тихим дефектом в соседнем стеке: на проекте без объявленного
# каталога поиск падал, код возврата съедался конвейером, и проверка
# проходила, ничего не проверив.
ALL_SWIFT=$(find . -name '*.swift' \
    -not -path './.tmp/*' -not -path './.build/*' -not -path './build/*' \
    -not -path './DerivedData/*' -not -path './Pods/*' -not -path './.git/*' \
    2>/dev/null)

# ─── храповик оформления ─────────────────────────────────────────────────
#
# У swift format нет базовой линии, в отличие от SwiftLint и periphery.
# Поэтому храповик здесь делается перечнем: проверяются файлы, изменённые
# относительно базовой ветки, а не весь продукт.
#
# Так старое не мешает работать, новое не проходит, и человек сам решает,
# когда взяться за старое — отдельной задачей, а не под давлением гейта.
# На самой базовой ветке изменённых файлов нет, и проверка молчит.
#
# Считать по-другому нельзя: на живом проекте из 13 тысяч строк первый же
# прогон дал две тысячи замечаний об отступах — не грязь, а расхождение
# настройки. Гейт, который с первого дня красный, отключают.
BASE_REF="${DELTA_BASE_REF:-main}"
FORMAT_FILES="$ALL_SWIFT"
FORMAT_SCOPE="весь продукт"
if git rev-parse --git-dir > /dev/null 2>&1; then
    MERGE_BASE=$(git merge-base HEAD "$BASE_REF" 2>/dev/null)
    if [ -n "$MERGE_BASE" ]; then
        FORMAT_FILES=$(git diff --name-only --diff-filter=ACMR "$MERGE_BASE" -- '*.swift' 2>/dev/null \
            | while IFS= read -r f; do [ -f "$f" ] && echo "./$f"; done)
        FORMAT_SCOPE="изменённое относительно $BASE_REF"
    fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
FAILED=""
PASSED=0
STARTED=$(date +%s)

# Предел времени руками: запускаем в фоне и ждём, поглядывая на часы.
run_limited() {
    limit="$1"
    cmd="$2"
    out="$3"
    ( eval "$cmd" ) > "$out" 2>&1 &
    pid=$!
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$limit" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -KILL "$pid" 2>/dev/null
            echo "" >> "$out"
            echo "проверка не уложилась в ${limit} с и была прервана" >> "$out"
            return 124
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid"
    return $?
}

check() {
    name="$1"
    what="$2"
    limit="$3"
    cmd="$4"
    out="$WORK/$name.log"
    started=$(date +%s)
    run_limited "$limit" "$cmd" "$out"
    code=$?
    took=$(( $(date +%s) - started ))
    if [ "$code" -eq 0 ]; then
        printf '✓ %-10s %s  (%s с)\n' "$name" "$what" "$took"
        PASSED=$((PASSED + 1))
    else
        printf '✗ %-10s %s  (%s с)\n' "$name" "$what" "$took"
        sed -n '1,40p' "$out" | sed 's/^/    /'
        FAILED="$FAILED $name"
    fi
}

echo "Гейт macos-swift-app · $XCPROJ_BASE · уровень $TIER"
echo

# ─── 1. Формат ───────────────────────────────────────────────────────────
if [ -n "$FORMAT_FILES" ]; then
    echo "$FORMAT_FILES" > "$WORK/files.txt"
    # Перечень подаётся перенаправлением, а не доводом `-a`: это довод GNU,
    # а на macOS xargs берклиевский и о нём не знает. Тот же капкан здесь уже
    # был со сборщиком строк `sed -i`.
    check format "оформление по .swift-format · $FORMAT_SCOPE" 120 \
        "xargs swift format lint --strict --configuration .swift-format < '$WORK/files.txt'"
else
    echo "· format     пропущена: изменённых файлов .swift нет ($FORMAT_SCOPE)"
fi

# ─── 2. Правила ──────────────────────────────────────────────────────────
# Базовая линия — храповик для существующего кода: находки, записанные
# в неё, не мешают работать; новые не проходят. Файла нет — проверяется всё,
# и это верно для проекта, заведённого с нуля.
LINT_BASELINE=""
[ -f .swiftlint-baseline.json ] && LINT_BASELINE="--baseline .swiftlint-baseline.json"
if command -v swiftlint > /dev/null 2>&1; then
    check rules "приёмы, роняющие приложение, и границы слоёв" 180 \
        "swiftlint lint --quiet --strict --config .swiftlint.yml $LINT_BASELINE"
else
    echo "✗ rules      SwiftLint не установлен"
    echo "    FIX: brew install swiftlint"
    FAILED="$FAILED rules"
fi

# ─── 3. Типы ─────────────────────────────────────────────────────────────
#
# Предупреждение компилятора здесь — отказ. Swift предупреждает о вещах,
# которые в других языках были бы ошибками: недостижимый код, потерянный
# результат, небезопасный переход через границу изоляции.
#
# Но не доводом `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`. Довод командной строки
# ложится на **все** цели сборки, включая чужие пакеты, а те глушат свои
# предупреждения у себя — и сборка падает не на нашем коде, а на
# «Conflicting options '-warnings-as-errors' and '-suppress-warnings'»
# в GRDB и WhisperKit. Проверено: именно так гейт и упал в первый раз.
#
# Поэтому собираем как есть и смотрим предупреждения только в своих файлах.
# Чужой код — не наша ответственность и не наш повод для отказа.
types_gate() {
    raw="$WORK/types.raw"
    xcodebuild $XCB_COMMON build > "$raw" 2>&1
    code=$?
    if [ "$code" -ne 0 ]; then
        grep -E "error:" "$raw" | sort -u | head -20
        [ -s "$raw" ] || echo "сборка не дала вывода"
        return 1
    fi
    grep -E "^/.*: warning: " "$raw" \
        | grep -v "/\.tmp/" \
        | grep -v "/SourcePackages/" \
        | grep -v "/DerivedData/" \
        | grep -v "/Pods/" \
        | sort -u > "$WORK/types.warn"
    if [ -s "$WORK/types.warn" ]; then
        echo "предупреждения компилятора в исходниках продукта:"
        cat "$WORK/types.warn"
        return 1
    fi
    return 0
}
check types "сборка Debug, предупреждение компилятора — отказ" 900 types_gate

if [ "$TIER" = "fast" ]; then
    echo
    echo "────────────────────────────────────────────────────────────"
    echo "Уровень: fast · $(( $(date +%s) - STARTED )) с · пройдено $PASSED"
    [ -z "$FAILED" ] && { echo "Гейт зелёный."; exit 0; }
    echo "Упало:$FAILED"
    exit 1
fi

# ─── 4. Тесты ────────────────────────────────────────────────────────────
#
# Приложение macOS живёт на той же машине, где идёт проверка: у него есть
# установленная копия, глобальные горячие клавиши и пользовательское
# хранилище. Тестовый прогон обязан их не трогать — иначе проверка ломает
# рабочую машину человека.
#
# Как именно продукт себя глушит, знает только он, поэтому у проекта есть
# право объявить свой запуск файлом tools/test.sh. Это объявление, а не
# догадка стека: файл либо положен, либо нет.
if [ -x tools/test.sh ]; then
    check tests "XCTest через объявленный проектом запуск" 1800 "sh tools/test.sh"
else
    check tests "XCTest" 1800 "xcodebuild $XCB_COMMON test -enableCodeCoverage YES"
fi

# ─── 5. Покрытие ─────────────────────────────────────────────────────────
#
# Порог объявляет проект файлом coverage-min.txt. Без порога число печатается,
# но гейтом не становится: цифра без порога никого ни к чему не обязывает.
#
# Отчёт ищется не только в каталоге стека: когда тесты запускает объявленный
# проектом `tools/test.sh`, он собирает в свой каталог, и отчёта по адресу
# стека просто нет. Ровно это и вышло на первом живом прогоне — гейт был
# зелёный, а строки про покрытие не было вовсе.
#
# Берётся только отчёт, появившийся **после начала этого прогона**: иначе
# гейт напечатал бы вчерашнее число как сегодняшнее, а это хуже молчания.
XCRESULT=""
for candidate in $(ls -td .tmp/*/Logs/Test/*.xcresult "$DERIVED"/Logs/Test/*.xcresult 2>/dev/null); do
    [ -e "$candidate" ] || continue
    made=$(stat -f %m "$candidate" 2>/dev/null || echo 0)
    if [ "$made" -ge "$STARTED" ]; then
        XCRESULT="$candidate"
        break
    fi
done
if [ -z "$XCRESULT" ]; then
    echo "· coverage   покрытие не измерено: прогон тестов не оставил свежего отчёта"
fi
if [ -n "$XCRESULT" ]; then
    COV=$(xcrun xccov view --report --only-targets "$XCRESULT" 2>/dev/null \
        | awk -v app="$XCPROJ_BASE.app" '$0 ~ app { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { gsub(/%/, "", $i); print $i; exit } }')
    if [ -n "$COV" ]; then
        if [ -f coverage-min.txt ]; then
            MIN=$(tr -d ' \n' < coverage-min.txt)
            LOW=$(awk -v c="$COV" -v m="$MIN" 'BEGIN { print (c + 0 < m + 0) ? 1 : 0 }')
            if [ "$LOW" = "1" ]; then
                printf '✗ %-10s покрытие %s%% ниже объявленного порога %s%%\n' coverage "$COV" "$MIN"
                FAILED="$FAILED coverage"
            else
                printf '✓ %-10s покрытие %s%% при пороге %s%%\n' coverage "$COV" "$MIN"
                PASSED=$((PASSED + 1))
            fi
        else
            printf '· %-10s покрытие %s%% — порог не объявлен (coverage-min.txt)\n' coverage "$COV"
        fi
    fi
fi

# ─── 6. Мёртвый код ──────────────────────────────────────────────────────
#
# `--disable-redundant-public-analysis` — калибровка, а не послабление.
# В приложении из одного модуля `public` ничего не открывает наружу, потому
# что наружи нет. Без этого флага на живом продукте 155 находок из 182 были
# про лишний `public`, и 27 настоящих терялись в шуме.
DEAD_BASELINE=""
[ -f .periphery-baseline.json ] && DEAD_BASELINE="--baseline .periphery-baseline.json"
if command -v periphery > /dev/null 2>&1; then
    check deadcode "объявления, к которым никто не обращается" 1800 \
        "periphery scan --project '$XCPROJ' --schemes '$SCHEME' --exclude-tests --retain-swift-ui-previews --disable-redundant-public-analysis --disable-update-check --strict --quiet $DEAD_BASELINE"
else
    echo "· deadcode   пропущена: periphery не установлен (brew install periphery)"
fi

# ─── 7. Сборка выпуска ───────────────────────────────────────────────────
#
# Отдельно от типов: Release собирается другими настройками оптимизации и
# с укреплённой средой исполнения. Проходящий Debug ничего о ней не говорит.
check build "сборка Release" 1200 \
    "xcodebuild $XCB_COMMON -configuration Release build"

echo
echo "────────────────────────────────────────────────────────────"
echo "Уровень: full · $(( $(date +%s) - STARTED )) с · пройдено $PASSED"
if [ -z "$FAILED" ]; then
    echo "Гейт зелёный."
    exit 0
fi
echo "Упало:$FAILED"
exit 1
