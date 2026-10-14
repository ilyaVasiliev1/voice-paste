# Spec: history

> Извлечено из кода (spec-miner). Дата извлечения: 2026-09-20.
> Источник: VoicePaste/Data (AppDatabase, HistoryStore, Migrations,
> PersistenceRecords), VoicePaste/Domain (Transcript, TranscriptListItem,
> HistoryStoring, UsageStats, VocabularyEntry), VoicePaste/UI/History,
> VoicePaste/UI/Dashboard/DashboardView.swift.
> Last verified: 2026-09-20 (commit 8f51051)

---

### Requirement: Сохранение расшифровки одной транзакцией
<!-- id: HistoryStore.save -->
<!-- entities: HistoryStore, Transcript -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/Data/Migrations.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT017_savedTranscript_survivesReopeningTheDatabase -->

Расшифровка SHALL сохраняться в SQLite одной транзакцией вместе с
поисковым индексом: триггеры синхронизации FTS5 срабатывают в той же
транзакции, поэтому строки без индексной пары не бывает. Превью приходит
уже посчитанным.

#### Scenario: запись переживает перезапуск
<!-- test: HistoryStoreTests.test_AT017_savedTranscript_survivesReopeningTheDatabase -->
- **WHEN** запись сохранена и база открыта заново
- **THEN** запись читается целиком, включая исходный и текущий текст

#### Scenario: каждая запись находится поиском
<!-- test: HistoryStoreTests.test_AT031_everySavedRow_hasNonEmptyPreview_andIsFindableViaFTS -->
- **WHEN** сохранено множество записей
- **THEN** у каждой непустое превью и каждая находится через FTS

---

### Requirement: Выключенная история отклоняет сохранение
<!-- id: HistoryStore.save -->
<!-- entities: HistoryStore, AppSettings, HistoryError -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/App/App.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_historyDisabled_saveThrows_andNoRowIsCreated -->

Хранилище SHALL читать признак включённости истории живым значением на каждое
сохранение, а не снятым при запуске. При выключенной истории сохранение
отклоняется с `historyDisabled`, строка не создаётся.

#### Scenario: история выключена
<!-- test: HistoryStoreTests.test_historyDisabled_saveThrows_andNoRowIsCreated -->
- **WHEN** история выключена и вызвано сохранение
- **THEN** бросается `historyDisabled`, в таблице ничего не появилось

---

### Requirement: Правка текста сохраняет исходное распознавание
<!-- id: HistoryStore.edit -->
<!-- entities: HistoryStore, Transcript -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/UI/History/DetailEditor.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT018_edit_changesTextAndPreview_butPreservesRawText -->

Правка SHALL менять только текущий текст, превью, отметку изменения и счётчик
слов. Исходный текст распознавания не трогается; поисковый индекс обновляется
тем же триггером.

#### Scenario: правка существующей записи
<!-- test: HistoryStoreTests.test_AT018_edit_changesTextAndPreview_butPreservesRawText -->
- **WHEN** текст записи изменён
- **THEN** текст и превью новые, исходный текст прежний

#### Scenario: правка несуществующей записи
<!-- test: HistoryStoreTests.test_edit_unknownId_throwsNotFound -->
- **WHEN** идентификатор не найден
- **THEN** бросается `notFound`

#### Scenario: запись правки не удалась
- **WHEN** хранилище отвергло правку
- **THEN** экран не выдаёт её за сохранённую: список не обновляется, в детали
  видна пометка «Правка не сохранена», причина уходит в журнал без текста

Отказ записи SHALL быть отличим от успеха. Обратное — обновить модель
безусловно — оставляет пользователя с текстом, которого в базе нет, и
обнаруживается только перезапуском.

---

### Requirement: Удаление записи и очистка истории
<!-- id: HistoryStore.delete -->
<!-- entities: HistoryStore, Transcript -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/UI/History/HistoryView.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT020_delete_removesOnlyThatRow -->

Удаление SHALL убирать ровно одну строку вместе с её индексной парой;
очистка удаляет всё в одной подтверждённой транзакции. Обе операции в UI
закрыты диалогом подтверждения.

#### Scenario: удаление одной записи
<!-- test: HistoryStoreTests.test_AT020_delete_removesOnlyThatRow -->
- **WHEN** удалена одна запись
- **THEN** остальные записи не затронуты

#### Scenario: очистка всей истории
<!-- test: HistoryStoreTests.test_AT020_clearAll_removesEverything_includingFTSIndex -->
- **WHEN** выполнена очистка
- **THEN** и таблица, и поисковый индекс пусты

#### Scenario: удаление несуществующей записи
<!-- test: HistoryStoreTests.test_delete_unknownId_throwsNotFound -->
- **WHEN** идентификатор не найден
- **THEN** бросается `notFound`

---

### Requirement: Постраничная загрузка истории курсором
<!-- id: HistoryStore.fetchPage -->
<!-- entities: HistoryStore, TranscriptPage, TranscriptCursor, TranscriptListItem -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/UI/History/HistoryView.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT029_pagination_returnsExactly100PerPage_newestFirst_neverReadingFullText -->

Список SHALL выдаваться страницами по 100 строк в порядке «сначала новые»
с курсором по паре `createdAt`, `id` и без `OFFSET`. Строка списка несёт
только лёгкие колонки и превью. Признак следующей страницы получается
выборкой одной лишней строки.

#### Scenario: первая и следующая страницы
<!-- test: HistoryStoreTests.test_AT029_pagination_returnsExactly100PerPage_newestFirst_neverReadingFullText -->
- **WHEN** в истории больше ста записей
- **THEN** страница содержит ровно 100 строк, отсортированных от новых к
  старым, и курсор на продолжение

#### Scenario: последняя страница
- **WHEN** оставшихся строк меньше размера страницы
- **THEN** курсор продолжения отсутствует

---

### Requirement: Полнотекстовый поиск по тексту и имени файла
<!-- id: HistoryStore.search -->
<!-- entities: HistoryStore, TranscriptPage -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/UI/History/HistoryView.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT019_search_findsByTextPhrase -->

Поиск SHALL идти по индексу FTS5 с префиксным совпадением каждого введённого
токена и той же постраничностью, что и обычный список. Произвольный ввод
пользователя не приводит к ошибке.

#### Scenario: поиск по фразе
<!-- test: HistoryStoreTests.test_AT019_search_findsByTextPhrase -->
- **WHEN** введена часть фразы из расшифровки
- **THEN** запись найдена

#### Scenario: поиск по части имени файла
<!-- test: HistoryStoreTests.test_AT019_AT030_search_findsByPartialSourceFileName -->
- **WHEN** введена часть имени импортированного файла
- **THEN** запись найдена

#### Scenario: произвольный ввод
<!-- test: HistoryStoreTests.test_search_neverThrowsOnArbitraryUserInput -->
- **WHEN** введены символы, недопустимые в синтаксисе FTS5
- **THEN** ошибки нет, возвращается пустая или корректная страница

#### Scenario: поиск по большому набору
<!-- test: HistoryStoreTests.test_AT030_search_worksAcrossLargeDataset_andPaginates -->
- **WHEN** совпадений больше размера страницы
- **THEN** результаты выдаются страницами с курсором

---

### Requirement: Список обновляется сам при изменении данных
<!-- id: HistoryStore.changes -->
<!-- entities: HistoryStore, HistoryStoring -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/UI/History/HistoryView.swift -->

Хранилище SHALL отдавать поток сигналов «что-то изменилось», построенный на
наблюдении за количеством строк и максимальной отметкой изменения. Долгоживущее
окно истории перезапрашивает текущий запрос по каждому сигналу, без
переоткрытия окна.

#### Scenario: сохранена новая расшифровка
<!-- test: HistoryListModelTests.test_changeTick_keepsEveryLoadedRow -->
- **WHEN** во время открытого окна истории сохранена запись
- **THEN** приходит сигнал и список перезапрашивается с первой страницы до прежней глубины:
  уже подгруженные строки не исчезают, прокрутка не возвращается к началу

#### Scenario: открыт поиск
- **WHEN** сигнал пришёл, когда в строке поиска есть запрос
- **THEN** перезапрашивается именно поиск, а не общий список

---

### Requirement: Локальная статистика по дням и часам
<!-- id: HistoryStore.fetchUsageStats -->
<!-- entities: HistoryStore, UsageStats, DailyUsageStat -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/UI/Dashboard/DashboardView.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT036_fetchUsageStats_groupsWordsByDay_andSummaryTotalsMatch -->

Статистика SHALL считаться из отметок времени, счётчиков слов и длительностей —
без чтения текста расшифровок. Окно в один день разбивается на 24 часовые
корзины, окна в 7 и 30 дней — на дневные. Пустые корзины присутствуют
с нулями.

#### Scenario: группировка по дням
<!-- test: HistoryStoreTests.test_AT036_fetchUsageStats_groupsWordsByDay_andSummaryTotalsMatch -->
- **WHEN** записи распределены по нескольким дням
- **THEN** слова, число расшифровок и длительность разложены по дням, а итоги
  равны сумме корзин

#### Scenario: пустая история
<!-- test: HistoryStoreTests.test_fetchUsageStats_emptyHistory_returnsZeroFilledWindow -->
- **WHEN** записей нет
- **THEN** возвращается окно нужной длины, заполненное нулями

---

### Requirement: Время речи не округляется в ноль
<!-- id: SpeechDurationText.text -->
<!-- entities: SpeechDurationText, DashboardView -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Dashboard/SpeechDurationText.swift -->
<!-- test_macos: VoicePasteTests/SpeechDurationTextTests.swift:test_underAMinute_showsSeconds_notZeroMinutes -->

Статистика SHALL показывать время речи так, чтобы ненулевая длительность не
выглядела нулём: меньше минуты — в секундах, меньше часа — в минутах, от часа —
в часах и минутах.

#### Scenario: три записи по нескольку секунд
<!-- test: SpeechDurationTextTests.test_underAMinute_showsSeconds_notZeroMinutes -->
- **WHEN** суммарная длительность — 24 секунды
- **THEN** показано «24 с», а не «0 мин»

#### Scenario: длинная речь
<!-- test: SpeechDurationTextTests.test_minutesAndHours_keepTheirFormat -->
- **WHEN** длительность — 5 ч 42 мин или 12 мин
- **THEN** показано «5 ч 42 мин» и «12 мин»

---

### Requirement: Миграции схемы только вперёд
<!-- id: Migrations.migrator -->
<!-- entities: Migrations, WordCounting, Transcript, ImportJob, VocabularyEntry -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/Migrations.swift, VoicePaste/Data/AppDatabase.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT032_migratorNeverErasesOnSchemaChange_andIsIdempotent -->

Схема SHALL развиваться только добавлением новых миграций. Стирание базы при
изменении схемы выключено: история пользователя не может быть молча
пересоздана. Добавление счётчика слов заполняет уже существующие строки
тем же правилом подсчёта, что и все новые записи.

#### Scenario: повторная миграция той же базы
<!-- test: HistoryStoreTests.test_AT032_migratorNeverErasesOnSchemaChange_andIsIdempotent -->
- **WHEN** мигратор применён к уже мигрированной базе
- **THEN** данные на месте, повторное применение безвредно

#### Scenario: база из прежней версии схемы
<!-- test: HistoryStoreTests.test_AT037_migration_addsWordCountColumn_andBackfillsExistingRows -->
- **WHEN** открыта база без колонки счётчика слов
- **THEN** колонка добавлена и заполнена по существующим текстам

---

### Requirement: Словарь замен хранится вместе с историей
<!-- id: HistoryStore.upsertVocabulary -->
<!-- entities: HistoryStore, VocabularyEntry -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/UI/Settings/SettingsView.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_vocabulary_upsertFetchDelete_roundTrips -->

Правила словаря SHALL храниться в той же базе, читаться целиком (таблица
мала, постраничность не нужна) в порядке создания и записываться одной
операцией «вставить или обновить по идентификатору».

#### Scenario: полный цикл правила
<!-- test: HistoryStoreTests.test_vocabulary_upsertFetchDelete_roundTrips -->
- **WHEN** правило создано, изменено и удалено
- **THEN** каждое состояние читается обратно без потерь, после удаления
  правила нет

---

### Requirement: Недоступная база не отключает диктовку
<!-- id: AppDatabase.makePool -->
<!-- entities: AppDatabase, FailingHistoryStore, AppState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/AppDatabase.swift, VoicePaste/Core/History/FailingHistoryStore.swift, VoicePaste/UI/Main/MainWindowView.swift -->

Если файл истории не открылся или не мигрировал, приложение SHALL продолжать
работать: диктовка и вставка доступны, история и очередь заменяются
заглушками, а окно показывает постоянный баннер недоступности хранилища.
Файл базы при этом не удаляется — он остаётся для диагностики.

#### Scenario: база не открывается при запуске
- **WHEN** открытие или миграция бросили ошибку
- **THEN** используется заглушка хранилища, причина ушла в журнал
  (`persistence.openFailed`), файл на диске сохранён

#### Scenario: окно открыто при недоступном хранилище
- **WHEN** в главном окне известна причина отказа хранилища
- **THEN** сверху показан баннер `storage-unavailable-banner`

---

### Requirement: Поиск и правка в окне истории не бьют по базе на каждый символ
<!-- id: HistoryView.scheduleSearch -->
<!-- entities: HistoryView, DetailEditor, HistoryStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/History/HistoryView.swift, VoicePaste/UI/History/DetailEditor.swift -->

Ввод в строку поиска SHALL откладываться на 80 мс с отменой устаревшего
запроса (запрос к 2,4 тыс. записей — около 2 мс, замер 14.10.2026; потолок
задержки — 100 мс); правка текста в детали сохраняется через 500 мс после
последнего нажатия. Нажатие Enter не запускает распознавание.

#### Scenario: быстрый набор запроса
<!-- test: HistoryListModelTests.test_searchBurst_sendsOnlyTheLastQuery -->
- **WHEN** пользователь печатает без пауз
- **THEN** в хранилище уходит только последний запрос

#### Scenario: задержка поиска короткая
<!-- test: HistoryListModelTests.test_searchDebounce_isShortEnoughToFeelInstant -->
- **WHEN** запрос поиска ожидает отправки
- **THEN** ожидание не больше 100 мс

#### Scenario: правка текста записи
- **WHEN** текст изменён и 500 мс не было новых изменений
- **THEN** правка сохранена, превью и отметка изменения обновлены

---

### Requirement: Окно истории не показывает «пусто» до первой выборки
<!-- id: HistoryListModel.isLoaded -->
<!-- entities: HistoryListModel, HistoryListColumn -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/History/HistoryListModel.swift, VoicePaste/UI/History/HistoryView.swift -->
<!-- test_macos: VoicePasteTests/HistoryListModelTests.swift:test_beforeTheFirstPage_listIsNotLoaded_soEmptyStateIsNotShown -->

Пока первая выборка не завершилась, модель SHALL считаться незагруженной, а список
показывать заглушку строк (не сразу, а через 150 мс, чтобы короткая выборка не
давала вспышки). Состояние «Нет записей» допустимо только после завершения
выборки с пустым результатом.

#### Scenario: выборка ещё идёт
<!-- test: HistoryListModelTests.test_beforeTheFirstPage_listIsNotLoaded_soEmptyStateIsNotShown -->
- **WHEN** окно открыто, а первая страница ещё не пришла
- **THEN** `isLoaded` ложно и «Нет записей» не показано

#### Scenario: база пуста
<!-- test: HistoryListModelTests.test_emptyStore_becomesLoadedWithNoItems -->
- **WHEN** первая выборка завершилась без записей
- **THEN** `isLoaded` истинно, список пуст, показано «Нет записей»

---

### Requirement: Отказ чтения истории виден, а не выдаётся за «пусто»
<!-- id: HistoryListModel.didFailToLoad -->
<!-- entities: HistoryListModel, HistoryListColumn, HistoryDetailColumn -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/History/HistoryListModel.swift, VoicePaste/UI/History/HistoryView.swift -->
<!-- test_macos: VoicePasteTests/HistoryListModelTests.swift:test_failedFirstLoad_isFailure_notAnEmptyHistory -->

Когда выборка списка не удалась, модель SHALL поднять признак отказа, а при пустом списке
показать состояние «История не прочиталась» с действием «Повторить», а не «Нет записей».
Уже показанные строки при сбое обновления остаются. Когда выбранная запись не прочиталась,
деталь SHALL показать «Не удалось открыть запись», а не «Выберите запись»; признак сбрасывается
следующим выбором.

#### Scenario: первая выборка не удалась
<!-- test: HistoryListModelTests.test_failedFirstLoad_isFailure_notAnEmptyHistory -->
- **WHEN** первая выборка завершилась ошибкой
- **THEN** `didFailToLoad` истинно, `isLoaded` истинно, список пуст

#### Scenario: повтор после отказа
<!-- test: HistoryListModelTests.test_retryAfterFailure_loadsTheList_andClearsTheFailure -->
- **WHEN** выполнен повтор и база ответила
- **THEN** список загружен, признак отказа снят

#### Scenario: сбой обновления
<!-- test: HistoryListModelTests.test_failedRefresh_keepsTheRowsAlreadyShown -->
- **WHEN** тик обновления закончился ошибкой при показанном списке
- **THEN** строки остаются

#### Scenario: запись не открылась
<!-- test: HistoryListModelTests.test_failedDetail_isShown_andClearedByTheNextSelection -->
- **WHEN** чтение выбранной записи завершилось ошибкой
- **THEN** `didFailToOpenDetail` истинно, а следующий выбор его снимает

---

### Requirement: Подгрузка страницы начинается заранее и не дублируется
<!-- id: HistoryListModel.loadNextPageIfNeeded -->
<!-- entities: HistoryListModel, TranscriptCursor -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/History/HistoryListModel.swift -->
<!-- test_macos: VoicePasteTests/HistoryListModelTests.swift:test_nextPage_isRequestedBeforeTheLastRow_andOnlyOnceForRepeatedAppear -->

Следующая страница SHALL запрашиваться, когда на экране появилась любая из
последних 20 строк, и не более одного запроса по одному курсору одновременно.
Страница поиска берётся из поиска, а не из общего списка.

#### Scenario: прокрутка к концу
<!-- test: HistoryListModelTests.test_nextPage_isRequestedBeforeTheLastRow_andOnlyOnceForRepeatedAppear -->
- **WHEN** несколько строк из последних 20 появились подряд
- **THEN** уходит один запрос, строки дописаны один раз

---

### Requirement: Деталь показывает последний выбор
<!-- id: HistoryListModel.select -->
<!-- entities: HistoryListModel, Transcript -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/History/HistoryListModel.swift -->
<!-- test_macos: VoicePasteTests/HistoryListModelTests.swift:test_slowAnswerToEarlierSelection_doesNotReplaceTheLaterOne -->

Ответ на выбор SHALL применяться, только если выбор не изменился: поздний ответ
на прежнюю запись не заменяет деталь нынешней, предыдущая выборка отменяется.

#### Scenario: быстрая навигация стрелками
<!-- test: HistoryListModelTests.test_slowAnswerToEarlierSelection_doesNotReplaceTheLaterOne -->
- **WHEN** выбрана одна запись, а затем другая, и ответ на первую приходит позже
- **THEN** деталь показывает вторую

---

### Requirement: Удаление убирает строку сразу, отказ возвращает её
<!-- id: HistoryListModel.delete -->
<!-- entities: HistoryListModel, HistoryStoring -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/History/HistoryListModel.swift, VoicePaste/UI/History/HistoryView.swift -->
<!-- test_macos: VoicePasteTests/HistoryListModelTests.swift:test_delete_removesTheRowBeforeTheStoreAnswers -->

Строка SHALL уходить из списка до ответа базы. Если удалена выбранная запись,
выбор переходит на соседнюю (следующую, иначе предыдущую). Пока база не
ответила, обновление списка не возвращает удаляемую строку. При отказе строка
возвращается на прежнее место и показан отказ.

#### Scenario: строка исчезает без ожидания
<!-- test: HistoryListModelTests.test_delete_removesTheRowBeforeTheStoreAnswers -->
- **WHEN** вызвано удаление, а база отвечает не сразу
- **THEN** строки в списке уже нет

#### Scenario: удалена выбранная запись
<!-- test: HistoryListModelTests.test_deleteOfSelectedRow_selectsTheNeighbour -->
- **WHEN** удалена выбранная запись
- **THEN** выбрана следующая

#### Scenario: тик во время удаления
<!-- test: HistoryListModelTests.test_refreshWhileDeleteIsPending_doesNotBringTheRowBack -->
- **WHEN** пришёл сигнал обновления, пока удаление не подтверждено
- **THEN** строка не появляется снова

#### Scenario: база отказала
<!-- test: HistoryListModelTests.test_failedDelete_returnsTheRowToItsPlace_andSaysSo -->
- **WHEN** удаление завершилось ошибкой
- **THEN** строка на прежнем месте, показан отказ

---

### Requirement: Просмотр записи ничего не пишет
<!-- id: DetailEditModel.userEdited -->
<!-- entities: DetailEditModel, DetailEditor, HistoryStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/History/DetailEditor.swift -->
<!-- test_macos: VoicePasteTests/HistoryListModelTests.swift:test_openingARecord_writesNothing -->

Запись в базу SHALL порождать только ввод человека, изменивший текст. Открытие
записи, выбор другой и ввод того же текста не пишут. Текст записи доступен
редактору с первого кадра. Правка, ожидающая своих 500 мс, не теряется при
переходе на другую запись; отказ записи виден и не выдаётся за успех.

#### Scenario: запись только открыта
<!-- test: HistoryListModelTests.test_openingARecord_writesNothing -->
- **WHEN** запись открыта и ничего не набрано
- **THEN** `HistoryStoring.edit` не вызывался

#### Scenario: набран тот же текст
<!-- test: HistoryListModelTests.test_sameTextTyped_writesNothing -->
- **WHEN** в редактор приходит текст, равный текущему
- **THEN** `HistoryStoring.edit` не вызывался

#### Scenario: серия правок
<!-- test: HistoryListModelTests.test_userEdits_areCoalescedIntoOneWrite_andReported -->
- **WHEN** текст изменён несколько раз подряд
- **THEN** записан один раз, последний вариант, `rawText` не тронут

#### Scenario: переход на другую запись
<!-- test: HistoryListModelTests.test_pendingEdit_survivesTheEditorBeingClosed -->
- **WHEN** правка набрана и редактор закрыт до записи
- **THEN** правка всё равно записана

#### Scenario: база отказала
<!-- test: HistoryListModelTests.test_failedSave_isShown_andNotReportedAsSaved -->
- **WHEN** запись правки завершилась ошибкой
- **THEN** поднят признак «Правка не сохранена», модель списка не обновлена

---

### Requirement: Статистика не показывает «пусто» до загрузки
<!-- id: UsageStatsModel.track -->
<!-- entities: UsageStatsModel, DashboardView -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Dashboard/DashboardView.swift -->
<!-- test_macos: VoicePasteTests/HistoryListModelTests.swift:test_usageStats_areLoading_untilTheStoreAnswers -->

До первой выборки статистика SHALL быть «загружается»: показатели и подпись
скрыты заглушкой, «Здесь появится статистика» не показано. Отказ чтения — отдельное
состояние, а не пустые данные.

#### Scenario: выборка ещё идёт
<!-- test: HistoryListModelTests.test_usageStats_areLoading_untilTheStoreAnswers -->
- **WHEN** экран открыт, а данные не пришли
- **THEN** `isLoaded` ложно

#### Scenario: база отказала
<!-- test: HistoryListModelTests.test_usageStatsFailure_isFailure_notEmptyData -->
- **WHEN** чтение статистики завершилось ошибкой
- **THEN** `didFailToLoad` истинно, `isLoaded` ложно

---

### Invariant: Размер страницы истории — 100 строк
<!-- entities: HistoryPaging, HistoryStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Domain/TranscriptListItem.swift, VoicePaste/Data/HistoryStore.swift -->
<!-- verified_by_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT029_pagination_returnsExactly100PerPage_newestFirst_neverReadingFullText -->

И обычный список, и поиск SHALL ограничиваться одной и той же константой
`HistoryPaging.pageSize = 100`. Из базы выбирается 101 строка, чтобы узнать
о существовании следующей страницы без `OFFSET`.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Превью — первые 240 символов текста
<!-- entities: Transcript -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Domain/Transcript.swift -->
<!-- verified_by_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT031_everySavedRow_hasNonEmptyPreview_andIsFindableViaFTS -->

Превью SHALL считаться единственной функцией `Transcript.makePreview` — первые
240 символов текущего текста — и пересчитываться в той же транзакции, что и
сам текст, при сохранении и при правке.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Порядок истории — по убыванию времени создания, затем идентификатора
<!-- entities: HistoryStore, TranscriptCursor, Migrations -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/Data/Migrations.swift -->
<!-- verified_by_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT029_pagination_returnsExactly100PerPage_newestFirst_neverReadingFullText -->

Сортировка SHALL быть `createdAt DESC, id DESC` во всех запросах списка и
поиска; ровно под неё создан индекс. Курсор устроен так же, поэтому страницы
стыкуются без пропусков и повторов.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Строка списка не несёт полного текста
<!-- entities: TranscriptListItem -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Domain/TranscriptListItem.swift, VoicePaste/Data/PersistenceRecords.swift -->
<!-- verified_by_macos: VoicePasteTests/HistoryStoreTests.swift:test_listItemType_hasNoFullTextFields_byConstruction -->

Тип строки списка SHALL по построению не иметь полей исходного и текущего
текста: запрос выбирает только лёгкие колонки, полный текст читается
единственным методом получения детали.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Счётчик слов считается одним правилом везде
<!-- entities: WordCounting, Transcript, Migrations -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/Migrations.swift, VoicePaste/Data/PersistenceRecords.swift -->
<!-- verified_by_macos: VoicePasteTests/HistoryStoreTests.swift:test_AT037_migration_addsWordCountColumn_andBackfillsExistingRows -->

Слова SHALL считаться как непустые токены, разделённые пробелами и переводами
строки. То же правило применяется при вставке через запись GRDB, при правке
сырым SQL и при заполнении старых строк миграцией.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: База открывается в режиме WAL с ожиданием блокировки 5 секунд
<!-- entities: AppDatabase -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/AppDatabase.swift -->

Файл `~/Library/Application Support/VoicePaste/history.sqlite` SHALL
открываться пулом с журналом WAL и ограниченным ожиданием занятой базы
в 5 секунд: короткая конкуренция на контрольной точке не должна ронять
сохранение.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: База никогда не удаляется автоматически
<!-- entities: AppDatabase, Migrations -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/AppDatabase.swift, VoicePaste/Data/Migrations.swift -->

Ни отказ открытия, ни отказ миграции, ни изменение формы миграции SHALL не
приводить к удалению или пересозданию файла истории. Единственное разрешённое
массовое удаление — явная «Очистить историю» пользователем.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Доступ к базе никогда не выполняется на главном акторе
<!-- entities: HistoryStore, ImportQueueStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/HistoryStore.swift, VoicePaste/Data/ImportQueueStore.swift -->

Хранилища SHALL быть акторами вне главного и работать только через
асинхронные чтение/запись пула: чтения идут по конкурентным соединениям WAL,
записи сериализуются единственным писателем.

> Last verified: 2026-09-20 (commit 8f51051)

---

<!-- uncertainty: Живое обновление списка (changes()), баннер недоступного хранилища и задержки ввода в HistoryView/DetailEditor проверены чтением кода — тестов на SwiftUI-слой в VoicePasteTests нет. -->
