#!/bin/zsh
set -euo pipefail

# Ставит собранный VoicePaste.app в /Applications и оставляет на машине ровно
# одну копию приложения.
#
# Смысл в единственности: две сборки на диске — это гарантия однажды запустить
# вчерашнюю и проверять не то, что починил.
#
#   scripts/install-local.sh [путь/к/VoicePaste.app]
#
# Без аргумента берётся сборка проверок стека — та самая, которую собрал прогон
# (`.tmp/orc-build`), а не отдельная выпускная: ставится проверенное, а не
# собранное заново с другими доводами.

PROJECT_ROOT="${0:A:h:h}"
SOURCE_APP="${1:-$PROJECT_ROOT/.tmp/orc-build/Build/Products/Debug/VoicePaste.app}"
TARGET_APP="/Applications/VoicePaste.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  print -u2 "Нет собранного приложения: $SOURCE_APP"
  print -u2 "Собери его проверкой стека: xcodebuild … -derivedDataPath .tmp/orc-build"
  exit 2
fi

# Запущенная копия держит свой бандл: переустановка под ней даёт приложение,
# которое уже не соответствует ни одной версии на диске.
if pgrep -ix voicepaste >/dev/null 2>&1; then
  print "Закрываю запущенный VoicePaste…"
  osascript -e 'tell application "VoicePaste" to quit' >/dev/null 2>&1 || true
  sleep 2
  pkill -ix voicepaste 2>/dev/null || true
fi

# Прежняя установка убирается целиком, а не перезаписывается: копирование поверх
# существующего бандла оставляет файлы, которых в новой сборке уже нет.
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"

# Подпись ad-hoc: без неё macOS отказывает приложению в правах доступности и
# микрофона, а без них продукт не работает вовсе.
codesign --force --deep --sign - "$TARGET_APP" >/dev/null 2>&1 || true

print "Поставлено: $TARGET_APP"
open "$TARGET_APP"
