# Локальные движки распознавания речи для VoicePaste (Mac, Apple Silicon): сравнение

Дата исследования: 14.10.2026. Метки: [источник] — число/факт со страницы первоисточника; [вывод] — мой вывод; [не проверено] — не нашёл или не смог открыть.
Ничего не устанавливалось и не запускалось. Клонированы только WhisperKit (argmax-oss-swift) и FluidAudio в scratchpad/clones — читал код, не собирал.

## 0. Главное одной страницей

1. **Нынешняя модель — не large-v3, а large-v3-turbo.** `openai_whisper-large-v3-v20240930_626MB` в README WhisperKit названа «Large v3 Turbo (compressed)» [источник: README argmax-oss-swift, строки 192–193; каталог моделей Models.swift, default для M-серии]. В репозитории продукта то же имя (`spec/model/spec.md:404`, `LocalModelDetectionTests.swift:76`), но `docs/status.md:36` называет модель «large-v3». Turbo — 4 слоя декодера вместо 32, дообучен 2 эпохи без перевода [источник: github.com/openai/whisper/discussions/2363]. Для русского turbo, по оценке блога, на 2–4 п.п. хуже large-v3 [не проверено: блог vexascribe, без первичных цифр].
2. **Три проблемы автора лечатся сменой архитектуры, а не настройками**: пунктуация — у Parakeet v3, Canary, GigaAM-e2e, Cohere, Granite выходит из коробки; скорость — трансдьюсеры на ANE в 100–200 раз быстрее реального времени; «Продолжение следует» — свойство Whisper (авторегрессионный декодер обучен на субтитрах), у CTC/TDT-моделей такого механизма нет [вывод; прямой замер Parakeet на тишине не найден].
3. **Китайский ломает «один быстрый движок»**: Parakeet v3 (25 европейских языков) китайского не знает, Canary-1B-v2 тоже, Cohere без русского. Русский + английский + китайский вместе покрывают Whisper, Qwen3-ASR, Nemotron Streaming Multilingual (сырой), Voxtral Realtime 4B (тяжёлый).
4. **Русский на Parakeet v3 — на уровне Whisper large-v3, не лучше**: FLEURS ru 5.51 против 4.17 у Whisper large-v3, CoVoST2 ru 3.00 против 4.04 [источник: arXiv 2509.14128, таблицы 11 и 13, прочитаны локально]. Выигрыш — в скорости и пунктуации, не в точности.

## 1. Сводная таблица

WER в %, ниже — лучше. Бенчмарки разных авторов с разной нормализацией — между строками не сравнивать строго.

| Движок | ru | en | zh | Пунктуация/регистр | Скорость (Apple Silicon) | Память/размер | Тишина/галлюцинации | Streaming | Лицензия | Интеграция в Swift | Свежесть |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **WhisperKit + large-v3-turbo 626MB (сейчас)** | FLEURS ru у large-v3: 4.17 [ист]; у turbo хуже на 2–4 п.п. [не проверено] | Open ASR avg large-v3 7.44 [ист]; turbo чуть хуже | да (turbo теряет на кантонском/тайском [ист]) | да, но ненадёжна на сплошной речи [вывод] | у продукта: 0,51 с фикс + 0,063 с/с речи, 5 с речи = 0,83 с [ист: docs/status.md] | 626 МБ; RSS ~430 МБ [ист: soniqo, вендор] | `noSpeechProb` в WhisperKit зашит в 0 с TODO (TextDecoder.swift:821, коммит 9f99b5c от 10.10.2026) [ист: код]; VAD только энергетический EnergyVAD, Silero нет [ист: код] | `AudioStreamTranscriber` | MIT | уже встроен | v1.1.1, 08.10 [ист] |
| **Parakeet TDT 0.6B v3** (NVIDIA; CoreML — FluidAudio) | FLEURS 5.51, CoVoST2 3.00 [ист: карточка и paper]; в FluidAudio на M4 Pro FLEURS ru 7.2 (их скорер) [ист] | LibriSpeech clean 2.27; Open ASR avg 6.32 [ист] | **нет** (25 европейских) | **да, пунктуация и регистр** [ист: карточка] | RTFx ~150 (LibriSpeech, M5 Pro), 209.7 на FLEURS ru (M4 Pro) [ист: FluidAudio Benchmarks.md] | ~480 МБ загрузка; ~400 МБ RAM [ист: вендор soniqo] | прямых сообщений не нашёл [не проверено]; чанкер FluidAudio обрывает последнее окно на последнем речевом кадре [ист: LongTranscription.md] | пакетный, окно 15 с; скользящее окно есть; EOU только en | CC-BY-4.0 (модель) / Apache-2.0 (FluidAudio) | SPM `FluidAudio`, macOS 14+, Swift 6 [ист: Package.swift] | модель 14.08.2025; FluidAudio v0.17.7, 08.10.2026 [ист] |
| **Parakeet Ultra** (post-train v3, moondream; CoreML FluidAudio) | FLEURS ru 5.21 против 5.91 у v3 (GPU, карточка) [ист]; FluidAudio: −1.3 п.п. к v3 [ист] | clean 2.13 / other 3.81 [ист] | нет | как у v3 | ~127× на test-clean, как v3 [ист] | encoder int8 595 МБ [ист] | как v3 | как v3 | CC-BY-4.0 | `AsrModelVersion.ultra` (с v0.17.3, 24.09.2026) | молодой: ~3 недели [ист] |
| **Qwen3-ASR 0.6B / 1.7B** (Alibaba) | FLEURS ru 1.7B **5.99**, 0.6B 9.91; CommonVoice ru 8.28 / 14.07 [ист: arXiv 2601.21337, табл. A.2, прочитана локально] | clean 1.63 [ист] | **да**, FLEURS zh 2.41 против 4.09 у Whisper v3 [ист: карточка] + 22 диалекта | вывод модели — с пунктуацией и регистром (пример в статье) [ист: paper §2.2]; надёжность не измерена [не проверено] | RTF 0.014 (0.6B, 5-bit, M5 Pro) против 0.084 у WhisperKit turbo на том же замере [ист: вендор soniqo — не независимо] | 0.6B 4-bit MLX ~0.7–1.0 ГБ; 1.7B 5-bit ~1.9 ГБ [ист: вендор] | **обучен выдавать пустой ответ `language None` на «нет речи»** [ист: paper §2.2]; поведение на тишине не измерено [не проверено] | есть, но только через vLLM [ист: карточка] | Apache-2.0 | сторонний `speech-swift` (MLX; ветка main, без тегов, macOS 15+) [ист: README] | модель 29.01.2026 [ист] |
| **GigaAM v3** (Сбер) | вендор-бенчмарк: e2e-RNNT avg 11.2 против 21.0 у Whisper*; FLEURS ru у GigaAM Multilingual 600M 3.0 против 3.1 Whisper v3 [ист: evaluation.md, прочитан] | слабый | нет | **e2e-варианты: да** [ист] | CoreML-конверсия сообщества: 25 с аудио за 102 мс (MacBook Air 8 ГБ), 245× [ист: карточка автора] | 422 МБ fp16 [ист] | прямых замеров на тишине нет [не проверено]; фраз «из субтитров» у CTC/RNNT быть не должно по устройству [вывод] | нет | MIT | **только CoreML-конверсии сообщества**, фикс. окно 25 или 30 с, мел-спектрограмму и CTC/RNNT-декодер писать самому [ист: карточки inhum, maxhlv] | v3 — 2025; Multilingual — июнь 2026 [ист] |
| **Apple SpeechTranscriber** (macOS 26+) | **Не подтверждено**: второстепенный источник (LoroNote, заинтересован) говорит «42 локали, 22 языка, русский есть» [не проверено]; первичный список Apple не получен | LibriSpeech clean 2.12 / other 4.56 (сторонний замер, M2 Pro, июль 2026) [ист: блог rohitraj/addpipe] | да (zh в списке запуска) | авто, подробностей первоисточник не даёт [не проверено] | 12–40× реального времени, M2 Pro; 34-мин видео за 45 с [ист: блог] | модель системная, не в памяти приложения [ист: Apple/WWDC-конспект] | не измерено [не проверено] | да | системная | `import Speech`, macOS **26.0+** [ист: Apple docs]; продукт сейчас macOS 15+ → нужен запасной путь | WWDC25 |
| **whisper.cpp** (+ CoreML-энкодер, Metal) | как Whisper | как Whisper | да | как Whisper | энкодер на ANE «>×3 к CPU» [ист: README] | ggml, квантизация q5_0 | есть опция `--vad` (Silero) [ист: README] | нет | MIT | XCFramework / `whisper.spm` | v1.9.5, 06.10 (год на странице не указан) [ист] |
| **MLX-whisper / mlx-audio** | как Whisper | — | да | как Whisper | — | — | — | — | MIT | Swift-STT в mlx-audio не описан [ист: README] | релизов на странице нет |
| **Canary-1B-v2** (NVIDIA) | FLEURS ru 6.90, CoVoST ru 5.14 [ист: paper табл. 11, 13] | 7.15 avg [ист] | нет | да | RTFx 749 [ист] | ~1B | — | нет | CC-BY-4.0 | в FluidAudio есть (Canary/) [ист: дерево репо] | 14.08.2025 |
| **Canary-Qwen 2.5B** | только английский [ист: вторичный обзор] | 5.63 avg | нет | — | RTFx 418 | 2.5B | — | — | — | нет CoreML [не проверено] | — |
| **Cohere Transcribe 03-2026** | **нет русского** (14 языков, есть zh) [ист: карточка] | 5.42 avg | да | да, по умолчанию | RTFx 525 | 2B; CoreML int8 энкодер 1.8 ГБ (бета) [ист: FluidAudio docs] | — | нет | Apache-2.0 | FluidAudio (бета) | 26.03.2026 |
| **Granite Speech 4.1 2B** (IBM) | **нет русского** (en fr de es pt ja) [ист: карточка] | 5.33 avg | нет | да | — | 2B | — | — | Apache-2.0 | нет | 29.04.2026 |
| **Voxtral Mini 3B (2507)** | не заявлен [ист: карточка]; в paper NVIDIA для ru пусто [ист] | 7.05 avg Open ASR | нет | — | RTF 0.074, M5 Pro [ист: вендор soniqo] | 3B (5B в метаданных), ~9.5 ГБ GPU bf16 | — | нет | Apache-2.0 | в speech-swift | 07.2025 |
| **Voxtral Mini 4B Realtime (2602)** | 13 языков, ru и zh есть; FLEURS avg 8.72 при 480 мс [ист: карточка] | 5.05 (Meanwhile) | да | — | потоковый, 80 мс–2.4 с | 4B BF16 | — | **да** | Apache-2.0 | ExecuTorch «не тестировано» [ист: карточка] | 02.2026 |
| **Nemotron ASR Streaming Multilingual 0.6B** | ~40 языков, ru и zh-CN есть [ист: FluidAudio NemotronMultilingual.md]; карточка NVIDIA за авторизацией (401) [не проверено] | 3.2–3.6 LibriSpeech [ист: FluidAudio] | да (CER 18.6 FLEURS) | — | RTFx 76–147 (M5 Pro) | 0.6B, int8 | — | **да**, 560/1120/2240 мс | — [не проверено] | **только локальный путь**, репозитория на HF нет, «intermediate checkpoint, May 2026» [ист] | сырой |
| **Moonshine** | русского в списках нет (ar, zh, ja, ko, es, uk, vi) [ист: paper 2509.02523, поиск] | да | да (CER ~26 — слабо) | — | — | tiny/base 27–61M | — | да | MIT; нерусские модели — некоммерческая [ист] | macOS в списке платформ, Swift не описан | — |
| **SenseVoice-Small** | **нет** (zh, yue, en, ja, ko) [ист: карточка] | LibriSpeech 3.22 [ист: FluidAudio] | AISHELL-1 3.09 CER | да (ITN) | 299× [ист: FluidAudio] | ≈ Whisper-small | — | — | model-license [не проверено] | FluidAudio (`SenseVoice/`) | 07.2024 |
| **Kyutai STT** | **нет** (en; en/fr) [ист: карточки] | — | — | — | — | 1–2.6B | — | да | CC-BY-4.0 | MLX-порт не проверял [не проверено] | — |
| **T-one** (Т-Банк) | телефония: Call-center 8.63, CommonVoice 19: 5.32 [ист: README] | нет | нет | **нет** (алфавит без знаков) [ист] | — | 71M | — | да, 300 мс | Apache-2.0 | нет CoreML [не проверено] | — |
| **Vosk** | — [не проверено, не открывал] | — | — | нет (из практики, [не проверено]) | — | — | — | — | Apache-2.0 | — | — |
| **Fine-tune antony66/whisper-large-v3-russian** | CV17 WER 6.39 против 9.84 у large-v3 [ист: карточка] | хуже [вывод] | не предназначен | не описана | как large-v3 | 1.5B | как Whisper | — | не указана | **CoreML-конверсии не найдено** [ист: поиск]; путь — `whisperkit-generate-model` [не проверено] | WIP, автор сам так пишет |

## 2. По кандидатам

### 2.1 WhisperKit (Argmax OSS SDK)
Версии: v1.0.0 (01.05.2026, переименование в `argmax-oss-swift`, Swift 6), v1.1.0 (06.08, инкрементальная загрузка, −70% памяти на 3 ч аудио), v1.1.1 (08.10, правки падений) [источник: GitHub Releases; год выведен по дате HEAD репо 10.10.2026]. Лицензия MIT, нижняя граница macOS 14 [источник: README].
Модели в каталоге (папки `argmaxinc/whisperkit-coreml`, размеры из имён): `large-v3_947MB`, `large-v3_turbo_954MB`, `large-v3-v20240930_547MB`, `_626MB`, `_turbo_632MB`, `distil-large-v3_594MB`, `distil-large-v3_turbo_600MB` [источник: дерево HF + Models.swift]. README рекомендует `_626MB` «для максимальной точности» и `_turbo` «на macOS для скорости и точности» [источник]. Что значит суффикс `_turbo` у Argmax, я не выяснил [не проверено].
Опции декодирования: `suppressBlank`, `noSpeechThreshold`, `logProbThreshold`, `compressionRatioThreshold`, `firstTokenLogProbThreshold`, `promptTokens`, `prefixTokens`, `chunkingStrategy: .vad` [источник: Configurations.swift]. **Но `noSpeechProb` в CoreML-декодере зашит в 0** (`TextDecoder.swift:821`: «TODO: implement no speech prob»), поэтому `noSpeechThreshold` фактически не работает [источник: код]. Комментарий в `WhisperKitTranscriber.swift` продукта верен.
Вывод: чинить через WhisperKit можно (promptTokens с пунктуированной затравкой — приём сообщества, [не проверено в источниках сессии]; внешний Silero-VAD до модели; обрезка хвоста уже есть), но причина галлюцинаций — сама архитектура Whisper. Для сравнения: VAD-предобработка снижает галлюцинации (WhisperX), но Silero VAD v5 даёт лишь 61% точности на шуме ESC-50 [источник: Calm-Whisper, arXiv 2505.12969, через сводку поиска].

### 2.2 whisper.cpp, MLX-whisper
whisper.cpp: Core ML-энкодер даёт «более ×3 к CPU», Metal, квантизация, `--vad` на Silero, XCFramework для SPM [источник: README]. Последний тег v1.9.5, 06.10 [год на странице не показан]. Тот же Whisper — те же галлюцинации; плюс только внешний Silero-VAD встроен. Замена WhisperKit на него смысла не даёт [вывод]. mlx-audio: список STT очень широк (Whisper, Parakeet, Qwen3-ASR, Voxtral, Canary, Granite…), но Swift-путь описан только для TTS [источник: README].

### 2.3 Parakeet TDT 0.6B v3 + FluidAudio
Модель: 25 европейских языков с автоопределением, пунктуация и регистр в выводе, CC-BY-4.0, 08/14/2025 [источник: HF карточка]. Окно 15 с, длинное аудио режется с перекрытием 2 с, границы ищутся по тишине [источник: FluidAudio LongTranscription.md]. Русский: FLEURS 5.51 (greedy, без LM) [источник: карточка]; в замере FluidAudio на M4 Pro — 7.2 / CER 2.2 [источник: Benchmarks.md]; расхождение — другой скорер/нормализация [вывод].
Сравнение с Whisper large-v3 в статье NVIDIA (Table 11, колонка ru): Whisper 4.17, Parakeet v3 5.51, Canary-1B-v2 6.90, Seamless v2 7.43. CoVoST2 ru: Whisper 4.04, Parakeet 3.00 [источник: arXiv 2509.14128, прочитано по сохранённому PDF].
FluidAudio: Apache-2.0, SPM, `macOS(.v14)`, Swift tools 6.0, ASR+VAD без лишнего через `traits: []` [источник: README, Package.swift]. Модели грузятся с Hugging Face; хост переопределяется `ModelRegistry.baseURL`/`REGISTRY_URL`, есть `offlineMode` [источник: README] — совместимо с имеющимся у продукта `GitHubModelDownloader` (раздача одним архивом с GitHub Release) [вывод]. Размер ~480 МБ [источник: FluidAudio Benchmarks.md].
Не подтверждено: поведение на 100% тишине и на шуме; задержка одного вызова на коротком клипе (RTFx замерены на длинных наборах); качество русского на разговорной речи автора.

### 2.4 Parakeet Ultra / Redux / Phonon-2 (FluidAudio)
v0.17.3 (24.09.2026): Ultra — «пост-обучение v3, точнее везде при той же скорости», encoder int8 595 МБ; Redux — тернарный, 183 МБ, но русский +2.57 п.п. хуже [источник: ParakeetRedux.md]. FLEURS по 24 языкам: v3 14.81, Redux 13.06, Ultra 11.67 [источник]. Русский: Ultra −1.3 п.п. к v3 [источник: ParakeetUltra.md]; в карточке moondream 5.21 против 5.91 (замер на GPU, не на Mac) [источник]. Лицензия CC-BY-4.0. Phonon-2 — только английский [источник]. Рекомендация вендора — Ultra для новых интеграций [источник: release v0.17.3]. Возраст — три недели: [вывод] брать v3 как опору, Ultra — как кандидата в бейкоффе.

### 2.5 Qwen3-ASR
52 языка и диалекта (30 языков, 22 китайских диалекта); русский, китайский, английский — в списке; макс. 1200 с на вызов; Apache-2.0; релиз 29.01.2026, обновление Transformers-поддержки 26.06.2026 [источник: README, paper Table 1]. Русский: FLEURS 5.99 (1.7B) / 9.91 (0.6B); CommonVoice 8.28 / 14.07; MLC-SLM 15.17 / 19.24 [источник: paper, табл. A.2]. Сводно: Multilingual FLEURS (12 языков) 4.90 против 5.27 у Whisper v3 [источник: карточка]. Китайский сильный (FLEURS zh 2.41 против 4.09).
Особенность: на этапе SFT обучали выдавать `language None` + пустой текст, когда речи нет [источник: paper §2.2] — прямо адресует проблему галлюцинаций, но эффективность на тишине автора не измерена [не проверено].
Запуск на Mac: официальный код — PyTorch/vLLM; MLX/CoreML — сторонний `speech-swift` (soniqo, Apache-2.0, macOS 15+, зависимость по ветке `main`, релизов-тегов нет, веса с HF `aufklarer/*`, `HF_ENDPOINT` для зеркала) [источник: README speech-swift]. Скорость RTF 0.012–0.014 на M5 Pro — заявление самого проекта [источник: soniqo.audio/faq, /benchmarks]. Независимых замеров на русском не нашёл [не проверено].

### 2.6 Apple SpeechAnalyzer / SpeechTranscriber
Доступность: macOS/iOS 26.0+, класс `SpeechTranscriber`; `DictationTranscriber` — для языков старого SFSpeechRecognizer [источник: developer.apple.com, speechtranscriber.md]. Модели системные, ставятся через `AssetInventory`, не лежат в памяти приложения [источник: конспект WWDC25 / yrocaz research note]. Известные ограничения: нет кастомного словаря, одновременных анализаторов — «консервативное число», `.offlineTranscription` из WWDC нет в SDK, на macOS 26.3 был баг `start(inputSequence:)` [источник: yrocaz research note, 27.07.2026].
Языки: **в первичных источниках списка нет** (`supportedLocales` читается только в рантайме; в Simulator пусто). Запуск-список 10 языков без русского [источник: addpipe, второстепенный]; позднее утверждение «42 локали / 22 языка, русский есть» — только от LoroNote (продаёт Whisper-приложение, заинтересован) [не проверено]. Проверка одним вызовом на Mac владельца (macOS 27): напечатать `SpeechTranscriber.supportedLocales`.
Качество (сторонний замер, июль 2026, LibriSpeech, M2 Pro): clean 2.12 / other 4.56 — лучше Whisper small [источник: блоги]; на русском данных нет. Пунктуация — первоисточник молчит [не проверено]. Нижняя граница macOS 26 против macOS 15 у продукта — нужна запасная ветка.

### 2.7 GigaAM (Сбер) и другие русские
Версии: v1 (wav2vec2), v2 (HuBERT-CTC), v3 (700 тыс. ч предобучения, 4 тыс. ч ASR), Multilingual (июнь 2026; 70+ языков), все MIT [источник: README]. Варианты v3: `ctc`, `rnnt`, `e2e_ctc`, `e2e_rnnt`; e2e выдают пунктуацию и нормализованный текст [источник: карточка ai-sage/GigaAM-v3].
Бенчмарк вендора (evaluation.md): средний WER по 9 наборам v3-RNNT 8.3, e2e-RNNT 11.2, Whisper* (с постобработкой) 21.0, T-One+LM 16.3. На Common Voice 19 ru: v3-RNNT 0.9, e2e-RNNT 3.0, Whisper 5.5; на Golos crowd — 2.3 / 9.1 / 19.0 [источник]. **Оговорки**: набор частично in-domain для GigaAM (Golos — датасет Сбера), версия Whisper не названа, e2e считается с пунктуацией и потому хуже [вывод]. На FLEURS (мультиязычный протокол) GigaAM Multilingual 600M 3.0 против Whisper v3 3.1 — паритет [источник].
Формат: официально PyTorch + `to_onnx` (fp32); CoreML — только сообщество: `inhum/gigaam-v3-coreml` (e2e-CTC, fp16, окно 25 с, 422 МБ, нужно самому считать лог-мел по таблицам из репо и жадный CTC), `maxhlv/` и `huggingfinger0/gigaam-v3-coreml` (RNN-T, int8, окно 30 с) [источник: карточки]. Автор конверсии: «не обещаю поддержку будущих версий», английские слова транслитерируются [источник]. `onnx-asr` (MIT) поддерживает GigaAM v2/v3 на macOS через CoreML EP [источник: README onnx-asr]; в sherpa-onnx — модели GigaAM v2 (2024-10-24), Apache-2.0, Swift API [источник: README sherpa-onnx].
T-one: 71M, телефония, **без пунктуации** [источник]. Vosk — не открывал [не проверено].
Итог: лучший чистый русский на «естественной» речи, но только русский (автор пишет и по-английски, и по-китайски) и без готового Swift-пакета.

### 2.8 Остальное
- **Voxtral Mini 3B 2507**: русского нет в заявленных языках [источник: карточка]. **Voxtral Mini 4B Realtime 2602**: 13 языков с ru и zh, FLEURS в среднем 8.72 при 480 мс; на Mac — ExecuTorch «не тестировалось»; 4B BF16 [источник: карточка]. Для диктовки на ноутбуке тяжело [вывод].
- **Moonshine**: нет русского; нерусские модели — некоммерческая лицензия [источник].
- **SenseVoice / Paraformer**: китайский (CoreML в FluidAudio, 299× / 85×, AISHELL-1 3.09 / 2.12 CER) [источник: Benchmarks.md]; русского нет.
- **Kyutai STT**: en, en/fr [источник].
- **Cohere Transcribe, Granite 4.1**: хороши по английскому (5.42 / 5.33 avg на Open ASR), русского нет [источник].
- **Canary-Qwen 2.5B**: английский [источник: вторичный обзор].
- **Open ASR Leaderboard**: мультиязычная дорожка — de, fr, it, es, pt; **русского там нет** [источник: arXiv 2510.06961 v3]. Русские цифры приходится брать из карточек и статей отдельных моделей.
- **Файнтюн antony66**: CoreML-конверсии нет; автор сам называет работу «в процессе» [источник].
- **Облако (гибрид)**: не исследовал — gpt-4o-transcribe, Yandex SpeechKit и др. [не проверено]; цифры по русскому не нашёл.

## 3. Привязка к трём проблемам автора

| Проблема | Причина | Что лечит |
|---|---|---|
| Нет пунктуации | Whisper на длинной русской речи без затравки склонен к потоку [вывод]; у модели нет явной цели «пунктуация» | Parakeet v3/Ultra, Canary, GigaAM-e2e, Granite, Cohere — пунктуация встроена [источник: карточки]. Для Whisper — `promptTokens` [не проверено] |
| Медленно | Whisper всегда кодирует окно 30 с; у продукта 0,51 с фикс на вызов [источник: docs/status.md] | FastConformer/TDT на ANE: RTFx 150–210 [источник: FluidAudio]; чистое ожидание для 5 с речи — порядка десятков мс [вывод, замерить] |
| «Продолжение следует», «Субтитры делал…» | Whisper обучен на видео с субтитрами; Silero-VAD пропускает часть шума [источник: Calm-Whisper] | Другая архитектура (Parakeet/GigaAM/Qwen3); продукт уже имеет `TrailingHallucinationFilter` + `SubtitleCreditFilter` — признак борьбы с симптомом |

## 4. Рекомендованный бейкофф (не выполнялся)
1. Записи автора (приватные фикстуры продукта): русские короткие (5–15 с), русские длинные (60–120 с), английские, китайские лекции, 100% тишина, тишина в конце, шум.
2. Движки: текущий turbo-626MB; `large-v3_947MB`; `_turbo_632MB`; Parakeet v3; Parakeet Ultra; Qwen3-ASR 0.6B и 1.7B (speech-swift); SpeechTranscriber (если ru есть).
3. Метрики: время от конца записи до готового текста (с холодным и тёплым стартом), WER на размеченных 10–20 фразах, доля вставок на тишине, пунктуация (ручная оценка 20 фраз), пик памяти.
4. Скорость мерить на Mac владельца; туннель на локальный инференс не влияет (только загрузка моделей) [вывод].

## 5. Что осталось неподтверждённым
- Есть ли русский в `SpeechTranscriber.supportedLocales` и как он ставит пунктуацию — читается только на macOS 26+.
- Поведение Parakeet v3/Ultra и Qwen3-ASR на тишине и шуме — прямых замеров не нашёл.
- Реальная задержка одного вызова Parakeet на 3–10 с речи на M-серии: FluidAudio публикует RTFx по длинным наборам.
- Качество Whisper turbo именно на русском (первичной цифры нет; график OpenAI — картинка).
- Что означает суффикс `_turbo` у Argmax и даст ли `_turbo_632MB` ускорение на «текущей» модели.
- Nemotron Multilingual Streaming: карточка закрыта (401), весов CoreML публичных нет.
- Vosk; облачные ASR (Yandex, OpenAI) — не исследовались.
- Независимые цифры RTF Qwen3-ASR на Mac: все числа — самого проекта speech-swift.
- Надёжность скачивания моделей из Китая без VPN: хост переопределяется (FluidAudio, speech-swift — `HF_ENDPOINT`), но фактическую доступность зеркал не проверял.

## 6. Прочитанные источники
- WhisperKit: https://github.com/argmaxinc/WhisperKit (README, releases), клон argmax-oss-swift (HEAD 9f99b5c, 10.10.2026): Sources/WhisperKit/Core/TextDecoder.swift, Configurations.swift, Models.swift, Audio/EnergyVAD.swift; https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main
- FluidAudio: https://github.com/FluidInference/FluidAudio (README, releases v0.17.x, клон HEAD 224de0f 14.10.2026, Package.swift), Documentation/Benchmarks.md, ASR/ParakeetUltra.md, ASR/ParakeetRedux.md, ASR/LongTranscription.md, ASR/NemotronMultilingual.md, ASR/Cohere.md
- NVIDIA: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3, https://huggingface.co/nvidia/canary-1b-v2, arXiv 2509.14128 (PDF, таблицы 11–13)
- https://huggingface.co/moondream/parakeet-ultra, https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- Open ASR Leaderboard: https://github.com/huggingface/open_asr_leaderboard, arXiv 2510.06961 v3
- Qwen3-ASR: https://github.com/QwenLM/Qwen3-ASR, https://huggingface.co/Qwen/Qwen3-ASR-1.7B, arXiv 2601.21337 (PDF)
- speech-swift: https://github.com/soniqo/speech-swift, https://soniqo.audio/faq, https://soniqo.audio/benchmarks/qwen3-asr-vs-whisper (вендор)
- GigaAM: https://github.com/salute-developers/GigaAM (README, evaluation.md), https://huggingface.co/ai-sage/GigaAM-v3, https://huggingface.co/inhum/gigaam-v3-coreml, https://huggingface.co/maxhlv/gigaam-v3-coreml, https://huggingface.co/huggingfinger0/gigaam-v3-coreml, https://github.com/istupakov/onnx-asr, https://github.com/k2-fsa/sherpa-onnx, https://github.com/voicekit-team/T-one
- Apple: https://developer.apple.com/documentation/speech/speechtranscriber.md; блоги (второстепенные): blog.addpipe.com/apple-speechanalyzer-api, rohitraj.tech (июль 2026), loronote.com (08.2026, заинтересован), github.com/yrocaz/mac-transcriber research note (27.07.2026)
- Whisper: https://github.com/openai/whisper/discussions/2363; https://github.com/ggml-org/whisper.cpp (README, releases); https://huggingface.co/antony66/whisper-large-v3-russian; vexascribe.com (блог, слабый источник)
- Прочее: https://huggingface.co/mistralai/Voxtral-Mini-3B-2507, .../Voxtral-Mini-4B-Realtime-2602, https://huggingface.co/CohereLabs/cohere-transcribe-03-2026, https://huggingface.co/ibm-granite/granite-speech-4.1-2b, https://github.com/moonshine-ai/moonshine, https://huggingface.co/FunAudioLLM/SenseVoiceSmall, https://huggingface.co/kyutai/stt-2.6b-en, https://github.com/snakers4/silero-models, https://github.com/Blaizzy/mlx-audio
- Продукт (локально): projects/voice-paste/VoicePaste/Core/Transcription/WhisperKitTranscriber.swift, docs/status.md, spec/model/spec.md, VoicePasteTests/LocalModelDetectionTests.swift
- Галлюцинации: arXiv 2501.11378, arXiv 2505.12969 (через сводку поиска, сами статьи целиком не читал)

Оговорка по способу чтения: страницы открывались инструментом, который пересказывает их малой моделью; числа из таблиц, на которые опирается вывод (arXiv 2509.14128, 2601.21337, FluidAudio Benchmarks/Ultra), перепроверены по исходным PDF/файлам репозитория.
