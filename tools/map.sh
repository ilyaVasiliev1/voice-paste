#!/bin/sh
#
# Карта поверхности: что здесь есть и по каким правилам это живёт.
# Печатается агенту в начале работы, чтобы он не выяснял раскладку поиском.

set -u

XCPROJ="${DELTA_XCODEPROJ:-$(ls -d ./*.xcodeproj 2>/dev/null | head -1)}"
echo "# Карта поверхности"
echo
echo "Проект Xcode: ${XCPROJ:-не найден}"
echo "Схема: ${DELTA_SCHEME:-$(basename "${XCPROJ:-—}" .xcodeproj)}"
echo

echo "## Слои и их размер"
echo
for dir in $(find . -maxdepth 3 -type d -name '*' \
    -not -path './.git*' -not -path './.tmp*' -not -path './.build*' \
    -not -path './DerivedData*' 2>/dev/null); do
    count=$(find "$dir" -maxdepth 1 -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -gt 0 ] && printf -- '- %s — файлов %s\n' "${dir#./}" "$count"
done
echo

echo "## Что ввозит каждый слой"
echo
for dir in $(find . -maxdepth 2 -type d -not -path './.git*' -not -path './.tmp*' \
    -not -path './.build*' -not -path './DerivedData*' 2>/dev/null); do
    imports=$(grep -rh '^import ' "$dir" 2>/dev/null | sort -u | sed 's/^import //' | tr '\n' ' ')
    [ -n "$imports" ] && printf -- '- %s: %s\n' "${dir#./}" "$imports"
done
echo

echo "## Правила стека"
echo
echo "См. stacks/macos-swift-app/rules.md. Коротко:"
echo "- предупреждение компилятора — отказ, а не замечание"
echo "- Domain и Data не ввозят интерфейсные рамки"
echo "- принудительное развёртывание, приведение и try запрещены"
echo "- тесты не трогают установленную копию продукта"
