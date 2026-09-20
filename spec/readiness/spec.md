# Spec: readiness

> Извлечено из кода (spec-miner). Дата извлечения: 2026-09-20.
> Источник: VoicePaste/Core/Readiness, VoicePaste/App (App, AppDelegate,
> AppState), VoicePaste/UI/Onboarding/OnboardingView.swift,
> VoicePaste/UI/MenuBar/MenuBarContentView.swift,
> VoicePaste/Core/Logging/DiagnosticLog.swift.
> Last verified: 2026-09-20 (commit 8f51051)

---

### Requirement: Готовность вычисляется из живого состояния системы
<!-- id: ReadinessCoordinator.refresh -->
<!-- entities: ReadinessCoordinator, ReadinessState, ModelState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Readiness/ReadinessCoordinator.swift -->
<!-- test_macos: VoicePasteTests/ReadinessModelStateObservationTests.swift:test_afterLoadCompletes_readinessSettlesOnReady_withoutAnExtraRefresh -->

Состояние готовности SHALL пересчитываться в фиксированном порядке: доступ
к микрофону, затем универсальный доступ, затем состояние модели. Пересчёт
происходит при возврате в приложение, после разрешения запроса прав и на
каждое изменение состояния модели.

#### Scenario: загрузка модели завершилась
<!-- test: ReadinessModelStateObservationTests.test_afterLoadCompletes_readinessSettlesOnReady_withoutAnExtraRefresh -->
- **WHEN** модель дошла до состояния `ready`
- **THEN** готовность становится `.ready` без дополнительного явного пересчёта

#### Scenario: локальный прогрев модели
<!-- test: ReadinessModelStateObservationTests.test_verifyingAfterLocalWarmUp_isNotReportedAsDownloading -->
- **WHEN** модель уже на диске и лишь вносится в память
- **THEN** приложение остаётся готовым и не сообщает о загрузке из сети

#### Scenario: нет доступа к микрофону
- **WHEN** доступ к микрофону не выдан, отозван или ограничен
- **THEN** состояние `needsMicrophonePermission` независимо от остального

#### Scenario: модель не установлена
- **WHEN** права выданы, но модели на диске нет
- **THEN** состояние `needsModel`

---

### Requirement: Подписка на состояние модели читает пришедшее значение
<!-- id: ReadinessCoordinator.init -->
<!-- entities: ReadinessCoordinator, ModelManager, ModelState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Readiness/ReadinessCoordinator.swift -->
<!-- test_macos: VoicePasteTests/ReadinessModelStateObservationTests.swift:test_publishedProjectedValue_emitsBeforeThePropertyIsUpdated -->

Подписчик SHALL считать готовность по значению, которое доставил издатель,
а не перечитывать свойство: публикация происходит до присваивания, и повторное
чтение отстаёт на один переход.

#### Scenario: публикация опережает присваивание
<!-- test: ReadinessModelStateObservationTests.test_publishedProjectedValue_emitsBeforeThePropertyIsUpdated -->
- **WHEN** состояние модели меняется
- **THEN** подписчик видит новое значение в параметре, тогда как свойство ещё
  хранит прежнее

---

### Requirement: Запрос доступа к микрофону различает отказ и непоказанный запрос
<!-- id: ReadinessCoordinator.microphoneAccessAction -->
<!-- entities: ReadinessCoordinator, MicrophoneAccessAction -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Readiness/ReadinessCoordinator.swift, VoicePaste/UI/Onboarding/OnboardingView.swift -->
<!-- test_macos: VoicePasteTests/ReadinessCoordinatorMicrophoneAccessActionTests.swift:test_notDetermined_mapsTo_notPresented_neverNeedsSystemSettings -->

После запроса приложение SHALL перечитывать реальный статус и решать по нему:
выданный доступ не требует действий, настоящий отказ ведёт в системные
настройки, а статус «не определён» означает, что macOS не показала запрос —
в этом случае отправлять в настройки нельзя, там приложения ещё нет в списке.

#### Scenario: статус не определён после запроса
<!-- test: ReadinessCoordinatorMicrophoneAccessActionTests.test_notDetermined_mapsTo_notPresented_neverNeedsSystemSettings -->
- **WHEN** после запроса статус остался «не определён»
- **THEN** действие `notPresented`, в онбординге показано объяснение и
  возможность повторить

#### Scenario: пользователь ранее отказал
<!-- test: ReadinessCoordinatorMicrophoneAccessActionTests.test_denied_mapsTo_needsSystemSettings -->
- **WHEN** статус «отказано» или «ограничено»
- **THEN** действие `needsSystemSettings`, открывается панель приватности

#### Scenario: доступ уже выдан
<!-- test: ReadinessCoordinatorMicrophoneAccessActionTests.test_authorized_mapsTo_alreadyAuthorized -->
- **WHEN** доступ уже есть
- **THEN** действие `alreadyAuthorized`, запрос не показывается

---

### Requirement: Системный запрос универсального доступа не показывается дважды
<!-- id: ReadinessCoordinator.requestAccessibilityTrust -->
<!-- entities: ReadinessCoordinator, AccessibilityPromptGate, AccessibilityTrust -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Readiness/ReadinessCoordinator.swift, VoicePaste/UI/Onboarding/OnboardingView.swift -->
<!-- test_macos: VoicePasteTests/ReadinessCoordinatorMicrophoneAccessActionTests.swift:test_accessibilityPromptGate_coalescesOverlappingRequests_withoutCachingPermission -->

Запрос SHALL быть однопоточным: пока он в работе, повторные нажатия
объединяются. Перед запросом приложение делается активным и выводит своё
окно вперёд, иначе macOS не прикрепит решение к этому процессу. Уже выданный
доступ не запрашивается повторно.

#### Scenario: два нажатия подряд
<!-- test: ReadinessCoordinatorMicrophoneAccessActionTests.test_accessibilityPromptGate_coalescesOverlappingRequests_withoutCachingPermission -->
- **WHEN** запрос вызван повторно, пока предыдущий не завершён
- **THEN** второй запрос объединён с первым, разрешение не кэшируется

#### Scenario: доступ выдан, пока приложение активировалось
- **WHEN** к моменту запроса доступ уже есть
- **THEN** системное окно не показывается, состояние пересчитывается

#### Scenario: шаг универсального доступа открыт
- **WHEN** пользователь находится на шаге универсального доступа онбординга
- **THEN** статус перечитывается каждые 1,5 с, а ссылка на системные настройки
  появляется через 1,5 с после запроса — чтобы не открыть её поверх системного окна

---

### Requirement: Пока приложение не готово, доступен только онбординг
<!-- id: AppState.openMainOrOnboarding -->
<!-- entities: AppState, ReadinessState, MainContentSection -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/App/App.swift, VoicePaste/UI/MenuBar/MenuBarContentView.swift -->
<!-- test_macos: VoicePasteTests/AppStateRoutingTests.swift:test_openMainOrOnboarding_whenNotReady_neverOpensMain_forAnySection -->

Все входы в главное окно — меню-бар, переходы из HUD, повторное открытие
из Dock — SHALL проходить через один маршрутизатор. Пока готовность не
достигнута, открывается окно онбординга, а главное окно не открывается
никогда, ни с одной секцией.

#### Scenario: статистика при неготовом приложении
<!-- test: AppStateRoutingTests.test_openStatistics_whenNotReady_routesToOnboarding_notMainSection -->
- **WHEN** выбран пункт «Статистика» и приложение не готово
- **THEN** открыт онбординг, секция главного окна не запрошена

#### Scenario: открытие записи из HUD при неготовом приложении
<!-- test: AppStateRoutingTests.test_openHistoryRecord_whenNotReady_routesToOnboarding_notMainSection -->
- **WHEN** запрошено открытие записи в истории и приложение не готово
- **THEN** открыт онбординг, выбор записи не запрошен

#### Scenario: любая секция при неготовом приложении
<!-- test: AppStateRoutingTests.test_openMainOrOnboarding_whenNotReady_neverOpensMain_forAnySection -->
- **WHEN** запрошена любая из секций главного окна
- **THEN** открывается только онбординг

---

### Requirement: Первый запуск сам показывает онбординг
<!-- id: VoicePasteApp.body -->
<!-- entities: VoicePasteApp, AppState, ModelManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/App.swift -->

При запуске приложение SHALL дождаться фоновой проверки модели на диске,
пересчитать готовность и, если она не достигнута, открыть онбординг и выйти
на передний план. В остальных случаях приложение остаётся в меню-баре —
главное окно не открывается само.

#### Scenario: настроенная машина
- **WHEN** права выданы и модель установлена
- **THEN** окно не открывается, приложение живёт в меню-баре

#### Scenario: первый запуск
- **WHEN** готовность не достигнута
- **THEN** открыт онбординг, приложение активировано

---

### Requirement: Онбординг нельзя завершить без установленной модели
<!-- id: OnboardingView.canFinishModelStep -->
<!-- entities: OnboardingView, ModelState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Onboarding/OnboardingView.swift -->

Кнопка завершения на шаге модели SHALL быть доступна только когда модель
проверена на диске (`ready`, `unloaded` или `preparing`). Завершение закрывает
окно онбординга и, если приложение стало готовым, открывает главное окно.

#### Scenario: модель ещё не скачана
- **WHEN** состояние модели `notPrepared`, `downloading`, `verifying` или `failed`
- **THEN** завершение недоступно

#### Scenario: модель на диске
- **WHEN** состояние модели `unloaded`
- **THEN** шаг считается пройденным, завершение доступно

#### Scenario: завершение при достигнутой готовности
- **WHEN** нажато «Готово» и готовность `.ready`
- **THEN** окно онбординга закрыто, открыто главное окно

---

### Requirement: Присутствие в Dock подчинено готовности
<!-- id: AppState.applyDockVisibility -->
<!-- entities: AppState, AppSettings, ReadinessState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/UI/MenuBar/MenuBarContentView.swift -->
<!-- test_macos: VoicePasteTests/AppStateRoutingTests.swift:test_applyDockVisibility_whenNotReady_forcesRegular_evenWithShowInDockFalse -->

Пока приложение не готово или видно окно онбординга, политика активации
SHALL принудительно оставаться обычной (значок в Dock), какой бы ни была
настройка. Только у готового приложения настройка «Показывать в Dock»
решает, остаться ли ему резидентом меню-бара.

#### Scenario: не готово, показ в Dock выключен настройкой
<!-- test: AppStateRoutingTests.test_applyDockVisibility_whenNotReady_forcesRegular_evenWithShowInDockFalse -->
- **WHEN** готовность не достигнута и настройка выключена
- **THEN** политика активации обычная

#### Scenario: видно окно онбординга
- **WHEN** окно онбординга на экране
- **THEN** политика остаётся обычной, даже если готовность достигнута в этот момент

---

### Requirement: Настройки открываются своим окном
<!-- id: AppState.openSettings -->
<!-- entities: AppState, WindowRouter -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/App/AppDelegate.swift, VoicePaste/UI/MenuBar/MenuBarContentView.swift -->
<!-- test_macos: VoicePasteTests/AppStateRoutingTests.swift:test_openSettings_callsOpenSettingsAction_neverOpensMainWindow -->

Пункт «Настройки…» SHALL выводить приложение вперёд и открывать именно окно
настроек через документированное действие среды, а не главное окно и не
приватный селектор. Политика Dock при этом не меняется.

#### Scenario: настройки из меню-бара
<!-- test: AppStateRoutingTests.test_openSettings_callsOpenSettingsAction_neverOpensMainWindow -->
- **WHEN** выбран пункт «Настройки…»
- **THEN** вызвано действие открытия настроек, главное окно не открыто

#### Scenario: повторные вызовы
<!-- test: AppStateRoutingTests.test_openSettings_calledRepeatedly_stillNeverOpensMainWindow -->
- **WHEN** пункт выбран несколько раз подряд
- **THEN** главное окно по-прежнему не открывается

---

### Requirement: Клик по значку в Dock возвращает нужное окно
<!-- id: AppDelegate.applicationShouldHandleReopen -->
<!-- entities: AppDelegate, AppState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppDelegate.swift -->

Щелчок по значку в Dock при отсутствии видимых окон SHALL пересчитывать
готовность и открывать окно через тот же маршрутизатор, что и меню-бар.
Закрытие всех окон не завершает приложение: оно остаётся резидентом
меню-бара и горячей клавиши.

#### Scenario: видимых окон нет
- **WHEN** пользователь щёлкает значок в Dock
- **THEN** открыто главное окно или онбординг — по текущей готовности

#### Scenario: закрыто последнее окно
- **WHEN** закрыто последнее окно приложения
- **THEN** приложение продолжает работать

---

### Requirement: Второй экземпляр передаёт управление первому
<!-- id: SingleInstanceGuard.decide -->
<!-- entities: SingleInstanceGuard -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppDelegate.swift, VoicePaste/App/App.swift -->
<!-- test_macos: VoicePasteTests/AppTests.swift:testDefersToExistingInstance -->

До создания окон, горячей клавиши и базы приложение SHALL проверять, не
запущен ли уже экземпляр с тем же идентификатором бандла. Если запущен —
активировать самый старый (наименьший pid) и завершиться.

#### Scenario: копия уже работает
<!-- test: AppTests.testDefersToExistingInstance -->
- **WHEN** среди запущенных есть процесс с тем же идентификатором бандла
- **THEN** решение — передать управление процессу с наименьшим pid

#### Scenario: единственный экземпляр
<!-- test: AppTests.testProceedsWhenSoleInstance -->
- **WHEN** других экземпляров нет
- **THEN** решение — продолжить запуск

#### Scenario: чужие приложения
<!-- test: AppTests.testIgnoresOtherBundleIdentifiers -->
- **WHEN** запущены процессы с другими идентификаторами бандла
- **THEN** они не влияют на решение

---

### Requirement: Значок в меню-баре показывает фазу и готовность
<!-- id: AppState.menuBarSymbolName -->
<!-- entities: AppState, DictationPhase, ReadinessState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/UI/MenuBar/MenuBarContentView.swift -->

Значок SHALL отражать текущее состояние: запись — красная волна, расшифровка —
многоточие, покой — волна у готового приложения и красный треугольник
у неготового. Пункты меню остаются видимыми всегда, меняется только их
доступность.

#### Scenario: идёт запись
- **WHEN** фаза `recording`
- **THEN** значок `waveform.circle.fill` красного цвета

#### Scenario: приложение не готово
- **WHEN** фаза `idle` и готовность не `.ready`
- **THEN** значок `exclamationmark.triangle` красного цвета

---

### Requirement: Тестовый прогон не трогает данные пользователя
<!-- id: ProcessRuntime.isRunningTests -->
<!-- entities: ProcessRuntime, AppDelegate, AppSettings, HistoryStore -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/App.swift, VoicePaste/App/AppDelegate.swift -->
<!-- test_macos: VoicePasteTests/AppStateRoutingTests.swift:test_processRuntime_detectsXCTestHost -->

Так как тесты запускают само приложение как хост, при обнаружении тестовой
среды приложение SHALL использовать изолированные настройки и временный
каталог модели, заглушки истории и очереди, не регистрировать глобальную
клавишу и принимать политику активации, не выводящую окно на экран.

#### Scenario: обнаружена тестовая среда
<!-- test: AppStateRoutingTests.test_processRuntime_detectsXCTestHost -->
- **WHEN** процесс запущен под XCTest
- **THEN** `ProcessRuntime.isRunningTests` истинно

#### Scenario: запуск набора тестов
<!-- test: AppTests.testDelegateForcesProhibitedPolicyUnderTestRuntime -->
- **WHEN** приложение загружено как тестовый хост
- **THEN** политика активации `.prohibited`, окно не всплывает и не крадёт фокус

---

### Invariant: Диктовка разрешена только в состоянии готовности
<!-- entities: AppState, ReadinessState, HotkeyManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/UI/History/HistoryView.swift -->
<!-- verified_by_macos: VoicePasteTests/AppStateRoutingTests.swift:test_readinessState_whenNotReady_isNotEqualToReady_drivesHistoryViewDisabled -->

Пока готовность не равна `.ready`, глобальное сочетание не зарегистрировано,
а кнопки записи и импорта в панели инструментов недоступны — это выключенный
элемент, а не нажатие, оборачивающееся ошибкой.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: У приложения одно постоянное окно
<!-- entities: VoicePasteApp, MainWindowView, MainContentSection -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/App.swift, VoicePaste/UI/Main/MainWindowView.swift -->

История, статистика и очередь импорта SHALL жить в одном окне с
идентификатором `main` как его секции. Онбординг — отдельное окно и
единственное исключение, открываемое при запуске. Второго окна приложения не
создаётся ни одним переходом.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Целевая платформа — macOS 15 и новее на Apple Silicon
<!-- entities: VoicePasteApp -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste.xcodeproj/project.pbxproj -->

`MACOSX_DEPLOYMENT_TARGET` SHALL быть `15.0`, архитектура — `arm64`.

Порог поднят с 14.0 сознательно: перевод выделенного текста в учебном режиме
идёт системным фреймворком `Translation`, доступным с macOS 15. Облачный
переводчик не рассматривался — он нарушил бы обещание офлайна, на котором
стоит продукт.

Проверяется `xcodebuild -showBuildSettings` и `lipo -archs` по собранному
двоичному файлу.

> Last verified: 2026-09-20

---

### Invariant: Минимум главного окна вмещает обе его колонки
<!-- entities: MainWindowLayout, MainWindowView, HistoryView -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Main/MainWindowLayout.swift, VoicePaste/UI/Main/MainWindowView.swift, VoicePaste/UI/History/HistoryView.swift -->
<!-- test_macos: VoicePasteTests/MainWindowLayoutTests.swift -->

Минимальная ширина главного окна SHALL быть не меньше суммы минимальной
ширины боковой панели и минимальной ширины правой части. Ширина по
умолчанию SHALL вмещать боковую панель, раскрытую до предела, вместе с
правой частью на её минимуме.

Минимум окна не задаётся отдельным числом: он выводится из ширин колонок.
Заданный руками, он однажды разойдётся с ними — и разошёлся: 680 при
колонках 240 и 520 означало, что условия неразрешимы уже в исходном
положении, а при растягивании панели расходились сильнее, и правой части
было некуда сжиматься.

#### Scenario: панель растянута до предела
- **WHEN** боковая панель раскрыта на максимальную ширину
- **THEN** правая часть не уже своего минимума, а окно не превышает ширину по умолчанию

> Last verified: 2026-09-20

---

### Invariant: Пересчёт готовности всегда переприменяет политику Dock и регистрацию клавиши
<!-- entities: AppState, ReadinessCoordinator, HotkeyManager, ModelManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift -->

Единственный метод пересчёта SHALL одновременно обновлять регистрацию
глобального сочетания, политику присутствия в Dock и однократно запускать
прогрев модели. Поэтому выдача прав или появление модели вступают в силу без
перезапуска, а вызывающему не нужно помнить о трёх отдельных шагах.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Прогрев модели планируется не более одного раза за запуск
<!-- entities: AppState, ModelManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift -->

Однократный признак SHALL защищать от повторного планирования прогрева:
осознанная выгрузка из настроек или отдача памяти системе остаются в силе
до следующего настоящего запроса на распознавание.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Диагностический журнал не содержит текста расшифровок
<!-- entities: DiagnosticLog -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Logging/DiagnosticLog.swift -->

В журнал SHALL попадать только короткие имена событий и причины; аудио и текст
расшифровок туда не передаются. Файл лежит в
`Application Support/VoicePaste/Logs/`, перезаводится по достижении 1 000 000
байт и не создаётся вовсе под тестовым прогоном.

> Last verified: 2026-09-20 (commit 8f51051)

---

<!-- uncertainty: Маршрут «клик по значку в Dock» и автоматическое открытие онбординга при запуске проверены чтением AppDelegate и App.swift — тестов на них в VoicePasteTests нет. -->
<!-- uncertainty: Поведение системных запросов TCC (микрофон, универсальный доступ) проверяемо только на живой системе: тесты покрывают чистые функции отображения статуса в действие и однопоточность запроса. -->
