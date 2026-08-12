# Модель данных

Хранилище — локальная база `history.sqlite` в `~/Library/Application Support/VoicePaste/`,
доступ через GRDB `DatabasePool`, WAL-журнал и миграции. Файл существует только в
учётной записи macOS пользователя.

## Что обеспечивает хранилище, а что код

SQLite держит первичные ключи, индексы и триггеры синхронизации поискового
индекса — это проверено миграциями проекта. Порядок и целостность составных
операций держит код: один актор сериализует изменения истории и очереди, и
частично сохранённой расшифровки не существует.

---

## DM-settings — Настройки приложения

Одна запись в `UserDefaults`; в базе не хранится.

| Поле | Тип | Правило |
|---|---|---|
| `hotkey` | сериализуемое сочетание | Глобальное; по умолчанию `⌥Space`. |
| `recordingMode` | `toggle \| hold` | По умолчанию `toggle`. |
| `modelID` | строка | Ровно `large-v3-v20240930_626MB`. |
| `modelUnloadMinutes` | целое | От 1 до 60, по умолчанию 10; `0` означает «держать загруженной». |
| `historyEnabled` | булево | По умолчанию `true`. |
| `autoInsertEnabled` | булево | По умолчанию `true`. |
| `autoCorrectSafeTypos` | булево | По умолчанию `true`. |
| `languageMode` | `auto \| ru \| en` | По умолчанию `auto`. |

Хранилище ограничений не держит: `UserDefaults` их не умеет. Диапазоны и значения
по умолчанию держит код при чтении.

- links: TERM-settings
- impl: app:VoicePaste/Core/Settings/AppSettings.swift

## DM-transcript — Расшифровка

Таблица `transcripts`.

| Поле | Тип | Индекс и правило |
|---|---|---|
| `id` | UUID / TEXT | Первичный ключ. |
| `createdAt` | epoch ms | Индекс `createdAt DESC, id DESC` — стабильная страничная выборка. |
| `updatedAt` | epoch ms | Меняется только при правке текста. |
| `source` | `dictation \| file` | Фильтр истории. |
| `sourceFileName` | TEXT, необязательное | Только имя файла: ни пути, ни копии оригинала. |
| `durationMilliseconds` | INTEGER | Длительность входного аудио. |
| `language` | BCP-47 TEXT, необязательное | Определённый или заданный язык. |
| `rawText` | TEXT | Вывод распознавания до нормализации; в списке не показывается. |
| `text` | TEXT | Текущая редактируемая версия. |
| `preview` | TEXT | Начало текущего текста для строки списка; длина — `INV-006`. |
| `wordCount` | INTEGER | Число слов текущего текста; пересчитывается в той же транзакции. |
| `status` | `completed \| failed` | Отказ не содержит аудио. |
| `insertionOutcome` | `inserted \| copied \| notRequested` | Итог доставки для диктовки. |

Система ОБЯЗАНА записывать расшифровку, её `preview` и строку поискового индекса
в одной транзакции.

- links: TERM-transcript, TERM-insertion
- impl: app:VoicePaste/Domain/Transcript.swift, app:VoicePaste/Domain/TranscriptListItem.swift, app:VoicePaste/Data/PersistenceRecords.swift, app:VoicePaste/Data/Migrations.swift

## DM-search-index — Поисковый индекс

Таблица `transcripts_fts` — FTS5 по `text` и `sourceFileName`, синхронизируется
триггерами миграций. Ничего сверх уже сохранённого текста не содержит.

- links: TERM-search-index, TERM-transcript
- impl: app:VoicePaste/Data/Migrations.swift, app:VoicePaste/Data/HistoryStore.swift

## DM-vocabulary-entry — Запись словаря

Таблица `vocabulary_entries`.

| Поле | Тип | Правило |
|---|---|---|
| `id` | UUID / TEXT | Первичный ключ. |
| `spokenForm` | TEXT | Поиск без учёта регистра. |
| `replacement` | TEXT, необязательное | Пусто означает «это слово не исправлять». |
| `isEnabled` | BOOLEAN | По умолчанию `true`. |
| `createdAt` | epoch ms | Для сортировки. |
| `updatedAt` | epoch ms | Для корректного обновления. |

- links: TERM-vocabulary-entry
- impl: app:VoicePaste/Domain/VocabularyEntry.swift, app:VoicePaste/Data/HistoryStore.swift

## DM-import-job — Задача импорта

Таблица `import_jobs` — только активная и прерванная очередь.

| Поле | Тип | Правило |
|---|---|---|
| `id` | UUID / TEXT | Первичный ключ и имя временного каталога. |
| `createdAt` | epoch ms | Очередь FIFO; второе поле сортировки — `id`. |
| `sourceFileName` | TEXT | Только отображаемое имя, в одну строку с усечением. |
| `mediaKind` | `audio \| video` | Для иконки и диагностики; на движок не влияет. |
| `durationMilliseconds` | INTEGER, необязательное | Появляется после чтения аудиодорожки. |
| `state` | `staging \| queued \| preparing \| transcribing \| paused \| failed` | Готовая задача удаляется из таблицы после сохранения расшифровки. |
| `progress` | REAL 0…1 | Считается по обработанной длительности, а не по таймеру. |
| `stageStartedAt` | epoch ms | Для прошедшего времени и оценки остатка. |
| `lastErrorCode` | TEXT, необязательное | Короткая причина без пути и содержимого файла. |

Система ОБЯЗАНА НЕ сохранять в таблице полный URL источника, security-scoped
bookmark и текст расшифровки.

- links: TERM-import-job
- impl: app:VoicePaste/Core/Import/ImportJob.swift, app:VoicePaste/Data/ImportQueueStore.swift, app:VoicePaste/Core/Import/ImportQueueStoring.swift

## DM-usage-stats — Сводка использования

Результат одного агрегатного запроса по `createdAt`, `wordCount` и
`durationMilliseconds` за выбранный период. Тексты расшифровок агрегат НЕ читает.
Отсутствующие календарные точки периода добавляются со значением `0`.

- links: TERM-transcript
- impl: app:VoicePaste/Domain/UsageStats.swift, app:VoicePaste/Data/HistoryStore.swift

## DM-model-state — Состояние модели

Состояние локального комплекта распознавания: отсутствует, загружается,
проверяется, готова, повреждена. Хранится в памяти процесса, на диске отражается
наличием проверенных артефактов в `Application Support/VoicePaste/Models/`.

- links: TERM-model
- impl: app:VoicePaste/Core/Transcription/ModelState.swift, app:VoicePaste/Core/Transcription/LocalModelDetection.swift

## Карта файлов на диске

| Место | Содержимое | Правило |
|---|---|---|
| `Application Support/VoicePaste/history.sqlite` | история и словарь | Рядом только штатные `-wal` и `-shm`. |
| `Application Support/VoicePaste/Models/` | модель и токенизатор | Библиотека распознавания получает явный локальный путь. |
| `Caches/VoicePaste/ImportQueue/<job-id>/` | временная копия выбранного файла | Удаляется при успехе, отмене или отказе. |
| `Caches/VoicePaste/Transcoding/<job-id>/` | временно декодированный поток | Удаляется при успехе, отмене или отказе. |
| `Application Support/VoicePaste/Logs/` | короткие диагностические записи | Без аудио и без текста; ротация по размеру. |

Экспорт текста создаётся только там, где пользователь явно указал в системном
диалоге.

## Загрузка истории

- Открытие окна выполняет keyset-запрос за первой страницей по `createdAt DESC, id DESC`,
  без `OFFSET` и без `rawText`. Размер страницы — `INV-007`.
- Полный `text` и `rawText` читаются только для выбранной записи.
- Удаление записи удаляет её и строку индекса в одной транзакции; очистка
  истории — одна подтверждённая транзакция.
- Если открытие или миграция не прошли, система ОБЯЗАНА НЕ удалять файл базы
  автоматически: показывается отказ, готовый текст сохраняется в буфер обмена.
- Все операции с базой выполняет отдельный актор поверх `DatabasePool`, не
  MainActor. Периодического опроса базы в интерфейсе нет.
