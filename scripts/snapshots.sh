#!/bin/zsh
# Снимки экранов приложения для визуальной проверки.
#
# Тест `ScreenSnapshots` выводит экраны в окна и пишет номер каждого окна в
# `<имя>.wid`; этот скрипт снимает окно по номеру системным `screencapture`.
# Снимает только окна приложения, не экран. Нужно право на запись экрана у
# терминала, из которого запущен скрипт.
#
#   zsh scripts/snapshots.sh <каталог для снимков>
set -euo pipefail

OUT_DIR="${1:?каталог для снимков}"
MARKER="$HOME/Library/Caches/VoicePaste/run-benchmark"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.wid(N) "$OUT_DIR"/*.png(N)

# Наблюдатель ограничен по времени сам: осиротевший фоновый процесс однажды
# уже грел Mac до перегрева.
(
  deadline=$(( $(date +%s) + 900 ))
  while (( $(date +%s) < deadline )); do
    for wid_file in "$OUT_DIR"/*.wid(N); do
      screencapture -x -o -l "$(cat "$wid_file")" "${wid_file%.wid}.png" 2>>"$OUT_DIR/watcher.log" || echo "не снято: ${wid_file:t}" >>"$OUT_DIR/watcher.log"
      rm -f "$wid_file"
    done
    sleep 0.2
  done
) &
WATCHER=$!

touch "$MARKER"
cleanup() { rm -f "$MARKER"; kill "$WATCHER" 2>/dev/null || true; }
trap cleanup EXIT

TEST_RUNNER_SNAPSHOT_DIR="$OUT_DIR" zsh "${0:A:h}/test-safely.sh" -only-testing:VoicePasteTests/ScreenSnapshots
