# Spec: dictation

> Извлечено из кода (spec-miner). Дата извлечения: 2026-09-20.
> Источник: VoicePaste/Core/Dictation, VoicePaste/Core/Audio, VoicePaste/Core/Hotkey,
> VoicePaste/Core/Insertion, VoicePaste/Core/HUD, VoicePaste/App/AppState.swift.
> Last verified: 2026-09-20 (commit 8f51051)

---

### Requirement: Запуск и остановка диктовки горячей клавишей
<!-- id: DictationStateMachine.handleHotkeyDown -->
<!-- entities: DictationStateMachine, DictationPhase, RecordingMode -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Dictation/DictationStateMachine.swift, VoicePaste/App/AppState.swift -->
<!-- test_macos: VoicePasteTests/DictationStateMachineTests.swift:test_toggle_secondPress_stopsAndProcesses -->

Приложение SHALL вести диктовку конечным автоматом из трёх фаз (`idle`,
`recording`, `processing`). В режиме `toggle` запись начинается и
заканчивается нажатиями клавиши; в режиме `hold` — нажатием и отпусканием.
Автомат не выполняет ввода-вывода: он возвращает эффект, который исполняет
`AppState`.

#### Scenario: первое нажатие в режиме toggle
<!-- test: DictationStateMachineTests.test_toggle_firstPress_startsCapture -->
- **WHEN** фаза `idle`, режим `toggle`, приходит нажатие клавиши
- **THEN** фаза становится `recording`, возвращается эффект `startCapture`

#### Scenario: второе нажатие в режиме toggle
<!-- test: DictationStateMachineTests.test_toggle_secondPress_stopsAndProcesses -->
- **WHEN** фаза `recording`, режим `toggle`, приходит нажатие клавиши
- **THEN** фаза становится `processing`, возвращается `stopCaptureAndProcess`

#### Scenario: удержание клавиши
<!-- test: DictationStateMachineTests.test_hold_keyDown_startsCapture_keyUp_stopsAndProcesses -->
- **WHEN** режим `hold`: нажатие из `idle`, затем отпускание
- **THEN** запись начинается на нажатии и завершается на отпускании

#### Scenario: автоповтор клавиши при удержании
<!-- test: DictationStateMachineTests.test_hold_keyRepeatWhileRecording_isNoOp -->
- **WHEN** режим `hold`, фаза `recording`, приходит повторное нажатие
- **THEN** эффект `none`, фаза остаётся `recording`

#### Scenario: отпускание клавиши в режиме toggle
<!-- test: DictationStateMachineTests.test_toggle_keyUp_isNoOp_inAnyPhase -->
- **WHEN** режим `toggle`, приходит отпускание клавиши в любой фазе
- **THEN** эффект `none`, фаза не меняется

---

### Requirement: Нажатие во время расшифровки не трогает идущую задачу
<!-- id: DictationStateMachine.handleHotkeyDown -->
<!-- entities: DictationStateMachine, HUDState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Dictation/DictationStateMachine.swift, VoicePaste/App/AppState.swift -->
<!-- test_macos: VoicePasteTests/DictationStateMachineTests.swift:test_toggle_pressDuringProcessing_isIgnored_currentJobPreserved -->

Пока идёт расшифровка, новое нажатие горячей клавиши SHALL возвращать
`alreadyProcessing`: текущая задача сохраняется, новая сессия не начинается,
пользователю показывается сообщение «Расшифровка уже идёт».

#### Scenario: нажатие в фазе processing
<!-- test: DictationStateMachineTests.test_toggle_pressDuringProcessing_isIgnored_currentJobPreserved -->
- **WHEN** фаза `processing`, приходит нажатие клавиши
- **THEN** фаза остаётся `processing`, эффект `alreadyProcessing`, в HUD —
  ошибка `dictation.alreadyProcessing`

---

### Requirement: Кнопки HUD завершают и отменяют сессию независимо от режима
<!-- id: DictationStateMachine.finishFromUI -->
<!-- entities: DictationStateMachine, HUDState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Dictation/DictationStateMachine.swift, VoicePaste/Core/HUD/HUDContentView.swift -->
<!-- test_macos: VoicePasteTests/DictationStateMachineTests.swift:test_finishFromUI_holdMode_whileRecording_stopsAndProcesses -->

Кнопка «✓» SHALL завершать запись и отправлять её на расшифровку в любом
режиме; кнопка «✕» SHALL отбрасывать запись и возвращать фазу сразу в `idle`,
минуя `processing` — расшифровки и записи в историю не происходит.

#### Scenario: завершение мышью в режиме hold
<!-- test: DictationStateMachineTests.test_finishFromUI_holdMode_whileRecording_stopsAndProcesses -->
- **WHEN** режим `hold`, фаза `recording`, нажата кнопка «✓»
- **THEN** фаза `processing`, эффект `stopCaptureAndProcess`

#### Scenario: отмена мышью
<!-- test: DictationStateMachineTests.test_cancelFromUI_whileRecording_discardsAndReturnsToIdle -->
- **WHEN** фаза `recording`, нажата кнопка «✕»
- **THEN** фаза `idle`, эффект `cancelCapture`, буфер аудио отброшен

#### Scenario: кнопки вне записи
<!-- test: DictationStateMachineTests.test_cancelFromUI_outsideRecording_isNoOp -->
- **WHEN** фаза `idle` или `processing`, нажата кнопка HUD
- **THEN** эффект `none`, фаза не меняется

---

### Requirement: Диктовка не начинается, пока приложение не готово
<!-- id: AppState.handleHotkeyDown -->
<!-- entities: AppState, ReadinessState, HUDState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift -->

Если на момент нажатия из фазы `idle` `readiness.state` не равен `.ready`,
приложение SHALL не начинать запись, показать причину в HUD и записать
её в диагностический журнал.

#### Scenario: нажатие при неготовом приложении
- **WHEN** `readiness.state != .ready` и приходит нажатие горячей клавиши из `idle`
- **THEN** запись не начинается, в HUD показана строка
  `readiness.state.statusLocalizationKey`, в журнал уходит `dictation.notReady`

---

### Requirement: Захват микрофона на время одной сессии
<!-- id: AudioCaptureService.start -->
<!-- entities: AudioCaptureService, AudioSampleAccumulator, AudioTapProcessor -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Audio/AudioCaptureService.swift -->
<!-- test_macos: VoicePasteTests/AudioCaptureServiceTests.swift:test_process_convertsSyntheticBuffer_andAccumulatesSamples -->

На каждую сессию SHALL создаваться новый `AVAudioEngine`; он освобождается
при остановке или отказе. Входной поток преобразуется в 16 кГц моно Float32
и накапливается в потокобезопасном аккумуляторе. Перед стартом статус доступа
к микрофону перепроверяется, иначе бросается `microphoneUnavailable`.

#### Scenario: преобразование входного буфера
<!-- test: AudioCaptureServiceTests.test_process_convertsSyntheticBuffer_andAccumulatesSamples -->
- **WHEN** тап отдаёт буфер произвольного формата
- **THEN** в аккумуляторе оказываются сэмплы 16 кГц моно Float32

#### Scenario: остановка без старта
<!-- test: AudioCaptureServiceTests.test_stop_withoutHavingStarted_returnsEmptyBuffer_andDoesNotCrash -->
- **WHEN** `stop()` вызван без предшествующего `start()`, в том числе повторно
- **THEN** возвращается пустой буфер, сбоя не происходит

#### Scenario: доступ к микрофону отозван
- **WHEN** `AVCaptureDevice.authorizationStatus(for: .audio) != .authorized`
- **THEN** `start()` бросает `AudioCaptureError.microphoneUnavailable`, движок не создаётся

---

### Requirement: Сбой микрофона показывает одно релевантное действие
<!-- id: AppState.beginRecording -->
<!-- entities: AppState, HUDState, HUDErrorAction -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/Core/HUD/HUDState.swift -->

Если захват не удалось начать, приложение SHALL вернуться в `idle`, показать
`dictation.microphoneError` с единственным действием «Выбрать микрофон»
и записать причину в журнал.

#### Scenario: движок не стартовал
- **WHEN** `audioCapture.start()` бросает ошибку
- **THEN** фаза `idle`, HUD `.error(message:action: .selectMicrophone)`,
  в журнале `capture.start.failed`

---

### Requirement: Escape приостанавливает запись, не стирая накопленное
<!-- id: AppState.cancelDictationWithEscape -->
<!-- entities: AppState, AudioCaptureService, HotkeyManager, HUDState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/Core/Audio/AudioCaptureService.swift -->

Escape во время записи SHALL останавливать только микрофон, сохраняя
накопленные сэмплы, и показывать состояние `cancelledWithUndo` с возвратной
стрелкой. Возврат подключает новый движок к тому же аккумулятору, так что обе
произнесённые части становятся одной расшифровкой. Явный «✕» в этом состоянии
— единственный необратимый путь.

#### Scenario: пауза по Escape
- **WHEN** фаза `recording`, не на паузе, нажат Escape
- **THEN** захват приостановлен, накопленные сэмплы сохранены, HUD
  `cancelledWithUndo`, регистрация Escape снята

#### Scenario: возврат к записи
- **WHEN** в паузе нажата возвратная стрелка и новый движок стартовал
- **THEN** запись продолжается в тот же аккумулятор, отсчёт времени
  продолжается с накопленного значения

#### Scenario: отказ при возобновлении
- **WHEN** при возврате `audioCapture.resume()` бросает ошибку
- **THEN** сессия отменяется, буфер отбрасывается, показан
  `dictation.microphoneError` с действием «Выбрать микрофон»

---

### Requirement: Слишком короткая или тихая запись не доходит до модели
<!-- id: AppState.endRecordingAndProcess -->
<!-- entities: AppState, AudioCaptureService, HUDState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift -->

Перед показом состояния «расшифровка» приложение SHALL проверять длину буфера
и его RMS. Не прошедший проверку буфер не передаётся в модель, история не
пишется, показывается `dictation.emptyAudio`.

#### Scenario: случайное двойное нажатие
- **WHEN** в буфере меньше 8000 сэмплов (0,5 с при 16 кГц)
- **THEN** фаза `idle`, HUD `.error(dictation.emptyAudio)`, модель не вызывается

#### Scenario: тишина в течение всей записи
- **WHEN** RMS последнего захвата меньше 0.004
- **THEN** фаза `idle`, HUD `.error(dictation.emptyAudio)`, модель не вызывается

---

### Requirement: Расшифровка, нормализация и доставка текста
<!-- id: AppState.transcribeAndFinish -->
<!-- entities: AppState, ModelManager, TextNormalizer, TextInserter, Transcript -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift -->

После остановки записи приложение SHALL загрузить модель, распознать речь,
применить словарь и нормализацию, доставить текст в активное приложение или
в буфер обмена, сохранить запись в историю (если история включена) и показать
исход в HUD.

#### Scenario: удачная диктовка с включённой авто-вставкой
- **WHEN** распознавание завершилось и `settings.autoInsertEnabled == true`
- **THEN** текст нормализован, выполнена попытка вставки, запись сохранена
  со `source = .dictation` и исходом `inserted` либо `copied`

#### Scenario: авто-вставка выключена
- **WHEN** `settings.autoInsertEnabled == false`
- **THEN** текст кладётся в буфер обмена, исход записи `copied` — текст
  никогда не отбрасывается молча

#### Scenario: сбой распознавания
- **WHEN** загрузка модели или распознавание бросили ошибку
- **THEN** показан `dictation.transcriptionFailed`, таймер выгрузки модели
  перезапущен, причина ушла в журнал

#### Scenario: длинная запись считается по ходу, а не целиком после остановки
- **WHEN** длительность записи превысила одно окно
- **THEN** закрывшиеся окна распознаются во время записи, а после остановки
  досчитывается только незакрытый хвост

#### Scenario: история не приняла запись
- **WHEN** сохранение в историю бросило ошибку, а текст уже доставлен
- **THEN** исход диктовки не меняется — текст доставлен, — но причина отказа
  уходит в журнал как `dictation.historySaveFailed`

История необязательна и её отказ SHALL НЕ превращать удачную диктовку в
ошибку. Но он SHALL оставлять след: потерянная запись без строки в журнале
неотличима от записи, которой не было.

---

### Requirement: Вставка текста в чужое приложение одним HID-сочетанием
<!-- id: TextInserter.insert -->
<!-- entities: TextInserter, FrontAppSnapshot, InsertionOutcome -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Insertion/TextInserter.swift -->
<!-- test_macos: VoicePasteTests/TextInserterTests.swift:test_AT084_everyExternalTextApplicationUsesTheSameHIDRoute -->

Доставка SHALL быть одинаковой для всех внешних приложений: текст кладётся
в буфер обмена, затем посылается ровно одна HID-последовательность ⌘V
приложению, которое было активным в начале записи и остаётся активным сейчас.
Ни AX-мутации, ни AppleScript, ни профилей приложений, ни повторных попыток.

#### Scenario: одинаковый маршрут для любого внешнего приложения
<!-- test: TextInserterTests.test_AT084_everyExternalTextApplicationUsesTheSameHIDRoute -->
- **WHEN** целевое приложение — нативное, Electron или веб-редактор
- **THEN** используется один и тот же HID-маршрут вставки

#### Scenario: полная последовательность клавиш
<!-- test: TextInserterTests.test_AT084_HIDPasteUsesACompleteModifierAndVKeySequence -->
- **WHEN** выполняется вставка
- **THEN** посылаются четыре события: Command down, V down, V up, Command up

---

### Requirement: Без доступа или при смене фокуса текст остаётся в буфере
<!-- id: TextInserter.insert -->
<!-- entities: TextInserter, FrontAppSnapshot, AccessibilityTrust -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Insertion/TextInserter.swift -->
<!-- test_macos: VoicePasteTests/TextInserterTests.swift:test_AT008_changedOrMissingTarget_keepsExactTextOnClipboard -->

Если универсальный доступ не выдан, снимок активного приложения отсутствует
или фронтальное приложение сменилось, вставка SHALL не выполняться, а результат
— оставаться в буфере обмена с исходом `copied`.

#### Scenario: нет универсального доступа
<!-- test: TextInserterTests.test_EC002_noAccessibilityTrust_keepsExactTextOnClipboard -->
- **WHEN** `AccessibilityTrust.isGranted == false`
- **THEN** вставка не посылается, текст в буфере обмена, исход `copied`

#### Scenario: фокус ушёл в другое приложение
<!-- test: TextInserterTests.test_AT008_changedOrMissingTarget_keepsExactTextOnClipboard -->
- **WHEN** pid фронтального приложения отличается от снятого в начале записи
- **THEN** вставка не посылается, текст в буфере обмена, исход `copied`

---

### Requirement: Файловый менеджер и системные настройки не цель для вставки
<!-- id: TextInserter.pasteTargetEligibility -->
<!-- entities: TextInserter -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Insertion/TextInserter.swift -->
<!-- test_macos: VoicePasteTests/TextInserterTests.swift:test_AT055_nonTextDestinationsRemainClipboardOnly -->

Короткий список приложений (Finder, System Preferences, System Settings, сам
VoicePaste) SHALL считаться не текстовым назначением: туда текст только
копируется.

#### Scenario: активен Finder
<!-- test: TextInserterTests.test_AT055_nonTextDestinationsRemainClipboardOnly -->
- **WHEN** снимок активного приложения — `com.apple.finder`
- **THEN** `pasteTargetEligibility` возвращает `clipboardOnly`, вставка не посылается

---

### Requirement: Глобальная клавиша регистрируется системой, а не перехватом потока
<!-- id: HotkeyManager.start -->
<!-- entities: HotkeyManager, HotkeyShortcut -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Hotkey/HotkeyManager.swift -->
<!-- test_macos: VoicePasteTests/HotkeyManagerTests.swift:test_shortcutMatches_exactCombination_isTrue -->

Сочетание SHALL регистрироваться через Carbon `RegisterEventHotKey`: macOS
присылает только зарегистрированные комбинации, обычный ввод не проходит через
приложение. Escape регистрируется только на время активной записи; пока
приложение не готово, не зарегистрировано ничего — сочетание достаётся
активному приложению.

#### Scenario: точное совпадение комбинации
<!-- test: HotkeyManagerTests.test_shortcutMatches_exactCombination_isTrue -->
- **WHEN** код клавиши и маска модификаторов совпадают с настроенными
- **THEN** сочетание считается совпавшим

#### Scenario: лишний модификатор
<!-- test: HotkeyManagerTests.test_shortcutMatches_extraModifier_isFalse -->
- **WHEN** нажато настроенное сочетание плюс лишний модификатор
- **THEN** совпадения нет

#### Scenario: смена сочетания в настройках
- **WHEN** пользователь записал новое сочетание и регистрация активна
- **THEN** прежняя регистрация снимается и ставится новая

#### Scenario: методы жизненного цикла без старта
<!-- test: HotkeyManagerTests.test_lifecycleMethodsWithoutStart_haveNoSystemSideEffects -->
- **WHEN** вызваны `stop()`/`setEscapeCancellationEnabled` без `start()`
- **THEN** системных побочных эффектов нет

---

### Requirement: Завершение приложения освобождает микрофон, клавишу и модель
<!-- id: AppState.prepareForQuit -->
<!-- entities: AppState, AudioCaptureService, HotkeyManager, ModelManager -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/UI/MenuBar/MenuBarContentView.swift -->

Пункт меню «Выйти» SHALL останавливать захват, снимать регистрацию горячих
клавиш и безусловно выгружать модель до завершения процесса.

#### Scenario: выход из меню-бара
- **WHEN** выбран пункт «Выйти»
- **THEN** захват остановлен, регистрация снята, модель выгружена, затем
  приложение завершается

---

### Invariant: Порог осмысленной записи — 0,5 секунды и RMS 0.004
<!-- entities: AppState, AudioCaptureService -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift -->

Буфер SHALL считаться пригодным для распознавания только при длине не менее
8000 сэмплов (0,5 с при 16 кГц) и RMS не ниже 0.004. RMS накапливается на
аудиопотоке во время захвата, поэтому решение не требует второго прохода
по буферу на главном акторе.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Аудио всегда 16 кГц моно Float32
<!-- entities: AudioCaptureService, AudioDecoder, TranscriptionRequest -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Audio/AudioCaptureService.swift, VoicePaste/Core/Import/AudioDecoder.swift -->
<!-- verified_by_macos: VoicePasteTests/AudioCaptureServiceTests.swift:test_process_convertsSyntheticBuffer_andAccumulatesSamples -->

И микрофонный захват, и декодер импорта SHALL отдавать один формат — 16 000 Гц,
один канал, Float32. Он же объявлен по умолчанию в `TranscriptionRequest`.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: HUD во время записи обновляется не чаще десяти раз в секунду
<!-- entities: AppState, HUDWindowController -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift -->

Уровень сигнала опрашивается каждые 100 мс, таймер прошедшего времени —
каждые 200 мс, а оба источника проходят через общий сток: повторный показ
разрешён не раньше, чем через 0,1 с после предыдущего. Принудительный показ
допускается только в момент старта и возобновления записи.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Готовый текст всегда оказывается в буфере обмена
<!-- entities: TextInserter -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Insertion/TextInserter.swift -->
<!-- verified_by_macos: VoicePasteTests/TextInserterTests.swift:test_copyToClipboard_replacesPreviousClipboardContent -->

Копирование в буфер SHALL выполняться до любой проверки возможности вставки —
это не запасной путь, а обязательный шаг. Поэтому ручное ⌘V доступно всегда,
каким бы ни был исход автоматической вставки.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Приостановленная диктовка не живёт дольше четырёх секунд
<!-- entities: AppState, HUDState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift, VoicePaste/Core/HUD/HUDState.swift -->

Пауза по Escape SHALL сама завершаться отменой через 4 секунды; тот же
интервал задан и как время автоскрытия состояния `cancelledWithUndo`.
Возврат к записи отменяет этот таймер.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Отменённая запись не оставляет следов
<!-- entities: AppState, Transcript, AudioCaptureService -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/App/AppState.swift -->
<!-- verified_by_macos: VoicePasteTests/DictationStateMachineTests.swift:test_cancelFromUI_whileRecording_discardsAndReturnsToIdle -->

Отмена SHALL останавливать захват и отбрасывать буфер: распознавание не
запускается, запись в историю не создаётся, снимок активного приложения
сбрасывается.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Окна записи нарезаются подряд, с перекрытием и без пропусков
<!-- entities: DictationWindowPlanner -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Dictation/DictationWindowPlanner.swift -->
<!-- test_macos: VoicePasteTests/DictationWindowPlannerTests.swift -->

Нарезка записи на окна SHALL покрывать её целиком: каждое следующее окно
начинается раньше конца предыдущего на величину перекрытия, а между окнами не
остаётся неучтённых сэмплов. Хвост короче окна распознаётся как есть — он не
дополняется и не отбрасывается.

Перекрытие существует затем, чтобы слово на границе попало в оба окна и
склейка смогла убрать повтор. Нулевое перекрытие режет слова, а перекрытие
шире окна зацикливает нарезку — ни то, ни другое не допускается.

#### Scenario: запись короче одного окна
- **WHEN** запись не достигла длины окна
- **THEN** окон не планируется вовсе, запись распознаётся одним проходом

#### Scenario: запись длиннее окна
- **WHEN** доступного звука хватает на окно
- **THEN** выдаётся окно, а следующее начинается на величину перекрытия раньше
  его конца

#### Scenario: остановка посреди окна
- **WHEN** запись остановлена, а последнее окно не закрылось
- **THEN** хвост от конца последнего выданного окна за вычетом перекрытия и до
  конца записи выдаётся одним отрезком

> Last verified: 2026-09-20

---

<!-- uncertainty: HUD-состояния `inserted`/`copied`/`cancelled`/`error` и их таймеры автоскрытия проверены только чтением кода — автотестов на HUDWindowController и HUDContentView в VoicePasteTests нет. -->
<!-- uncertainty: Переход по Escape и возврат к той же записи (AudioCaptureService.pause/resume) не покрыт тестом: проверить можно только с живым AVAudioEngine. -->
