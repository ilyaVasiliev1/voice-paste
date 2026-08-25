#!/bin/sh
#
# Погасить поднятое tools/serve.sh.
#
# Гасится ровно тот процесс, который подняли, — по записанному номеру,
# а не по имени. Гасить по имени значило бы задеть рабочую копию человека,
# у которой имя то же самое.

set -u

DERIVED="${DELTA_DERIVED_DATA:-.tmp/delta-verify}"
PIDFILE="$DERIVED/serve.pid"

if [ ! -f "$PIDFILE" ]; then
    echo "Поднятого экземпляра нет: $PIDFILE отсутствует."
    exit 0
fi

PID=$(cat "$PIDFILE")
if ! kill -0 "$PID" 2>/dev/null; then
    echo "Процесс $PID уже не работает."
    rm -f "$PIDFILE"
    exit 0
fi

kill -TERM "$PID" 2>/dev/null || true
waited=0
while kill -0 "$PID" 2>/dev/null; do
    if [ "$waited" -ge 10 ]; then
        kill -KILL "$PID" 2>/dev/null || true
        break
    fi
    sleep 1
    waited=$((waited + 1))
done

rm -f "$PIDFILE"
echo "Погашено: pid $PID"
