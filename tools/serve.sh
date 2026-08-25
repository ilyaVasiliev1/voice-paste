#!/bin/sh
#
# Поднять собранное приложение, чтобы агент посмотрел на свою работу.
#
# Восьмой ответ стека (`canon/stacks.md`): семь проверок судят код, но задача
# не доведена, пока продукт не подняли и не посмотрели.
#
# Три правила, и все три здесь исполняются:
#
#   1. Поднимается СОБРАННОЕ, а не установленное. Рабочая копия человека —
#      не предмет агента, и трогать её нельзя ни при каком исходе.
#   2. Поднятое гасится — этим занимается tools/unserve.sh.
#   3. Двух копий не бывает. Если у человека работает своя, поднятая обязана
#      ей не мешать. Как именно — знает продукт: он объявляет переменную
#      окружения тихого режима файлом tools/serve.env, и здесь она читается,
#      а не угадывается.

set -u

ROOT=$(pwd)
DERIVED="${DELTA_DERIVED_DATA:-.tmp/delta-verify}"
APP=$(ls -d "$DERIVED"/Build/Products/Debug/*.app 2>/dev/null | head -1)

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "Собранного приложения нет в $DERIVED/Build/Products/Debug." >&2
    echo "FIX: собери сперва — «sh tools/verify.sh fast» собирает Debug." >&2
    exit 2
fi

NAME=$(basename "$APP" .app)
BINARY="$APP/Contents/MacOS/$NAME"
if [ ! -x "$BINARY" ]; then
    echo "В пакете $APP нет исполняемого файла $NAME." >&2
    exit 2
fi

# Тихий режим объявляет продукт, а не стек: как приложению не мешать
# работающей копии — знание продукта. Файла нет — поднимаем как есть,
# и это законно для продукта, у которого установленной копии не бывает.
if [ -f tools/serve.env ]; then
    # shellcheck disable=SC1091
    . ./tools/serve.env
fi

echo "Поднимаю $APP"
"$BINARY" > "$DERIVED/serve.log" 2>&1 &
PID=$!
echo "$PID" > "$DERIVED/serve.pid"

# Живость, а не «команда не упала»: процесс обязан пережить первые секунды.
# Приложение, падающее на старте, иначе считалось бы поднятым.
waited=0
while [ "$waited" -lt 10 ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "Приложение завершилось через ${waited} с после запуска." >&2
        echo "Вывод: $DERIVED/serve.log" >&2
        tail -20 "$DERIVED/serve.log" >&2
        rm -f "$DERIVED/serve.pid"
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done

echo "Поднято: pid $PID · вывод $DERIVED/serve.log"
echo "Погасить: sh tools/unserve.sh"
