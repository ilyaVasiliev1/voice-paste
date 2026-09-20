# Карта

Что где лежит и куда смотреть дальше. Здоровье и блокеры — `status.md`,
решения — `decisions.md`, что продукт обязан делать — `../spec/`.

## Слои

| Слой | Где | Объём | За что отвечает |
|---|---|---|---|
| App | `VoicePaste/App/` | 4 файла, 1325 строк | Точка входа, сборка зависимостей, единственный экземпляр, маршрутизация окон |
| Core | `VoicePaste/Core/` | 30 файлов, 6023 строки | Вся логика продукта, разложенная по доменам |
| Data | `VoicePaste/Data/` | 6 файлов, 945 строк | SQLite через GRDB: схема, миграции, хранилища |
| Domain | `VoicePaste/Domain/` | 6 файлов, 366 строк | Модели без зависимости от GRDB и AppKit |
| UI | `VoicePaste/UI/` | 12 файлов, 2119 строк | SwiftUI-экраны |
| Тесты | `VoicePasteTests/` | 29 файлов | 235 кейсов |

Домены `Core/`: `Audio`, `Dictation`, `HUD`, `History`, `Hotkey`, `Import`,
`Insertion`, `Lecture`, `Logging`, `Normalizer`, `Readiness`, `Settings`,
`Transcription`.

UI не обращается к `AVAudioEngine`, `AXUIElement` и GRDB напрямую — только через
`AppState` и протоколы (`HistoryStoring`, `ImportQueueStoring`, `Transcribing`,
`LoginItemRegistering`).

## Главный путь: горячая клавиша → текст в чужом окне

1. `Core/Hotkey/HotkeyManager.swift` — системная регистрация сочетания, без
   перехватчика событий. Отдаёт нажатие и отпускание в `App/AppState.swift`.
2. `Core/Dictation/DictationStateMachine.swift` — чистый автомат, режимы
   «переключением» и «удержанием». Возвращает эффект, сам ничего не делает.
3. `AppState` снимает снимок активного приложения (`Core/Insertion/TextInserter.swift`),
   запускает `Core/Audio/AudioCaptureService.swift` и поднимает панель
   `Core/HUD/HUDWindowController.swift` — она не забирает фокус.
4. Запись длиннее одного окна считается **по ходу**:
   `Core/Dictation/DictationWindowPlanner.swift` считает границы,
   `StreamingDictationTranscriber.swift` распознаёт закрывшиеся окна, пока
   человек ещё говорит. После остановки досчитывается только хвост.
   Короткая диктовка идёт одним проходом, как прежде.
   `Core/Transcription/ModelManager.swift` выдаёт загруженную модель,
   `WhisperKitTranscriber.swift` распознаёт.
5. `Core/Transcription/TrailingHallucinationFilter.swift` срезает хвостовую тишину,
   `Core/Normalizer/TextNormalizer.swift` применяет словарь и мягкую орфографию.
6. `TextInserter` кладёт текст в буфер и посылает одно синтетическое ⌘V в то
   приложение, которое было активным в начале записи. Ушло в другое — остаётся
   буфер обмена.
7. `Data/HistoryStore.swift` сохраняет расшифровку.

## Путь лекции

Раздел «Лекции» в главном окне → `App/AppState+Lecture.swift` поднимает захват
и `Core/Lecture/LectureRecorder.swift`. Тот режет запись окнами по 10 секунд,
распознаёт их по ходу и сдвигает времена сегментов на начало окна.
`Core/Lecture/LectureParagraphBuilder.swift` собирает абзацы по паузам
говорящего — чистая функция, языковая модель в оформлении не участвует.
`UI/Lecture/LectureView.swift` показывает их с метками времени и переводит
выделенное системным переводчиком. `Data/LectureStore.swift` сохраняет лекцию
и абзацы одной транзакцией.

## Путь импорта файла

Перетаскивание в HUD (`Core/HUD/HUDContentView.swift`) или главное окно
(`UI/Import/ImportQueueView.swift`) → `Core/Import/ImportManager.swift`: одна
очередь, ровно одна задача одновременно → `Core/Import/AudioDecoder.swift`
декодирует потоком, включая OGG/Opus → дальше тот же тракт распознавания и
нормализации → `Data/ImportQueueStore.swift` и `HistoryStore`.

## Спецификация: возможность → код

`../spec/` — 132 блока в восьми файлах. У каждого есть `enforced_macos` со
ссылкой на реальный файл, у 90 есть `test_macos` со ссылкой на реальный тест.

| Возможность | Блоков | Где |
|---|---|---|
| Учебный режим | 9 | `spec/lecture/spec.md` |
| Диктовка | 20 | `spec/dictation/spec.md` |
| История | 20 | `spec/history/spec.md` |
| Модель | 19 | `spec/model/spec.md` |
| Импорт файлов | 18 | `spec/file-import/spec.md` |
| Готовность | 18 | `spec/readiness/spec.md` |
| Обработка текста | 15 | `spec/text-pipeline/spec.md` |
| Настройки | 13 | `spec/settings/spec.md` |

## Куда идти за задачей

| Нужно | Смотреть | Чем проверить |
|---|---|---|
| Изменить поведение диктовки | `spec/dictation/spec.md`, затем `Core/Dictation/`, `App/AppState.swift` | `zsh scripts/test-safely.sh`, затем сверка |
| Тронуть схему базы | `Data/Migrations.swift`, `Data/PersistenceRecords.swift` | `VoicePasteTests/HistoryStoreTests.swift` |
| Поменять загрузку модели | `Core/Transcription/ModelManager.swift`, `GitHubModelDownloader.swift` | `ModelManagerTests`, `ModelDownloadProgressTests` |
| Тронуть вставку текста | `Core/Insertion/TextInserter.swift` | `VoicePasteTests/TextInserterTests.swift` |
| Изменить нарезку окон | `Core/Dictation/DictationWindowPlanner.swift` | `DictationWindowPlannerTests`, `StreamingDictationTranscriberTests` |
| Тронуть учебный режим | `Core/Lecture/`, `UI/Lecture/` | `LectureParagraphBuilderTests`, `LectureRecorderTests`, `LectureStoreTests` |
| Собрать выпуск | `scripts/build-release.sh` | Сборка отказывает, если модель попала в пакет |

## Границы

Продукт не переносится на другие платформы: интерфейс стоит в тракте системного
ввода и разрешений macOS. Минимум системы — macOS 15: перевод выделенного идёт
системным фреймворком `Translation`, доступным с неё. Сервера у продукта нет, боевого контура нет — выкладка
это релиз на GitHub, и делает её человек.
