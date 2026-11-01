# VoicePaste: локальное распознавание на Mac

Дата проверки: 1 ноября 2026. Только исследование официальных репозиториев, карточек моделей и документации. Модели не скачивались, качество и скорость на Mac владельца не измерялись. Страницы `main` изменяемы: перед экспериментом закрепить конкретные версии SDK и ревизии весов; не считать весь текущий каталог SDK проверенным релизом приложения.

## Вывод

Универсального подтверждённого победителя для русской диктовки с английскими терминами и шумных китайских лекций нет. Разделить интерфейс сценариев и внутренний контракт движка, но не делать каталог из десятков моделей. Для сравнительной проверки нужны три семейства: **Whisper large-v3-turbo / large-v3 как контроль**, **Qwen3-ASR 0.6B/1.7B для RU/EN/ZH**, **Parakeet Ultra/v3 для быстрой RU/EN-диктовки**. Parakeet не заменяет китайский движок.

На M5 Air 32 GB достаточно оснований проверять эти локальные варианты; это не доказательство скорости на долгой нагрузке. Нужны замеры нагрева/энергии на безвентиляторном Air, а не перенос результатов M5 Pro, серверных GPU или короткого LibriSpeech.

## Движки и веса

| Семейство | Языки и выход | Интеграция и офлайн | Размер/лицензия | Решение для VoicePaste |
|---|---|---|---|---|
| WhisperKit + Whisper large-v3-turbo / large-v3 | RU/EN/ZH; пунктуация; сегменты/word timestamps. Автодекодирование может выдумывать речь на тишине | Swift/Core ML, существующий путь VoicePaste. После получения весов работает локально | SDK MIT; turbo weights MIT. Размер зависит от конвертации/квантизации; 626 MB из текущих документов продукта не размер любого Whisper | Сохранить контрольный вариант, не менять весь движок до сравнения |
| whisper.cpp + те же Whisper | Та же модельная семья; сегменты, экспериментальные word timestamps, VAD | C/C++, Metal/Core ML, есть SwiftUI example. Локально после установки | MIT код; лицензия весов отдельно. Квантизация меняет диск/память/качество | Альтернативный runtime, если измерения покажут реальную пользу; не запускать два Whisper runtime без причины |
| FluidAudio + NVIDIA Parakeet TDT v3 / Moondream Ultra | 25 европейских языков, включая RU/EN, **без ZH**. Пунктуация, регистр, временные отметки | Swift/Core ML/ANE. Sliding windows — не то же самое, что cache-aware streaming | SDK Apache-2.0; v3/Ultra CC-BY-4.0. Ultra ~630 MB каталог, encoder 595 MB; требуется attribution NVIDIA/Moondream | Кандидат для короткой диктовки; RU+EN переключение проверить отдельно |
| FluidAudio + Parakeet Redux | Та же языковая область, не ZH | Core ML, macOS 15+; первый compile может занять минуты | ~220 MB каталог, 183 MB encoder, CC-BY-4.0 | Не выбирать автоматически ради размера: в парном замере SDK на ANE медленнее Ultra |
| Qwen3-ASR 0.6B / 1.7B + MLXAudioSTT | RU/EN/ZH; 30 языков и 22 китайских диалекта. Для точных отметок отдельный Qwen3-ForcedAligner 0.6B | Официальный runtime Qwen — Python Transformers/vLLM; **существует сторонний нативный Swift/MLX порт**, Python в приложение тащить не обязательно | Qwen weights Apache-2.0, mlx-audio-swift MIT. MLX 4-bit каталог 0.6B **713 MB**, 1.7B **1.61 GB**, aligner дополнительно | Главный новый кандидат для китайского; проверить punctuation, streaming chunk boundaries, совместимость и пиковую память |
| Apple SpeechAnalyzer / SpeechTranscriber | Длинная и дальняя речь, volatile/final результаты и audio time ranges. Поддержку RU/ZH/EN проверять через supportedLocales на целевом Mac | Нативный Swift, macOS 26+, модели управляются системой; on-device. Asset availability проверяется до записи | Системный закрытый runtime, не OSS-веса. Размер и наличие определяет AssetInventory | Полезный дополнительный baseline, но не единственный движок при поддержке macOS 15 |
| FluidAudio SenseVoiceSmall | Опубликованный Small явно перечисляет Mandarin/Cantonese/EN/JA/KO; общую фразу «50+ языков» не считать гарантией RU. Event/emotion теги не заменяют текст | Нативный Swift порт; неавторегрессионный CTC. Полные функции Python FunASR не следует приписывать порту | SDK Apache-2.0; у исходной карточки **model-license**, не безусловный Apache-2.0 | Резерв для ZH; до распространения нужны точная лицензия весов, проверка ITN/пунктуации/timestamps |
| FluidAudio Paraformer / FunASR paraformer-zh | ZH+EN; отдельные VAD, ct-punc, diarization в полном FunASR pipeline | Swift Core ML порт есть; Python full pipeline не равен одному Swift manager | Карточка paraformer-zh Apache-2.0; лицензии VAD/punctuation/diarization проверять отдельно | Возможно быстрый ZH-кандидат второй очереди, но больше деталей сборки, чем единая модель |

Источники к таблице:

- [WhisperKit, теперь argmax-oss-swift](https://github.com/argmaxinc/argmax-oss-swift), [whisper.cpp](https://github.com/ggml-org/whisper.cpp), [официальная карточка turbo и ограничения](https://huggingface.co/openai/whisper-large-v3-turbo).
- [NVIDIA Parakeet v3: языки, пунктуация, timestamps и лицензия](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [Moondream Ultra](https://huggingface.co/moondream/parakeet-ultra), [парные замеры Core ML Ultra/Redux](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md).
- [Qwen3-ASR официальный репозиторий](https://github.com/QwenLM/Qwen3-ASR), [официальная карточка 0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), [Swift ASR + ForcedAligner](https://github.com/Blaizzy/mlx-audio-swift/tree/main/Sources/MLXAudioSTT/Models/Qwen3ASR), [лицензия Swift-порта](https://github.com/Blaizzy/mlx-audio-swift/blob/main/LICENSE), [0.6B 4bit: размер](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit/tree/main), [1.7B 4bit: размер](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit/tree/main).
- [Apple: архитектура и дальняя речь](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechTranscriber: runtime locale checks](https://developer.apple.com/documentation/speech/speechtranscriber).
- [FluidAudio каталог портов](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md), [SenseVoiceSmall: исходная карточка](https://huggingface.co/FunAudioLLM/SenseVoiceSmall), [Paraformer-zh: исходная карточка](https://huggingface.co/funasr/paraformer-zh).

В каталоге FluidAudio также появились Nemotron Unified (европейские языки с batch/streaming), Nemotron Streaming Multilingual (включает ZH, без RU в перечисленном наборе), Cohere Transcribe и LFM3-Audio. Это список для наблюдения, не причина расширять первую итерацию: надо отдельно закрепить релиз, совместимость, модельную лицензию и доступность реализации. Cohere в перечисленных языках не закрывает RU. Kyutai STT ориентирован на EN/FR, поэтому не решает главный сценарий пользователя.

## Что посмотреть у готовых приложений

| Продукт | Что действительно полезно изучить | Ограничение |
|---|---|---|
| [Handy](https://github.com/cjpais/Handy) | Silero VAD → выбранный локальный Whisper/Parakeet → вставка; простой shortcut flow и история | Tauri/Rust, не SwiftUI. [MIT](https://github.com/cjpais/Handy/blob/main/LICENSE); модельные лицензии отдельно |
| [FluidVoice](https://github.com/altic-dev/FluidVoice) | Language-first onboarding, пробная диктовка, live preview, история с бюджетом хранения, статистика, local engine selection | GPLv3. Fluid Intelligence — **отдельный закрытый runtime**, не воспроизводимая часть открытого кода. fluidvoice.org официально опровергнут авторами; пользоваться altic.dev/fluid и GitHub |
| [MacParakeet](https://github.com/moona3k/macparakeet) | Ближайший набор сценариев: диктовка, файлы, встречи, timed transcripts; выбор WhisperKit для китайского; bounded recording и восстановление | GPL-3.0. В README различены stable и development; наличие кода не означает наличие функции в DMG |
| [VoiceInk](https://github.com/Beingpax/VoiceInk) | Приложение под macOS: onboarding, диктовка, модельные настройки, app-aware presets, работа с accessibility | GPLv3; изучать поведение и архитектуру, не переносить код в MIT-проект без решения о лицензии |
| [MacWhisper](https://www.macwhisper.com/) | Drop files, библиотека, просмотр/поиск расшифровки, связка записи со временем и экспорт; local models | Закрытое приложение; публичная страница подтверждает функции, не алгоритмы и не абсолютную точность |
| [Superwhisper](https://superwhisper.com/models) | Отдельные speech и language stages; явные local/cloud модели и режимы форматирования | Закрытое приложение. [Офлайн режим](https://superwhisper.com/offline-transcription) есть; cloud model и local model — разные пути |
| [Wispr Flow](https://wisprflow.ai/privacy) | Удобство короткой диктовки, контекст, clean-up и понятные контролы хранения | Транскрипция **облачная**, отключение обучения не делает её локальной. Не baseline офлайн-производительности |

## Как убрать выдуманные окончания

«Thank you», «продолжение следует» и похожие фразы нельзя просто глобально вырезать: они бывают настоящей речью. Проектное решение для проверки:

1. VAD до ASR с небольшим pre-roll/post-roll, чтобы не отрезать тихие первые/последние слоги.
2. Отдельные фикстуры: цифровая тишина, шум аудитории, музыка, длинная пауза, реальная фраза «thank you».
3. Проверять confidence/no-speech/repetition там, где runtime их предоставляет; не выдавать один и тот же порог за универсальный для всех моделей.
4. Для Whisper проверить no-speech, logprob, compression ratio и перенос контекста между окнами; это диагностические параметры, а не гарантия отсутствия галлюцинаций. Модельная карточка прямо предупреждает о галлюцинациях и повторениях.
5. Не использовать LLM для безусловного переписывания исходной лекции. Оригинальный transcript и его time ranges сохраняются; пунктуация/очищенная версия/конспект — отдельные производные с явной маркировкой.

## Минимальный честный эксперимент

Три семейства из вывода; сначала уже установленный Whisper как baseline, новые веса — только в отдельном согласованном эксперименте. На одинаковых аудио и одном Mac фиксировать:

- RU, EN и ZH раздельно; RU+EN и ZH+EN отдельно; для ZH — CER, для RU/EN — WER. Пунктуацию оценивать отдельно от нормализованного WER/CER.
- 5–30-секундная диктовка, 5–10 минут лекции, затем одна полная пара; начало/конец, тишина, дальний преподаватель, шум.
- Cold/warm start; время от отпускания shortcut до вставки; first partial и final latency; throughput; peak RAM; CPU/GPU/ANE по доступным инструментам; температура/энергия и длительная стабильность.
- Потери на стыках, timestamp drift, лишний текст на тишине, сохранность исходной записи, cancel/retry, sleep/device change, прерывание загрузки модели.
- Сетевой запрет после установки весов: распознавание и просмотр истории продолжают работать. Никакого скрытого cloud fallback.

Далёкую речь нельзя гарантированно восстановить программно, если сигнал уже потерян в шуме/реверберации. В режиме лекции нужны индикатор входного уровня, проверка первых секунд и сохранение аудио. Noise suppression сравнивать A/B: обработка может уничтожить тихую китайскую речь. Сначала надёжная запись и читаемый таймлайн, затем дополнительные конспекты/разделение говорящих.

Источники с рекламным «fastest», произвольными процентами accuracy и несопоставимыми WER в разных корпусах не использовались как доказательство превосходства. Ни одной новой модели пока не присвоен статус «лучше для пользователя».
