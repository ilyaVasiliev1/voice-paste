# Spec: model

> Извлечено из кода (spec-miner). Дата извлечения: 2026-09-20.
> Источник: VoicePaste/Core/Transcription (ModelManager, ModelState,
> LocalModelDetection, GitHubModelDownloader, WhisperKitTranscriber),
> VoicePaste/UI/Onboarding/OnboardingView.swift.
> Last verified: 2026-09-20 (commit 8f51051)

---

### Requirement: Модель, найденная на диске, не требует повторной загрузки
<!-- id: ModelManager.completeInitialModelDiscovery -->
<!-- entities: ModelManager, ModelState, LocalModelDetection -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift, VoicePaste/Core/Transcription/LocalModelDetection.swift -->
<!-- test_macos: VoicePasteTests/ModelManagerTests.swift:test_init_withVerifiedModelFilesOnDisk_startsUnloaded_notNotPrepared -->

При запуске приложение SHALL проверять каталог модели в фоне и, обнаружив
проверенную модель вместе с токенизатором, переходить в состояние `unloaded`
(«есть на диске, ещё не в памяти»). Обход каталога идёт вне главного актора;
результат устаревшего обхода не может перезаписать текущее состояние.

#### Scenario: модель и токенизатор на месте
<!-- test: ModelManagerTests.test_init_withVerifiedModelFilesOnDisk_startsUnloaded_notNotPrepared -->
- **WHEN** в каталоге лежит проверенная модель и полный токенизатор
- **THEN** состояние становится `unloaded`, загрузка из сети не предлагается

#### Scenario: модель есть, токенизатора нет
<!-- test: ModelManagerTests.test_init_withModelButMissingTokenizer_startsNotPrepared -->
- **WHEN** модель на диске, но файлы токенизатора отсутствуют или пусты
- **THEN** состояние `notPrepared`

#### Scenario: пустой каталог модели
<!-- test: ModelManagerTests.test_init_withEmptyModelDirectory_startsNotPrepared -->
- **WHEN** каталог модели пуст
- **THEN** состояние `notPrepared`

---

### Requirement: Проверка локальной модели отвергает оборванную загрузку
<!-- id: LocalModelDetection.discoverModelFolder -->
<!-- entities: LocalModelDetection, ModelCatalog -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/LocalModelDetection.swift -->
<!-- test_macos: VoicePasteTests/LocalModelDetectionTests.swift:test_discoverModelFolder_stubFoldersWithoutModelMil_returnsNil -->

Папка SHALL считаться моделью только когда у каждого из трёх обязательных
компонентов (`MelSpectrogram`, `AudioEncoder`, `TextDecoder`) есть непустой
полезный файл и суммарный размер папки не меньше 50 МБ. Поиск идёт вглубь
не более четырёх уровней — WhisperKit вкладывает модель в
`models/argmaxinc/whisperkit-coreml/<вариант>`.

#### Scenario: каркас папок без model.mil
<!-- test: LocalModelDetectionTests.test_discoverModelFolder_stubFoldersWithoutModelMil_returnsNil -->
- **WHEN** есть только пустые папки `.mlmodelc` с мелкими заглушками
- **THEN** модель не найдена

#### Scenario: файлы меньше порога правдоподобия
<!-- test: LocalModelDetectionTests.test_discoverModelFolder_tinyModelMilFiles_returnsNil -->
- **WHEN** суммарный размер кандидата меньше 50 МБ
- **THEN** модель не найдена

#### Scenario: вложенная настоящая модель
<!-- test: LocalModelDetectionTests.test_discoverModelFolder_nestedPlausibleModel_returnsNestedFolder -->
- **WHEN** модель лежит на несколько уровней ниже корня каталога
- **THEN** возвращается именно вложенная папка

#### Scenario: отсутствует один компонент
<!-- test: LocalModelDetectionTests.test_discoverModelFolder_missingOneComponent_returnsNil -->
- **WHEN** один из трёх обязательных компонентов отсутствует
- **THEN** модель не найдена

---

### Requirement: В сеть ходит только явная установка модели
<!-- id: ModelManager.installModel -->
<!-- entities: ModelManager, ModelCatalog, ModelDownloadSource -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift, VoicePaste/UI/Onboarding/OnboardingView.swift -->
<!-- test_macos: VoicePasteTests/ModelManagerTests.swift:test_AT099_runtimeLoadNeverInvokesFactoryWhenArtifactsAreMissing -->

`installModel()` SHALL быть единственным путём, которому разрешена загрузка из
сети, и вызываться только явным действием в онбординге или настройках.
Обычный `ensureLoaded()` (прогрев, диктовка, импорт) сетевую установку не
авторизует: отсутствующие файлы дают `verificationFailed`.

#### Scenario: рантайм-загрузка при отсутствующих файлах
<!-- test: ModelManagerTests.test_AT099_runtimeLoadNeverInvokesFactoryWhenArtifactsAreMissing -->
- **WHEN** модели или токенизатора нет и вызван `ensureLoaded()`
- **THEN** фабрика транскрайбера не вызывается, состояние `failed(.verificationFailed)`

#### Scenario: рантайм-загрузка получает несетевой эндпоинт
<!-- test: ModelManagerTests.test_AT099_runtimeLocalLoadReceivesNonNetworkEndpoint -->
- **WHEN** локальная модель загружается в память без сетевой установки
- **THEN** в WhisperKit передаётся `voicepaste-offline://local`

#### Scenario: локальная модель не загрузилась
<!-- test: ModelManagerTests.test_ensureLoaded_whenExistingLocalModelFails_doesNotRetryOrDownload -->
- **WHEN** загрузка существующей локальной модели завершилась ошибкой
- **THEN** повторов и обращения к сети не происходит

---

### Requirement: Параллельные загрузки модели объединяются в одну
<!-- id: ModelManager.ensureLoaded -->
<!-- entities: ModelManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->
<!-- test_macos: VoicePasteTests/ModelManagerTests.swift:test_AT099_repeatedPrewarmAndFirstUseShareOneLoad -->

Прогрев при готовности приложения и диктовка, начатая во время этого прогрева,
SHALL делить одну загрузку: повторная компиляция Core ML недопустима.
Завершившаяся позже старая загрузка не освобождает слот новой.

#### Scenario: прогрев и первая диктовка
<!-- test: ModelManagerTests.test_AT099_repeatedPrewarmAndFirstUseShareOneLoad -->
- **WHEN** `prewarm()` вызван несколько раз и во время загрузки пришёл
  `ensureLoaded()`
- **THEN** фабрика транскрайбера вызвана ровно один раз

#### Scenario: прогрев без модели на диске
- **WHEN** состояние `notPrepared` и вызван `prewarm()`
- **THEN** ничего не происходит — прогрев никогда не начинает загрузку 626 МБ

---

### Requirement: Честный прогресс загрузки модели
<!-- id: ModelManager.handleDownloadProgress -->
<!-- entities: ModelManager, ModelDownloadProgress, ModelCatalog -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift, VoicePaste/UI/Onboarding/OnboardingView.swift -->
<!-- test_macos: VoicePasteTests/ModelDownloadProgressTests.swift:test_completedAndTotalBytes_areDerivedFromFraction_neverZeroOfZero -->

Все показываемые числа SHALL выводиться из единственной надёжной величины —
доли выполнения. Всего байт — всегда каталожная константа 626 МБ, выполнено —
доля от неё, скорость — производная по монотонным часам, ETA — от сглаженной
скорости.

#### Scenario: байты выведены из доли
<!-- test: ModelDownloadProgressTests.test_completedAndTotalBytes_areDerivedFromFraction_neverZeroOfZero -->
- **WHEN** загрузчик отдаёт долю выполнения
- **THEN** показывается «N из 626 МБ», а не «0 из 0 МБ»

#### Scenario: всего байт не зависит от доли
<!-- test: ModelDownloadProgressTests.test_totalBytes_isAlwaysCatalogConstant_regardlessOfFractionValue -->
- **WHEN** доля принимает любое значение
- **THEN** общий объём остаётся каталожной константой

#### Scenario: скорость и ETA появляются не сразу
<!-- test: ModelDownloadProgressTests.test_speedAndETA_areNilUntilEnoughRealSamplesAccumulate_thenBecomePlausible -->
- **WHEN** накоплено меньше трёх замеров или прошло меньше секунды
- **THEN** скорость и ETA не показываются (UI говорит «Считаем время…»)

#### Scenario: ровный рост доли
<!-- test: ModelDownloadProgressTests.test_speed_isStable_whenFractionIncreasesInEvenSteps -->
- **WHEN** доля растёт равными шагами
- **THEN** показанная скорость устойчива

---

### Requirement: Сетевой сбой повторяется автоматически ограниченное число раз
<!-- id: ModelManager.loadWithAutoRetry -->
<!-- entities: ModelManager, ModelError -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->
<!-- test_macos: VoicePasteTests/ModelDownloadProgressTests.swift:test_networkDrop_exhaustsAutoRetries_thenLandsInFailed -->

Сетевая установка SHALL повторяться не более двух дополнительных раз с паузой
1,5 с; локальная загрузка не повторяется вовсе. Исчерпав попытки, менеджер
переходит в `failed` с кнопкой «Повторить». Отмена ошибкой модели не считается.

#### Scenario: связь не восстановилась
<!-- test: ModelDownloadProgressTests.test_networkDrop_exhaustsAutoRetries_thenLandsInFailed -->
- **WHEN** все попытки завершились сетевой ошибкой
- **THEN** состояние `failed`, файлы не удаляются

#### Scenario: сбой только на первой попытке
<!-- test: ModelDownloadProgressTests.test_autoRetry_repairsATransientFirstAttempt_withinASingleEnsureLoaded -->
- **WHEN** первая попытка упала, вторая прошла
- **THEN** один вызов `installModel()` завершается успехом

#### Scenario: повтор после исчерпанной сессии
<!-- test: ModelDownloadProgressTests.test_retryAfterExhaustedSession_resetsTracking_andCanSucceed -->
- **WHEN** пользователь нажал «Повторить» после отказа
- **THEN** счётчики прогресса сброшены, загрузка может завершиться успехом

---

### Requirement: Локальные файлы удаляются только при доказанной порче
<!-- id: ModelManager.indicatesUnreadableLocalModel -->
<!-- entities: ModelManager, ModelError -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->
<!-- test_macos: VoicePasteTests/ModelLoadFailureClassificationTests.swift:test_retriableDownloadFailure_doesNotJustifyDeletingTheModel -->

Классификация ошибки загрузки SHALL быть закрытой по умолчанию: удалять
скачанные 626 МБ разрешено, только когда ошибка прямо говорит о нечитаемых
файлах. Любая транспортная ошибка и любая неопознанная ошибка оставляют модель
на диске.

#### Scenario: сетевая ошибка при загрузке локальной модели
<!-- test: ModelLoadFailureClassificationTests.test_retriableDownloadFailure_doesNotJustifyDeletingTheModel -->
- **WHEN** ошибка — `RetriableDownloadFailure`, таймаут или `URLError`
- **THEN** модель не удаляется

#### Scenario: Core ML не читает model.mil
<!-- test: ModelLoadFailureClassificationTests.test_coreMLMILReadFailure_justifiesDeletingTheModel -->
- **WHEN** ошибка из домена `com.apple.CoreML` или упоминает `model.mil`
- **THEN** удаляется только полезная нагрузка модели, токенизатор сохраняется

#### Scenario: неизвестная ошибка
<!-- test: ModelLoadFailureClassificationTests.test_unknownError_failsClosed_andKeepsTheModel -->
- **WHEN** тип ошибки не распознан
- **THEN** модель сохраняется

#### Scenario: сообщение смешивает сеть и модель
<!-- test: ModelLoadFailureClassificationTests.test_mixedNetworkAndModelWording_isTreatedAsNetwork -->
- **WHEN** текст ошибки содержит и сетевые, и модельные признаки
- **THEN** ошибка считается сетевой, модель сохраняется

#### Scenario: отмена задачи
<!-- test: ModelLoadFailureClassificationTests.test_cancellation_doesNotJustifyDeletingTheModel -->
- **WHEN** загрузка отменена
- **THEN** ни файлы, ни состояние не трогаются

---

### Requirement: Удаление модели пользователем
<!-- id: ModelManager.deleteModel -->
<!-- entities: ModelManager, ModelState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift, VoicePaste/UI/Settings/SettingsView.swift -->
<!-- test_macos: VoicePasteTests/ModelManagerTests.swift:test_deleteModel_leavesModelDirectoryEmptyOnDisk -->

«Удалить модель» SHALL выгружать модель из памяти, отменять все незавершённые
загрузки и обходы каталога, очищать каталог модели и переводить состояние в
`notPrepared`. История, словарь и настройки не затрагиваются.

#### Scenario: удаление из состояния ready
<!-- test: ModelManagerTests.test_deleteModel_fromReady_setsNotPrepared -->
- **WHEN** модель загружена в память и подтверждено удаление
- **THEN** состояние `notPrepared`, каталог модели пуст

#### Scenario: поздно завершившаяся загрузка после удаления
<!-- test: ModelManagerTests.test_deleteModel_invalidatesLateFinishingLoad -->
- **WHEN** загрузка завершается уже после удаления
- **THEN** она не переводит состояние в `ready` и не восстанавливает файлы

#### Scenario: соседние файлы вне каталога модели
<!-- test: ModelManagerTests.test_deleteModel_doesNotTouchSiblingFilesOutsideModelDirectory -->
- **WHEN** рядом с каталогом модели лежат чужие файлы
- **THEN** они остаются нетронутыми

#### Scenario: повторное удаление
<!-- test: ModelManagerTests.test_deleteModel_fromNotPrepared_isIdempotent_noCrash -->
- **WHEN** удаление вызвано, когда модели нет
- **THEN** операция безвредна, состояние остаётся `notPrepared`

---

### Requirement: Выгрузка модели из памяти
<!-- id: ModelManager.endTask -->
<!-- entities: ModelManager, AppSettings -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift, VoicePaste/UI/Settings/SettingsView.swift -->
<!-- test_macos: VoicePasteTests/ModelManagerTests.swift:test_unloadTimer_firesAfterOneMinute_unlessCancelledByNewTask -->

По завершении диктовки или импорта SHALL запускаться таймер выгрузки на
`modelUnloadMinutes` минут; значение `0` (по умолчанию) означает «держать
модель в памяти» и таймер не ставит. Новая задача отменяет ожидающую выгрузку.
Кнопка «Выгрузить сейчас» и выход из приложения выгружают немедленно.

#### Scenario: настроенный таймаут
<!-- test: ModelManagerTests.test_unloadTimer_firesAfterOneMinute_unlessCancelledByNewTask -->
- **WHEN** задан ненулевой таймаут и после задачи прошло это время
- **THEN** модель выгружена из памяти

#### Scenario: значение по умолчанию
<!-- test: ModelManagerTests.test_endTask_zeroMinutes_neverSchedulesUnload -->
- **WHEN** `modelUnloadMinutes == 0`
- **THEN** таймер выгрузки не ставится, модель остаётся в памяти

#### Scenario: немедленная выгрузка
<!-- test: ModelManagerTests.test_unloadNow_releasesModel_immediately -->
- **WHEN** вызван `unloadNow()`
- **THEN** ссылка на движок сброшена, состояние `ready` переходит в `unloaded`

#### Scenario: отмена несуществующего таймера
<!-- test: ModelManagerTests.test_beginTask_withNoPendingTimer_isHarmless -->
- **WHEN** новая задача началась, когда выгрузка не запланирована
- **THEN** ничего не происходит

---

### Requirement: Модель отдаётся системе при нехватке памяти
<!-- id: ModelManager.startMemoryPressureMonitoring -->
<!-- entities: ModelManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->

Пока модель резидентна, менеджер SHALL слушать сигнал нехватки памяти от macOS
и освобождать её по этому сигналу, а не по фиксированному таймеру. Идущая
загрузка при этом не прерывается.

#### Scenario: система сообщила о нехватке памяти
- **WHEN** пришло событие `warning`/`critical`, загрузка не идёт, модель резидентна
- **THEN** модель выгружена, в журнал записано `reason=memoryPressure`

#### Scenario: сигнал во время загрузки
- **WHEN** событие пришло, пока идёт загрузка
- **THEN** загрузка продолжается, выгрузка не выполняется

---

### Requirement: Источник загрузки модели выбирается пользователем
<!-- id: ModelManager.load -->
<!-- entities: ModelDownloadSource, ModelCatalog, AppSettings, GitHubModelDownloader -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift, VoicePaste/Core/Transcription/GitHubModelDownloader.swift, VoicePaste/UI/Onboarding/OnboardingView.swift -->
<!-- test_macos: VoicePasteTests/ModelDownloadSourceTests.swift:test_installModel_withOfficialProvider_passesOfficialEndpointToFactory -->

Источник SHALL читаться живым значением в момент начала загрузки. `github`
скачивает архивы модели и токенизатора прямо с релиза проекта и раскладывает
их в ожидаемую WhisperKit структуру; `mirror` и `official` ведут через
HuggingFace-хаб. Уже проверенная локальная модель при смене источника не
перекачивается.

#### Scenario: выбран официальный источник
<!-- test: ModelDownloadSourceTests.test_installModel_withOfficialProvider_passesOfficialEndpointToFactory -->
- **WHEN** выбран `official` и начата установка
- **THEN** в фабрику транскрайбера передан `https://huggingface.co`

#### Scenario: выбрано зеркало
<!-- test: ModelDownloadSourceTests.test_installModel_withMirrorProvider_passesMirrorEndpointToFactory -->
- **WHEN** выбран `mirror` и начата установка
- **THEN** в фабрику передан `https://hf-mirror.com`

#### Scenario: источник изменён до первой загрузки
<!-- test: ModelDownloadSourceTests.test_changingProviderValue_beforeFirstLoad_isReadLiveNotCapturedAtInit -->
- **WHEN** значение источника изменено после создания менеджера, но до загрузки
- **THEN** используется новое значение, а не снятое при инициализации

#### Scenario: нужен только токенизатор
- **WHEN** модель уже на диске, а токенизатора нет
- **THEN** с релиза проекта докачивается только токенизатор (~640 КБ),
  модель не перекачивается

---

### Requirement: Отмена идущей загрузки
<!-- id: ModelManager.cancelDownload -->
<!-- entities: ModelManager, GitHubModelDownloader -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift, VoicePaste/UI/Onboarding/OnboardingView.swift -->

Кнопка «Отменить загрузку» SHALL останавливать идущую загрузку архива;
онбординг затем очищает уже записанное и возвращает состояние `notPrepared`,
чтобы можно было сменить источник и начать заново.

#### Scenario: отмена в онбординге
- **WHEN** идёт загрузка и нажата «Отменить загрузку»
- **THEN** загрузка остановлена, временные файлы убраны, состояние `notPrepared`

---

### Requirement: Отказ при нехватке места на диске
<!-- id: ModelManager.checkStorage -->
<!-- entities: ModelManager, ModelError, ModelCatalog -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->

Перед началом сетевой установки из состояния `notPrepared` SHALL проверяться
свободное место; если его меньше объёма модели, установка не начинается.

#### Scenario: места меньше объёма модели
- **WHEN** доступно меньше 626 МБ
- **THEN** состояние `failed(.insufficientStorage)`, загрузка не начинается

---

### Invariant: Ровно одна модель объёмом 626 МБ
<!-- entities: ModelCatalog, AppSettings -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelState.swift -->

Приложение SHALL использовать единственный вариант модели
`large-v3-v20240930_626MB`; объявленный размер `626 × 1024 × 1024` байт
используется и для проверки свободного места, и для расчёта прогресса,
и для подписи в настройках. Выбор модели пользователю не предлагается.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Доля загрузки не убывает и не достигает единицы
<!-- entities: ModelManager, ModelDownloadProgress -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->
<!-- verified_by_macos: VoicePasteTests/ModelDownloadProgressTests.swift:test_fraction_neverDecreases_evenWithFractionJitter -->

Показанная доля SHALL быть не меньше максимальной уже показанной в этой
попытке и не больше 0.999. Переход к «готово» происходит только сменой
состояния на `verifying`, а не долей, дошедшей до единицы. На новой попытке
максимум сбрасывается.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Экран загрузки обновляется не чаще четырёх раз в секунду
<!-- entities: ModelManager, ModelDownloadProgress -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->
<!-- verified_by_macos: VoicePasteTests/ModelDownloadProgressTests.swift:test_downloadingUpdates_areThrottledToApproximately4Hz -->

Между публикациями состояния `.downloading` SHALL проходить не меньше 0,25 с;
исключение — самый первый замер, который пропускается сразу, чтобы индикатор
не стоял на нуле. В журнал прогресс пишется не чаще одного раза на десять
процентов.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: ETA показывается только по достоверному сигналу
<!-- entities: ModelManager, ModelDownloadProgress -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->
<!-- verified_by_macos: VoicePasteTests/ModelDownloadProgressTests.swift:test_speedAndETA_areNilUntilEnoughRealSamplesAccumulate_thenBecomePlausible -->

Скорость SHALL сглаживаться экспоненциальным средним с весом 0.3 и считаться
достоверной только после трёх и более замеров и не менее одной секунды с
первого замера. До этого и скорость, и ETA отсутствуют. Время измеряется
монотонными часами, а не настенными.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Загрузка в память никогда не открывает сокет
<!-- entities: ModelManager, ModelCatalog -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/ModelManager.swift -->
<!-- verified_by_macos: VoicePasteTests/ModelManagerTests.swift:test_AT099_runtimeLocalLoadReceivesNonNetworkEndpoint -->

Любая загрузка, кроме явной установки, SHALL получать схему
`voicepaste-offline://local`: запасной путь WhisperKit к своему хабу падает до
того, как URLSession откроет соединение. HTTPS-эндпоинт получает только
`installModel()`.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Состояния `unloaded` и `preparing` не выводят приложение из готовности
<!-- entities: ModelState, ReadinessCoordinator -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Readiness/ReadinessCoordinator.swift, VoicePaste/Core/Transcription/ModelState.swift -->
<!-- verified_by_macos: VoicePasteTests/ReadinessModelStateObservationTests.swift:test_verifyingAfterLocalWarmUp_isNotReportedAsDownloading -->

Проверенная на диске, но не резидентная модель (`unloaded`) и модель, которую
вносят в память (`preparing`), SHALL означать готовность приложения. Блокирует
диктовку только настоящая загрузка из сети.

> Last verified: 2026-09-20 (commit 8f51051)

---

<!-- uncertainty: Проверка свободного места (checkStorage) и реакция на нехватку памяти не покрыты тестами: обе зависят от состояния реальной системы. -->
<!-- uncertainty: GitHubModelDownloader прочитан по вызовам из ModelManager; отдельного теста на распаковку архивов и докачку по частям в VoicePasteTests нет. -->
