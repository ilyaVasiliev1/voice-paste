#!/bin/bash
# Полное удаление VoicePaste: само приложение + все пользовательские данные,
# модель распознавания (~600 МБ) и кэши. Перетаскивания в Корзину для этого
# недостаточно — данные и модель лежат вне бандла приложения.
#
# Использование:
#   bash scripts/uninstall.sh          # спросит подтверждение
#   bash scripts/uninstall.sh --yes    # без вопросов (для скриптов)
#
# Разрешения (Микрофон, Универсальный доступ) снимаются вручную — см. финал.
set -euo pipefail

BUNDLE_ID="com.ilyavasiliev.voicepaste"
APP="/Applications/VoicePaste.app"

# Всё, что приложение создаёт вне своего бандла.
TARGETS=(
  "$APP"
  "$HOME/Library/Application Support/VoicePaste"
  "$HOME/Library/Caches/VoicePaste"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
)

echo "Будут удалены VoicePaste и все его данные (включая модель ~600 МБ):"
existing=()
for path in "${TARGETS[@]}"; do
  if [ -e "$path" ]; then
    printf '  • %s (%s)\n' "$path" "$(du -sh "$path" 2>/dev/null | cut -f1)"
    existing+=("$path")
  fi
done

if [ ${#existing[@]} -eq 0 ]; then
  echo "Ничего не найдено — VoicePaste уже удалён."
  exit 0
fi

if [ "${1:-}" != "--yes" ]; then
  printf '\nПродолжить удаление? [y/N] '
  read -r answer
  case "$answer" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Отменено."; exit 0 ;;
  esac
fi

# Закрыть приложение, если запущено, чтобы файлы не держались.
osascript -e 'tell application "VoicePaste" to quit' 2>/dev/null || true
sleep 1
pkill -x VoicePaste 2>/dev/null || true

for path in "${existing[@]}"; do
  rm -rf "$path"
  echo "удалено: $path"
done

echo
echo "Готово. Файлы VoicePaste удалены."
echo "Разрешения снимаются вручную (macOS не даёт их трогать из скрипта):"
echo "  Системные настройки → Конфиденциальность и безопасность →"
echo "    • Микрофон — убрать VoicePaste"
echo "    • Универсальный доступ — убрать VoicePaste"
