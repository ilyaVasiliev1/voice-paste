# Spec: file-import

> Извлечено из кода (spec-miner). Дата извлечения: 2026-09-20.
> Источник: VoicePaste/Core/Import (ImportManager, AudioDecoder, ImportJob,
> ImportQueueStoring), VoicePaste/Data/ImportQueueStore.swift,
> VoicePaste/UI/Import, VoicePaste/Core/HUD/HUDContentView.swift.
> Last verified: 2026-09-20 (commit 8f51051)

---

### Requirement: Файл ставится в очередь и копируется в собственный кэш
<!-- id: ImportManager.enqueue -->
<!-- entities: ImportManager, ImportJob, ImportQueueStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift, VoicePaste/UI/Import/ImportQueueView.swift -->
<!-- test_macos: VoicePasteTests/ImportManagerTests.swift:test_AT021_importsSupportedWAV_producesCompletionAndCleansOwnedCache -->

Постановка в очередь SHALL возвращать управление сразу: строка очереди видна
до начала работы с диском. Затем задача записывается в долговременную очередь,
исходный файл копируется в приватный каталог кэша под идентификатором задачи,
и только после этого она становится готовой к обработке. Исходный URL после
копии не удерживается.

#### Scenario: поддерживаемый аудиофайл
<!-- test: ImportManagerTests.test_AT021_importsSupportedWAV_producesCompletionAndCleansOwnedCache -->
- **WHEN** в очередь поставлен файл WAV
- **THEN** появляется завершение с расшифровкой, задача убрана из очереди,
  её каталог кэша удалён

#### Scenario: запись очереди не сохранилась
- **WHEN** запись задачи в долговременную очередь не удалась
- **THEN** задача помечена ошибкой `import.error.persistenceFailed`,
  копирование на диск не начинается

---

### Requirement: Неподдерживаемый файл виден как ошибка, а не исчезает
<!-- id: ImportManager.enqueue -->
<!-- entities: ImportManager, ImportJob, SupportedImportFormat -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift, VoicePaste/UI/Import/ImportQueueView.swift -->
<!-- test_macos: VoicePasteTests/ImportManagerTests.swift:test_AT022_unsupportedFile_remainsVisibleAsFailedWithoutCompletion -->

Расширение файла SHALL проверяться до копирования. Неподдерживаемый файл
остаётся видимой неудачной задачей с причиной; расшифровки не появляется.

#### Scenario: файл неподдерживаемого формата
<!-- test: ImportManagerTests.test_AT022_unsupportedFile_remainsVisibleAsFailedWithoutCompletion -->
- **WHEN** поставлен файл с расширением вне списка поддерживаемых
- **THEN** задача в состоянии `failed` с ключом
  `import.error.unsupportedFormat`, завершения нет

---

### Requirement: Отмена во время копирования убирает задачу и кэш
<!-- id: ImportManager.cancel -->
<!-- entities: ImportManager, ImportJob -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift -->
<!-- test_macos: VoicePasteTests/ImportManagerTests.swift:test_AT025_cancelledStaging_removesJobAndCache -->

Отмена SHALL останавливать текущий этап и не оставлять следов: строка очереди
и её запись в базе удаляются, приватный каталог кэша убирается. Отмена
активной задачи отменяет рабочую задачу, отмена ожидающей — её задачу
копирования.

#### Scenario: отмена на этапе копирования
<!-- test: ImportManagerTests.test_AT025_cancelledStaging_removesJobAndCache -->
- **WHEN** задача отменена во время копирования
- **THEN** задачи нет ни в списке, ни в базе, каталог кэша удалён

---

### Requirement: Прерванные задачи восстанавливаются после перезапуска
<!-- id: ImportQueueStore.restoreJobs -->
<!-- entities: ImportQueueStore, ImportManager, ImportJob -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/ImportQueueStore.swift, VoicePaste/Core/Import/ImportManager.swift -->
<!-- test_macos: VoicePasteTests/ImportManagerTests.swift:test_AT038_restoredInterruptedJobs_areRequeuedInFIFOOrder -->

Незавершённые при выходе задачи SHALL возвращаться в состояние «в очереди»
с нулевым прогрессом и обрабатываться в порядке создания. Процесс не может
продолжить прерванное распознавание — он безопасно начинает его заново
с уже скопированного источника.

#### Scenario: перезапуск с незавершённой очередью
<!-- test: ImportManagerTests.test_AT038_restoredInterruptedJobs_areRequeuedInFIFOOrder -->
- **WHEN** приложение запущено при задачах в состояниях копирования,
  подготовки, расшифровки или паузы
- **THEN** все они снова «в очереди» и выстроены по времени создания

#### Scenario: источник в кэше пропал
- **WHEN** у восстановленной задачи нет скопированного источника
- **THEN** задача становится видимой ошибкой, а не пустой расшифровкой

---

### Requirement: Очередь обрабатывается по одной задаче
<!-- id: ImportManager.startWorkerIfNeeded -->
<!-- entities: ImportManager, ImportJob, ModelManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift -->

Рабочий цикл SHALL быть единственным: он берёт первую задачу в состоянии
«в очереди», доводит её до конца и переходит к следующей. Новая задача,
появившаяся после остановки цикла, запускает его снова.

#### Scenario: несколько файлов поставлены подряд
- **WHEN** в очереди несколько готовых задач
- **THEN** они обрабатываются последовательно, в порядке постановки

#### Scenario: задача добавлена в момент завершения цикла
- **WHEN** после выхода из цикла в очереди осталась готовая задача
- **THEN** цикл перезапускается и берёт её

---

### Requirement: Медиа декодируется ограниченными окнами
<!-- id: AudioDecoder.decodeInChunks -->
<!-- entities: AudioDecoder, DecodedAudioChunk, ImportManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/AudioDecoder.swift, VoicePaste/Core/Import/ImportManager.swift -->
<!-- test_macos: VoicePasteTests/ImportManagerTests.swift:test_AT100_longImportIsTranscribedInBoundedSequentialWindows -->

Декодер SHALL отдавать окна по 28 секунд исходного материала с перекрытием
0,75 с и ждать распознавания каждого окна перед подготовкой следующего.
Тексты окон склеиваются с удалением перекрытия.

#### Scenario: длинный файл
<!-- test: ImportManagerTests.test_AT100_longImportIsTranscribedInBoundedSequentialWindows -->
- **WHEN** импортируется длинная запись
- **THEN** распознавание идёт последовательными ограниченными окнами, а не
  одним массивом сэмплов

#### Scenario: отмена во время декодирования
- **WHEN** задача отменена между окнами
- **THEN** декодирование прекращается, задача и кэш удаляются

---

### Requirement: Из видео берётся только звуковая дорожка
<!-- id: AudioDecoder.decodeVideoAudioTrackInChunks -->
<!-- entities: AudioDecoder, AudioDecodeError -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/AudioDecoder.swift -->

Для контейнеров `mp4`, `mov`, `m4v` SHALL использоваться чтение ассета с
единственным выходом — 16 кГц моно PCM. Видеокадры не декодируются и не
удерживаются. Отсутствие звуковой дорожки — явная ошибка `noAudioTrack`.

#### Scenario: видео со звуком
- **WHEN** импортируется файл MP4 со звуковой дорожкой
- **THEN** расшифровывается звук, видеопоток не читается

#### Scenario: видео без звука
- **WHEN** в файле нет звуковой дорожки
- **THEN** задача завершается ошибкой `import.error.noAudioTrack`

---

### Requirement: OGG декодируется системными средствами
<!-- id: AudioDecoder.decodeAudioFileInChunks -->
<!-- entities: AudioDecoder, TranscriptionRequest -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/AudioDecoder.swift -->
<!-- test_macos: VoicePasteTests/AudioDecoderOggTests.swift:test_realTelegramSample_decodesLocally_to16kHzMonoFloat32 -->

Голосовое сообщение в формате OGG SHALL декодироваться средствами системы,
без сторонних библиотек, в тот же формат 16 кГц моно Float32, который
принимает распознавание.

#### Scenario: настоящее голосовое сообщение
<!-- test: AudioDecoderOggTests.test_realTelegramSample_decodesLocally_to16kHzMonoFloat32 -->
- **WHEN** декодируется файл OGG из фикстуры
- **THEN** получаются сэмплы 16 кГц моно Float32, пригодные для запроса
  распознавания

#### Scenario: повреждённый файл
<!-- test: AudioDecoderOggTests.test_corruptedOggFile_throwsDecodeFailed_notCrash -->
- **WHEN** файл повреждён
- **THEN** бросается `decodeFailed`, приложение не падает

#### Scenario: расширение вне списка
<!-- test: AudioDecoderOggTests.test_unsupportedExtension_throwsUnsupportedFormat -->
- **WHEN** расширение не поддерживается
- **THEN** бросается `unsupportedFormat`

---

### Requirement: Завершённый импорт становится записью истории
<!-- id: ImportManager.process -->
<!-- entities: ImportManager, Transcript, HistoryStore, TextNormalizer -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift -->
<!-- test_macos: VoicePasteTests/ImportManagerTests.swift:test_AT021_importsSupportedWAV_producesCompletionAndCleansOwnedCache -->

Успешный импорт SHALL создавать запись со `source = .file`, именем исходного
файла, измеренной длительностью и нормализованным текстом, после чего задача
и её кэш удаляются. Пустой текст после нормализации считается ошибкой.

#### Scenario: удачная расшифровка файла
<!-- test: ImportManagerTests.test_AT021_importsSupportedWAV_producesCompletionAndCleansOwnedCache -->
- **WHEN** файл распознан
- **THEN** публикуется завершение с расшифровкой, задача и кэш удалены

#### Scenario: после нормализации текста нет
- **WHEN** нормализованный текст пуст
- **THEN** задача завершается ошибкой `dictation.emptyAudio`

---

### Requirement: Выключенная история не делает успешный импорт ошибкой
<!-- id: ImportManager.process -->
<!-- entities: ImportManager, AppSettings, HistoryStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift -->

Сохранение в историю SHALL быть необязательным шагом: при выключенной истории
оно пропускается, а при отказе хранилища причина уходит в журнал. Результат
остаётся доступен для копирования в обоих случаях.

#### Scenario: история выключена
- **WHEN** `historyEnabled == false` и файл распознан
- **THEN** завершение опубликовано, запись в историю не создаётся, ошибки нет

#### Scenario: хранилище недоступно
- **WHEN** сохранение бросило ошибку
- **THEN** завершение всё равно опубликовано, в журнале
  `import.historySaveFailed` без текста расшифровки

---

### Requirement: Повтор неудачной задачи без повторного выбора файла
<!-- id: ImportManager.retry -->
<!-- entities: ImportManager, ImportJob -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift, VoicePaste/UI/Import/ImportQueueView.swift -->

Неудачная задача SHALL сохранять уже скопированный источник, поэтому повтор
возможен без обращения к Finder. Повтор доступен только пока источник на месте;
удаление неудачной строки сразу убирает её кэш.

#### Scenario: повтор с сохранённым источником
- **WHEN** у неудачной задачи в кэше есть исходный файл и нажат повтор
- **THEN** задача возвращается в очередь с нулевым прогрессом и без причины ошибки

#### Scenario: источник уже удалён
- **WHEN** файла в кэше нет
- **THEN** кнопка повтора недоступна, повтор не запускается

---

### Requirement: Импорт через HUD
<!-- id: AppState.beginFileImport -->
<!-- entities: AppState, ImportManager, HUDState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/Core/HUD/HUDContentView.swift -->

HUD SHALL быть вторым входом в ту же очередь: поднятая площадка принимает
перетаскивание и открывает выбор файла, показывает ход именно своей задачи
и её результат. Закрытие HUD во время импорта отменяет эту задачу, не трогая
остальные.

#### Scenario: файл перетащен на HUD
- **WHEN** на площадку HUD брошен файл
- **THEN** он поставлен в ту же очередь, HUD показывает ход именно этой задачи

#### Scenario: закрытие HUD во время импорта
- **WHEN** пользователь закрывает HUD, пока его задача не завершена
- **THEN** задача отменяется, наблюдение прекращается

#### Scenario: переключение из записи в импорт
- **WHEN** во время записи нажата кнопка импорта в HUD
- **THEN** запись отменяется и буфер отбрасывается, показывается площадка импорта

#### Scenario: результат импорта
- **WHEN** задача HUD завершилась
- **THEN** показан результат с действиями «Копировать» и «Открыть в истории»

---

### Requirement: Очередь видна в боковом списке и в статистике
<!-- id: HistoryView.sidebar -->
<!-- entities: ImportManager, ImportJob, HistoryView, DashboardView -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/History/HistoryView.swift, VoicePaste/UI/Dashboard/DashboardView.swift -->

Пока есть незавершённые задачи, они SHALL показываться отдельной секцией
в боковом списке истории (кроме режима поиска) и строкой состояния очереди
в статистике; обе ведут в рабочую область очереди. В историю и поиск они
при этом не попадают.

#### Scenario: идёт обработка файла
- **WHEN** в очереди есть активная задача и строка поиска пуста
- **THEN** в боковом списке видна секция «В процессе» с этапом и прогрессом

#### Scenario: открыт поиск
- **WHEN** в строке поиска есть запрос
- **THEN** секция активных задач не показывается

---

### Invariant: Память импорта не зависит от длительности файла
<!-- entities: AudioDecoder, ImportManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/AudioDecoder.swift, VoicePaste/Core/Import/ImportManager.swift -->
<!-- verified_by_macos: VoicePasteTests/ImportManagerTests.swift:test_AT100_longImportIsTranscribedInBoundedSequentialWindows -->

Декодер SHALL дожидаться обработки окна перед удержанием следующего, а
накопитель хранить только текст. Поэтому трёхчасовой файл занимает столько же
памяти под PCM, сколько короткий.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Прогресс импорта доходит до UI не чаще четырёх раз в секунду
<!-- entities: ImportProgressGate, ImportManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift -->
<!-- verified_by_macos: VoicePasteTests/ImportManagerTests.swift:test_AT051_progressBurstIsCoalescedBeforeItCanScheduleUIWork -->

Сток прогресса SHALL пропускать значение не чаще одного раза в 250 мс и
делать это до создания задачи на главном акторе; значение от 0.999 проходит
всегда. Извлечение звука из видео может давать десятки вызовов в секунду —
они не должны копиться очередью работы UI.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Прогресс не убывает и не показывает завершение раньше времени
<!-- entities: ImportManager, ImportJob -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/ImportManager.swift -->

Значение прогресса SHALL быть не меньше уже показанного и не больше 0.99 до
фактического завершения; этапы задают опорные точки (подготовка 0.02,
расшифровка не меньше 0.05, ход медиа отображается в отрезок 0.05…0.99).
Промежуточный прогресс в базу не пишется — только границы этапов.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: В базе очереди нет ни пути, ни закладки, ни байтов медиа
<!-- entities: ImportQueueStore, ImportJob -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/ImportQueueStore.swift, VoicePaste/Data/Migrations.swift -->
<!-- verified_by_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT038_importQueuePersistsFIFO_andSafelyRequeuesInterruptedWork -->

Таблица задач SHALL хранить только идентификатор, время, имя файла, вид медиа,
длительность, состояние, прогресс, время начала этапа и ключ ошибки. Сам файл
живёт в каталоге кэша, адресуемом по идентификатору задачи.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Поддерживаемые форматы — m4a, wav, mp3, mp4, mov, m4v, ogg
<!-- entities: SupportedImportFormat, ImportPanelPresenter -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Import/AudioDecoder.swift, VoicePaste/UI/Import/ImportPanelPresenter.swift -->
<!-- verified_by_macos: VoicePasteTests/AudioDecoderOggTests.swift:test_unsupportedExtension_throwsUnsupportedFormat -->

Один и тот же список расширений SHALL проверяться при постановке в очередь,
при декодировании и предлагаться в системном диалоге выбора файла — окно
главного импорта и HUD используют его вместе.

> Last verified: 2026-09-20 (commit 8f51051)

---

<!-- uncertainty: Импорт через HUD (перетаскивание, выбор файла, отмена закрытием) проверен чтением AppState и HUDContentView; автотеста на этот путь в VoicePasteTests нет. -->
<!-- uncertainty: Ветка видео в AudioDecoder (AVAssetReader) не покрыта тестом — в фикстурах есть только OGG. -->
