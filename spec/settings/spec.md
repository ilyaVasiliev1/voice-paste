# Spec: settings

> Извлечено из кода (spec-miner). Дата извлечения: 2026-09-20.
> Источник: VoicePaste/Core/Settings (AppSettings, LoginItemRegistering),
> VoicePaste/Core/Hotkey/HotkeyShortcut.swift, VoicePaste/UI/Settings
> (SettingsView, HotkeyRecorderView).
> Last verified: 2026-09-20 (commit 8f51051)

---

### Requirement: Значения настроек по умолчанию
<!-- id: AppSettings.init -->
<!-- entities: AppSettings, HotkeyShortcut, RecordingMode, TranscriptionLanguage, ModelDownloadSource -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Settings/AppSettings.swift, VoicePaste/Core/Hotkey/HotkeyShortcut.swift -->
<!-- test_macos: VoicePasteTests/AppSettingsModelDownloadSourceTests.swift:test_default_isGitHub_onEmptyDefaults -->

На чистой машине приложение SHALL стартовать с сочетанием ⌥Space, режимом
«переключение», языком «автоопределение», включёнными историей, авто-вставкой
и безопасным автоисправлением, включённым показом в Dock, источником загрузки
модели «GitHub» и выгрузкой модели `0` минут — то есть с моделью, остающейся
в памяти.

#### Scenario: пустое хранилище настроек
<!-- test: AppSettingsModelDownloadSourceTests.test_default_isGitHub_onEmptyDefaults -->
- **WHEN** сохранённых значений нет
- **THEN** источник загрузки — `github`

#### Scenario: нераспознанное сохранённое значение
<!-- test: AppSettingsModelDownloadSourceTests.test_unrecognizedStoredValue_fallsBackToGitHub -->
- **WHEN** в хранилище лежит неизвестная строка источника
- **THEN** используется значение по умолчанию, а не отказ

---

### Requirement: Изменение настройки сохраняется и вступает в силу сразу
<!-- id: AppSettings.persist -->
<!-- entities: AppSettings, AppState, HotkeyManager, DictationStateMachine -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Settings/AppSettings.swift, VoicePaste/UI/Settings/SettingsView.swift -->
<!-- test_macos: VoicePasteTests/AppSettingsModelDownloadSourceTests.swift:test_settingOfficial_persistsAcrossNewAppSettingsInstance -->

Каждое изменение SHALL записываться в пользовательские настройки немедленно.
Смена режима записи и сочетания дополнительно применяется к живому автомату
диктовки и к регистрации глобальной клавиши без перезапуска.

#### Scenario: смена источника загрузки
<!-- test: AppSettingsModelDownloadSourceTests.test_settingOfficial_persistsAcrossNewAppSettingsInstance -->
- **WHEN** выбран другой источник и создан новый экземпляр настроек
- **THEN** сохранённое значение прочитано обратно

#### Scenario: смена сочетания клавиш
- **WHEN** записано новое сочетание
- **THEN** прежняя регистрация снята, поставлена новая, значение сохранено

#### Scenario: смена режима записи
- **WHEN** выбран режим «удержание»
- **THEN** автомат диктовки работает в этом режиме начиная со следующего нажатия

---

### Requirement: Автозапуск управляется системой, а не сохранённым флагом
<!-- id: AppSettings.requestLoginItemChange -->
<!-- entities: AppSettings, LoginItemRegistering -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Settings/AppSettings.swift, VoicePaste/Core/Settings/LoginItemRegistering.swift -->
<!-- test_macos: VoicePasteTests/AppSettingsLaunchAtLoginTests.swift:test_enabling_registersWithSystem_andReflectsEnabledStatus -->

Источником истины для «Запускать при входе» SHALL быть статус системной
службы. Переключатель, тронутый пользователем, просит систему
зарегистрировать или снять регистрацию вне главного актора, а затем всегда
пересинхронизируется с тем, что система сообщает после попытки.

#### Scenario: включение
<!-- test: AppSettingsLaunchAtLoginTests.test_enabling_registersWithSystem_andReflectsEnabledStatus -->
- **WHEN** переключатель включён
- **THEN** выполнена регистрация, значение отражает статус «включено»

#### Scenario: выключение
<!-- test: AppSettingsLaunchAtLoginTests.test_disabling_whenEnabled_unregistersWithSystem_andReflectsOff -->
- **WHEN** переключатель выключен при активной регистрации
- **THEN** регистрация снята, значение отражает «выключено»

#### Scenario: отказ системы при регистрации
<!-- test: AppSettingsLaunchAtLoginTests.test_registerFailure_revertsSwitch_toActualSystemState -->
- **WHEN** регистрация не удалась
- **THEN** переключатель возвращается в фактическое состояние системы,
  причина ушла в журнал

#### Scenario: система требует подтверждения
<!-- test: AppSettingsLaunchAtLoginTests.test_registerSucceeds_butStatusStaysRequiresApproval_revertsSwitchToOff -->
- **WHEN** регистрация прошла, но статус остался «требует одобрения»
- **THEN** переключатель показывает «выключено» — любое значение, кроме
  «включено», читается как выключенное

#### Scenario: изменение сделано вне приложения
<!-- test: AppSettingsLaunchAtLoginTests.test_refreshFromSystem_picksUpExternalChange_withoutCallingRegistry -->
- **WHEN** пользователь изменил элемент входа в системных настройках и
  открыл вкладку «Основное»
- **THEN** переключатель отражает новое состояние, повторных запросов
  к системе не делается

#### Scenario: чистая машина
<!-- test: AppSettingsLaunchAtLoginTests.test_default_isOff_onCleanRegistry_andNothingIsRegistered -->
- **WHEN** регистрации нет
- **THEN** переключатель выключен, при инициализации регистрация не создаётся

---

### Requirement: Запись горячей клавиши требует хотя бы одного модификатора
<!-- id: RecorderNSView.keyDown -->
<!-- entities: HotkeyShortcut, HotkeyRecorderView -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Settings/HotkeyRecorderView.swift -->

Записыватель SHALL принимать сочетание только с одним из модификаторов
command, option, control, shift: сочетание без модификатора столкнулось бы
с обычным набором текста. Esc отменяет запись без изменений, Delete
возвращает значение по умолчанию.

#### Scenario: клавиша без модификатора
- **WHEN** во время записи нажата клавиша без модификаторов
- **THEN** сочетание не применяется, показана краткая подсказка (1,2 с),
  запись продолжается

#### Scenario: отмена записи
- **WHEN** нажат Esc или фокус ушёл с элемента
- **THEN** сочетание остаётся прежним

#### Scenario: сброс к значению по умолчанию
- **WHEN** во время записи нажат Delete
- **THEN** сочетание становится ⌥Space

#### Scenario: запись с клавиатуры без мыши
- **WHEN** элемент в фокусе и нажат Space или Return
- **THEN** запись сочетания начинается

---

### Requirement: Словарь замен правится в настройках
<!-- id: SettingsBody.addVocabularyEntry -->
<!-- entities: VocabularyEntry, HistoryStore, AppSettings -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Settings/SettingsView.swift, VoicePaste/Data/HistoryStore.swift -->
<!-- test_macos: VoicePasteTests/HistoryStoreTests.swift:test_vocabulary_upsertFetchDelete_roundTrips -->

Раздел «Автозамены» SHALL позволять добавлять правило (произнесённая форма и
подстановка), включать и выключать его и удалять. Добавление недоступно, пока
произнесённая форма пуста. После каждой операции список перечитывается из
хранилища.

#### Scenario: добавление правила
- **WHEN** заполнена произнесённая форма и нажат плюс
- **THEN** правило сохранено включённым, поля очищены, список обновлён

#### Scenario: пустая произнесённая форма
- **WHEN** поле произнесённой формы пусто или содержит только пробелы
- **THEN** кнопка добавления недоступна

#### Scenario: выключение правила
- **WHEN** переключатель правила выключен
- **THEN** правило сохранено выключенным и перестаёт применяться при нормализации

---

### Requirement: Разрушительные действия закрыты подтверждением
<!-- id: SettingsBody.historySection -->
<!-- entities: AppSettings, ModelManager, HistoryStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Settings/SettingsView.swift -->

Очистка истории и удаление модели SHALL выполняться только после отдельного
подтверждения. Кнопка удаления модели неактивна, пока модели на диске нет.
После удаления модели готовность пересчитывается.

#### Scenario: очистка истории
- **WHEN** нажата «Очистить историю» и подтверждено действие
- **THEN** история очищена одной транзакцией

#### Scenario: модель не установлена
- **WHEN** состояние модели `notPrepared`, `downloading`, `verifying` или `failed`
- **THEN** кнопка удаления модели недоступна

---

### Requirement: Раздел модели показывает состояние и управляет памятью
<!-- id: SettingsBody.modelSection -->
<!-- entities: ModelManager, ModelState, ModelCatalog, AppSettings -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Settings/SettingsView.swift, VoicePaste/Core/Transcription/ModelManager.swift -->

Раздел «Модель» SHALL показывать имя модели, её объём и текущее состояние,
давать выбор источника загрузки, шаг выгрузки из памяти и кнопку немедленной
выгрузки. Кнопка установки появляется, только когда модели на диске нет.

#### Scenario: модель на диске
- **WHEN** состояние `ready`, `unloaded` или `preparing`
- **THEN** статус «готова»/«подготовка», кнопка установки не показывается

#### Scenario: немедленная выгрузка
- **WHEN** нажата «Выгрузить сейчас»
- **THEN** модель освобождена из памяти, файлы на диске остаются

---

### Requirement: Состояние модели отрисовано одним видом в настройках и онбординге
<!-- id: ModelLifecycleView -->
<!-- entities: ModelState, ModelLifecycleView, SettingsBody, OnboardingView -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Settings/ModelLifecycleView.swift, VoicePaste/Core/Transcription/ModelState.swift -->
<!-- test_macos: VoicePasteTests/ModelStateInstalledTests.swift:test_installed_onlyWhenModelIsOnDisk -->

Состояние модели — установлена, загружается с прогрессом и скоростью, проверяется,
не удалась, отсутствует — SHALL показываться одним видом и в настройках, и на
шаге модели в онбординге, вместе с выбором источника и кнопкой загрузки или
повтора. Признак «модель на диске» SHALL выводиться из состояния в одном месте:
от него зависят и кнопка удаления в настройках, и завершение онбординга.

Прежде это было написано дважды и разошлось: в настройках загрузка показывалась
одной строкой статуса без прогресса и без отмены, а онбординг показывал прогресс,
скорость и остаток времени.

#### Scenario: модель на диске
<!-- test: ModelStateInstalledTests.test_installed_onlyWhenModelIsOnDisk -->
- **WHEN** состояние `ready`, `unloaded` или `preparing`
- **THEN** модель считается установленной; в остальных состояниях — нет

#### Scenario: загрузка из настроек
- **WHEN** загрузка запущена из настроек
- **THEN** в настройках видны прогресс, скорость и кнопка отмены — как в онбординге

---

### Requirement: Разрешения видны и ведут в нужную панель системы
<!-- id: SettingsBody.permissionsControls -->
<!-- entities: ReadinessCoordinator, AppSettings -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Settings/SettingsView.swift, VoicePaste/Core/Readiness/ReadinessCoordinator.swift -->

Вкладка «Основное» SHALL показывать состояние доступа к микрофону и
универсального доступа и предлагать переход в соответствующую панель
системных настроек, только когда доступ не выдан. При появлении вкладки
готовность пересчитывается.

#### Scenario: переход из HUD
- **WHEN** в HUD нажато «Выбрать микрофон»
- **THEN** окно настроек выходит вперёд на вкладку с разрешениями,
  даже если оно уже было открыто

#### Scenario: доступ выдан
- **WHEN** оба доступа выданы
- **THEN** кнопки перехода в системные настройки не показываются

---

### Invariant: Состояние автозапуска никогда не читается из сохранённых настроек
<!-- entities: AppSettings, LoginItemRegistering -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Settings/AppSettings.swift -->
<!-- verified_by_macos: VoicePasteTests/AppSettingsLaunchAtLoginTests.swift:test_nonEnabledStatuses_allShowAsOff_andInitNeverTouchesRegistry -->

Значение переключателя SHALL всегда выводиться из статуса системной службы:
сохранённый флаг мог бы разойтись с реальностью. Зеркалирование статуса при
инициализации и после запроса не должно повторно вызывать регистрацию.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Под тестовым прогоном элемент входа не трогается
<!-- entities: AppSettings, NullLoginItemRegistry -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Settings/AppSettings.swift, VoicePaste/Core/Settings/LoginItemRegistering.swift -->
<!-- verified_by_macos: VoicePasteTests/AppSettingsLaunchAtLoginTests.swift:test_testHostDefault_neverReflectsEnabled_regardlessOfToggle -->

В тестовой среде реестром по умолчанию SHALL быть заглушка: тестовый хост —
копия самого приложения, и случайная запись затронула бы установленную на
машине копию.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Время выгрузки модели ограничено диапазоном 0…60 минут
<!-- entities: AppSettings, ModelManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Settings/SettingsView.swift, VoicePaste/Core/Transcription/ModelManager.swift -->
<!-- verified_by_macos: VoicePasteTests/ModelManagerTests.swift:test_endTask_negativeMinutes_alsoNeverSchedulesUnload -->

Шаг в настройках SHALL ограничивать значение диапазоном 0…60; нулевое и любое
неположительное значение означает «держать модель в памяти» и таймер выгрузки
не ставит. Переполнение при расчёте задержки также отменяет таймер.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Признак включённой истории читается живым значением
<!-- entities: AppSettings, HistoryStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Settings/AppSettings.swift, VoicePaste/App/App.swift -->
<!-- verified_by_macos: VoicePasteTests/HistoryStoreTests.swift:test_historyDisabled_saveThrows_andNoRowIsCreated -->

Хранилище истории — актор вне главного, поэтому признак SHALL передаваться ему
как замыкание над защищённым блокировкой зеркалом, а не как значение,
снятое при запуске: включение истории посреди сессии обязано действовать сразу.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Сочетание клавиш хранится кодом клавиши и маской модификаторов
<!-- entities: HotkeyShortcut, HotkeyManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Hotkey/HotkeyShortcut.swift -->
<!-- verified_by_macos: VoicePasteTests/HotkeyManagerTests.swift:test_carbonModifiers_mapsEverySupportedModifier -->

Сохраняется SHALL ровно то представление, которое принимает системная
регистрация: виртуальный код клавиши и маска модификаторов. Оно же
используется для показа сочетания, так что записанное и срабатывающее
совпадают.

> Last verified: 2026-09-20 (commit 8f51051)

---

<!-- uncertainty: Экраны настроек (вкладки, диалоги подтверждения, редактор словаря, записыватель сочетания) проверены чтением кода: тестов на SwiftUI/AppKit-слой в VoicePasteTests нет. -->
