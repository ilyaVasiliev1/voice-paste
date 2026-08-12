# Точки входа

Сетевой службы у продукта нет. Все точки входа — местный обмен между оболочкой
приложения и локальными акторами, поэтому адрес имеет форму
`API-<канал>.<операция>`. Форма `API-<МЕТОД>-<путь>` здесь не применяется: она
описывала бы сетевую службу, которой не существует.

---

## API-readiness.observe — Наблюдение готовности

Вход: —

Выход:
```
state — одно из: ready, needsMicrophonePermission,
        needsAccessibilityPermission, needsModel, downloadingModel, error
```

Отказы: `modelMissing`, `permissionDenied`.

Пока состояние не `ready`, оболочка ОБЯЗАНА НЕ начинать запись.

- out: состояние готовности (ready, needsMicrophonePermission, needsAccessibilityPermission, needsModel, downloadingModel, error)
- links: EC-001, EC-002, EC-008, DM-model-state, TERM-readiness
- impl: app:VoicePaste/Core/Readiness/ReadinessState.swift, app:VoicePaste/Core/Readiness/ReadinessCoordinator.swift

## API-dictation.start — Начало диктовки

Вход:
```
hotkeyEvent — событие зарегистрированного сочетания
mode        — toggle | hold
```

Выход:
```
sessionId — идентификатор сессии
```

Отказы: `notReady`, `alreadyRecording`, `microphoneDenied`.

- out: sessionId — идентификатор сессии
- links: EC-001, EC-003, EC-004, EC-005, DM-settings, TERM-dictation
- impl: app:VoicePaste/Core/Dictation/DictationStateMachine.swift, app:VoicePaste/Core/Audio/AudioCaptureService.swift, app:VoicePaste/Core/Hotkey/HotkeyManager.swift, app:VoicePaste/Core/Hotkey/HotkeyShortcut.swift

## API-dictation.stop — Остановка диктовки

Вход:
```
sessionId — идентификатор сессии
```

Выход:
```
transcript — DM-transcript после обработки
```

Отказы: `emptyAudio`, `transcriptionFailed`.

- out: transcript — DM-transcript после обработки
- links: EC-004, EC-005, DM-transcript, TERM-dictation
- impl: app:VoicePaste/Core/Dictation/DictationStateMachine.swift, app:VoicePaste/Core/Transcription/Transcribing.swift, app:VoicePaste/Core/Transcription/WhisperKitTranscriber.swift

## API-insertion.insert — Доставка текста

Вход:
```
text          — готовый текст
targetSnapshot — снимок приложения, активного на старте диктовки
```

Выход:
```
outcome — inserted | copied
```

Отказы: `accessibilityDenied`, `targetUnavailable`.

Система ОБЯЗАНА использовать ровно один путь доставки за раз: либо прямую
вставку, либо буфер обмена.

- out: outcome — inserted или copied
- links: EC-002, EC-006, DM-transcript, TERM-insertion
- impl: app:VoicePaste/Core/Insertion/TextInserter.swift

## API-text.normalize — Нормализация текста

Вход:
```
rawText    — вывод распознавания
language   — auto | ru | en
vocabulary — активные записи словаря
settings   — DM-settings
```

Выход:
```
text           — нормализованный текст
appliedChanges — перечень применённых правок
```

Отказы: `spellLanguageUnavailable` — шаг проверки пропускается, текст не
блокируется.

- out: text — нормализованный текст · appliedChanges — перечень применённых правок
- links: EC-011, EC-012, DM-vocabulary-entry, DM-settings
- impl: app:VoicePaste/Core/Normalizer/TextNormalizer.swift

## API-import.enqueue — Приём файла в очередь

Вход:
```
fileURL — security-scoped адрес локального файла
origin  — mainWindow | hud
```

Выход:
```
jobId — идентификатор задачи после копирования во временный каталог
```

Отказы: `unsupportedFormat`, `insufficientStorage`, `sourceReadFailed`.

Система ОБЯЗАНА НЕ выполнять распознавание в обработчике перетаскивания или
системного диалога: управление возвращается интерфейсу сразу после приёма файла.

- out: jobId — идентификатор задачи после копирования источника
- links: EC-009, EC-010, EC-018, EC-019, DM-import-job, TERM-import-job
- impl: app:VoicePaste/Core/Import/ImportManager.swift, app:VoicePaste/Core/Import/AudioDecoder.swift

## API-import.queue — Очередь импорта

Вход:
```
action — observe | cancel | retry
jobId  — идентификатор задачи для cancel и retry
```

Выход:
```
jobs — упорядоченный перечень DM-import-job со стадией, прогрессом
       и оценкой остатка
```

Отказы: `notFound`, `cancelled`, `decodeFailed`, `transcriptionFailed`.

Один работник последовательно готовит и распознаёт задачи в фоне.

- out: jobs — упорядоченный перечень DM-import-job со стадией, прогрессом и оценкой остатка
- links: EC-013, EC-015, EC-016, EC-017, DM-import-job, TERM-import-job
- impl: app:VoicePaste/Core/Import/ImportManager.swift, app:VoicePaste/Core/Import/ImportQueueStoring.swift

## API-history.query — История

Вход:
```
action — page | search | update | delete | clear
query  — строка поиска для search, ключ страницы для page
```

Выход:
```
items — страница DM-transcript
item  — обновлённая запись для update
```

Отказы: `notFound`, `historyDisabled`.

- out: items — страница DM-transcript · item — обновлённая запись
- links: EC-014, DM-transcript, DM-search-index
- impl: app:VoicePaste/Data/HistoryStore.swift, app:VoicePaste/Domain/HistoryStoring.swift, app:VoicePaste/Core/History/FailingHistoryStore.swift

## API-history.stats — Сводка использования

Вход:
```
period — today | days7 | days30
```

Выход:
```
stats — DM-usage-stats: слова, время речи, число расшифровок, точки графика
```

Отказы: `historyDisabled`.

- out: stats — DM-usage-stats за выбранный период
- links: EC-014, DM-usage-stats
- impl: app:VoicePaste/Data/HistoryStore.swift, app:VoicePaste/Domain/UsageStats.swift

## API-model.ensure — Установка и выгрузка модели

Вход:
```
action — ensure | load | unload
source — githubRelease | huggingFaceMirror | huggingFace для ensure
```

Выход:
```
state — DM-model-state
```

Отказы: `downloadFailed`, `verificationFailed`, `insufficientStorage`.

- out: state — DM-model-state
- links: EC-007, EC-008, DM-model-state, TERM-model
- impl: app:VoicePaste/Core/Transcription/ModelManager.swift, app:VoicePaste/Core/Transcription/GitHubModelDownloader.swift, app:VoicePaste/Core/Transcription/LocalModelDetection.swift
