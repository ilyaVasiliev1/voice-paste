#!/bin/zsh
set -euo pipefail

# Набор для сравнения движков без голоса владельца: фразы с известным текстом,
# прочитанные системными голосами macOS, плюс тишина и шум. Чище живой записи с
# микрофона — по нему сравнивают движки между собой, а не обещают качество на голосе.
#
#   scripts/make-bakeoff-set.sh [каталог]     # по умолчанию ~/Library/Caches/VoicePaste/Bakeoff/clips

OUT="${1:-$HOME/Library/Caches/VoicePaste/Bakeoff/clips}"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

typeset -a RU=(
  "Привет, это проверка диктовки. Сегодня мы обсудим план работы на неделю."
  "Нужно отправить письмо клиенту до конца рабочего дня, а потом позвонить в бухгалтерию."
  "Завтра в десять утра у нас встреча, пожалуйста, подготовьте отчёт и презентацию."
  "Я думаю, что этот подход лучше, потому что он проще и быстрее."
  "Скажите, пожалуйста, как пройти к ближайшей станции метро?"
  "В прошлом месяце мы закончили первый этап, и теперь начинаем второй."
  "Купить молоко, хлеб, сыр и яблоки, затем зайти в аптеку."
  "Если что-то пойдёт не так, сразу напишите мне, я постараюсь помочь."
  "Это очень важное решение, поэтому давайте обсудим его спокойно и без спешки."
  "Программа должна работать быстро, не зависать и не терять введённый текст."
  "Погода сегодня хорошая, светит солнце, но к вечеру обещают дождь."
  "Сначала откройте настройки, потом выберите нужный пункт и сохраните изменения."
  "Москва находится на реке Москве, а Санкт-Петербург стоит на Неве."
  "Мы договорились встретиться в субботу, если никто не передумает."
  "Пожалуйста, проверьте документ ещё раз и исправьте все ошибки."
  "Спасибо за помощь, без вас мы бы не справились так быстро."
)
typeset -a ZH=(
  "今天天气很好，我们一起去公园散步吧。"
  "请把这份文件发给我，谢谢你的帮助。"
  "明天下午三点我们开会，请准时参加。"
  "我正在学习中文，希望可以说得更流利。"
)
typeset -a EN=(
  "Please send me the report by the end of the day."
  "The weather is nice today, so let us go for a walk."
  "I think this approach is simpler and faster than the previous one."
  "Thank you for your help, we could not have done it without you."
)

python3 -I - "$OUT" <<'PY'
import sys, wave, random, struct, os
out = sys.argv[1]
rate = 16000
random.seed(7)
def write(name, samples):
    with wave.open(os.path.join(out, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))
write("silence-5s.wav", [0] * (rate * 5))
write("noise-5s.wav", [int(random.gauss(0, 400)) for _ in range(rate * 5)])
PY

typeset -a MANIFEST=()
make_clip() {
  local id="$1" voice="$2" lang="$3" text="$4"
  say -v "$voice" -o "$WORK/$id.aiff" -- "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/$id.aiff" "$OUT/$id.wav"
  MANIFEST+=("$id	$lang	$text")
}
i=0; for t in "${RU[@]}"; do i=$((i+1)); make_clip "ru-$(printf %02d $i)" Milena ru "$t"; done
i=0; for t in "${ZH[@]}"; do i=$((i+1)); make_clip "zh-$(printf %02d $i)" Tingting zh "$t"; done
i=0; for t in "${EN[@]}"; do i=$((i+1)); make_clip "en-$(printf %02d $i)" Samantha en "$t"; done
MANIFEST+=("silence-5s	none	")
MANIFEST+=("noise-5s	none	")

printf '%s\n' "${MANIFEST[@]}" | python3 -I -c "
import sys, json
rows = []
for line in sys.stdin:
    cid, lang, text = (line.rstrip('\n').split('\t') + ['', ''])[:3]
    rows.append({'id': cid, 'language': lang, 'text': text})
json.dump(rows, open('$OUT/manifest.json', 'w'), ensure_ascii=False, indent=1)
print(len(rows), 'клипов в', '$OUT')
"
