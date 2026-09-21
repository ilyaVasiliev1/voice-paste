# Учебный режим

Долгая запись лекции с расшифровкой, которая пополняется по ходу, абзацами по
паузам и с метками времени. Отдельно от диктовки: там цель — вставить текст в
чужое окно и забыть, здесь — читать и возвращаться.

---

### Requirement: Запись лекции пополняет расшифровку по ходу
<!-- id: LectureRecorder.record -->
<!-- entities: LectureRecorder, Lecture, LectureParagraph -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Lecture/LectureRecorder.swift -->
<!-- test_macos: VoicePasteTests/LectureRecorderTests.swift -->

Пока идёт запись лекции, закрывшиеся окна SHALL распознаваться и добавляться к
расшифровке, не дожидаясь остановки. Остановка досчитывает незакрытый хвост.

Окно лекции короче окна диктовки: здесь важна не пропускная способность, а то,
как скоро сказанное появляется на экране.

#### Scenario: текст появляется до остановки
- **WHEN** запись идёт дольше одного окна
- **THEN** расшифровка уже содержит распознанное, а запись продолжается

#### Scenario: остановка досчитывает хвост
- **WHEN** запись остановлена посреди окна
- **THEN** хвост распознаётся и попадает в расшифровку

---

### Requirement: Движок распознавания лекции выбирается владельцем
<!-- id: LectureEngine.selection -->
<!-- entities: AppSettings, LiveTranscribing -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Lecture/LiveTranscribing.swift, VoicePaste/Core/Settings/AppSettings.swift, VoicePaste/App/AppState+Lecture.swift -->
<!-- test_macos: VoicePasteTests/LiveTranscriptionTests.swift:test_defaultEngine_followsTheMeasuredWinnerPerLanguage -->

Лекция SHALL распознаваться одним из двух движков на выбор: потоковым
распознавателем системы или Whisper через нарезку на окна.

Выбор не вкусовой. Замер 2026-09-21 на одной и той же синтезированной речи:

| | китайский, 29 с | русский, 22,5 с |
|---|---|---|
| система | 0,50 с, 2,4 % ошибок | 0,73 с, 14 % ошибок |
| Whisper | 2,26 с, 4,9 % ошибок | 1,84 с, 0 % ошибок |

На китайском система вчетверо быстрее и вдвое точнее, на русском Whisper
точнее в разы и единственный ставит знаки препинания. Поэтому по умолчанию
движок следует за языком, но остаётся переключаемым: речь владельца отличается
от синтезированной, и на ней разрыв может сложиться иначе.

Потоковый движок SHALL показывать уточняемый текст отдельно от устоявшегося:
это его смысл, а не украшение — иначе он ничем не лучше нарезки.

#### Scenario: китайская лекция по умолчанию
<!-- test: LiveTranscriptionTests.test_defaultEngine_followsTheMeasuredWinnerPerLanguage -->
- **WHEN** язык лекции китайский и движок не переопределён
- **THEN** используется потоковый распознаватель системы

#### Scenario: русская лекция по умолчанию
<!-- test: LiveTranscriptionTests.test_defaultEngine_followsTheMeasuredWinnerPerLanguage -->
- **WHEN** язык лекции русский и движок не переопределён
- **THEN** используется Whisper: система на русском ошибается вчетверо чаще

#### Scenario: язык, которого система не знает
- **WHEN** выбранного языка нет у потокового распознавателя
- **THEN** используется Whisper независимо от выбора движка

---

### Requirement: Язык лекции выбирается до записи
<!-- id: LectureView.languagePicker -->
<!-- entities: AppSettings, LectureRecorder -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/UI/Lecture/LectureView.swift, VoicePaste/Core/Settings/AppSettings.swift -->

Язык лекции SHALL выбираться на её экране до начала записи и действовать на
всю запись. Выбор сохраняется между лекциями.

Автоматическое определение остаётся доступным, но по умолчанию язык задаётся
явно. Причина в том, как ведёт себя модель при ошибке определения: она не
отказывается распознавать, а передаёт услышанное словами назначенного языка —
китайская речь выходит набором русских слов и читается как плохой перевод.
На окне в несколько секунд такая ошибка обычна, а переключение говорящего
между языками делает её ещё вероятнее.

Явный выбор эту ошибку исключает: назначенный язык действует на все окна
записи и не зависит от того, что модель услышала в первых секундах.

#### Scenario: язык задан явно
- **WHEN** на экране лекции выбран язык и начата запись
- **THEN** все окна распознаются этим языком, независимо от определения

#### Scenario: выбор недоступен во время записи
- **WHEN** запись идёт
- **THEN** переключатель языка заблокирован: смена языка посреди записи
  разошлась бы с уже распознанным

---

### Requirement: Абзацы нарезаются по паузам говорящего
<!-- id: LectureParagraphBuilder.build -->
<!-- entities: LectureParagraphBuilder, LectureParagraph -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Lecture/LectureParagraphBuilder.swift -->
<!-- test_macos: VoicePasteTests/LectureParagraphBuilderTests.swift -->

Расшифровка SHALL делиться на абзацы по паузам между сегментами: пауза длиннее
порога начинает новый абзац, короче — продолжает текущий. У каждого абзаца есть
время начала и конца.

Сегменты приходят из нескольких окон, и окна перекрываются: время сегмента из
следующего окна может оказаться раньше конца уже принятого. Такая
отрицательная «пауза» не означает, что говорящий не молчал, — она означает
перекрытие. Абзац SHALL начинаться и на границе окна, если сегмент начинается
раньше конца предыдущего: иначе вся лекция сливается в одно полотно.

Порог — настройка, а не константа: у разных говорящих разный темп.

Языковая модель здесь не участвует. Заголовков, тезисов и выводов продукт не
сочиняет: он показывает сказанное, разбитое по настоящим паузам, и ничего не
добавляет от себя.

#### Scenario: пауза длиннее порога начинает абзац
- **WHEN** между сегментами пауза больше порога
- **THEN** следующий сегмент открывает новый абзац

#### Scenario: пауза короче порога продолжает абзац
- **WHEN** между сегментами пауза меньше порога
- **THEN** сегмент дописывается в текущий абзац

#### Scenario: пустых абзацев не бывает
- **WHEN** среди сегментов есть пустые по тексту
- **THEN** они не порождают абзацев

---

### Requirement: Лекция хранится целиком с абзацами и временем
<!-- id: LectureStore.save -->
<!-- entities: LectureStore, Lecture, LectureParagraph -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Data/LectureStore.swift, VoicePaste/Data/Migrations.swift -->
<!-- test_macos: VoicePasteTests/LectureStoreTests.swift -->

Лекция и её абзацы SHALL сохраняться одной транзакцией. Абзацы хранятся
порядком и со своим временем, чтобы к месту в записи можно было вернуться.

#### Scenario: лекция переживает перезапуск
- **WHEN** лекция сохранена и база открыта заново
- **THEN** читаются и лекция, и все её абзацы в прежнем порядке

#### Scenario: удаление лекции уносит её абзацы
- **WHEN** лекция удалена
- **THEN** её абзацев в базе не остаётся

---

### Requirement: Запись продолжает сохранённую лекцию
<!-- id: LectureContinuation.appending -->
<!-- entities: LectureContinuation, LectureDetail, AppState -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Lecture/LectureContinuation.swift, VoicePaste/App/AppState+Lecture.swift, VoicePaste/UI/Lecture/LectureView.swift -->
<!-- test_macos: VoicePasteTests/LectureContinuationTests.swift:test_newParagraphs_followTheLectureInTimeAndOrder -->

У открытой сохранённой лекции SHALL быть действие «Продолжить запись». Новые
абзацы дописываются в конец той же лекции, а не в новую: время идёт дальше от
конца лекции, порядок продолжается, длительность и число слов пересчитываются,
название и дата создания остаются прежними.

Просьба владельца 21.09.2026: лекция не обязана заканчиваться первой остановкой
— после перерыва её дописывают.

#### Scenario: продолжение после перерыва
<!-- test: LectureContinuationTests.test_newParagraphs_followTheLectureInTimeAndOrder -->
- **WHEN** лекция длиной 46:00 продолжена, и новый абзац начался на 0:05 новой записи
- **THEN** он стоит последним со временем 46:05, длительность — сумма обеих записей

#### Scenario: продолжение без новой речи
<!-- test: LectureContinuationTests.test_nothingNew_keepsTheLectureUnchanged -->
- **WHEN** продолжение остановлено, а новых абзацев нет
- **THEN** лекция не меняется

#### Scenario: название и дата
<!-- test: LectureContinuationTests.test_newParagraphs_followTheLectureInTimeAndOrder -->
- **WHEN** лекция продолжена
- **THEN** её название и дата создания прежние, отметка изменения новая

---

### Invariant: Окно лекции короче окна диктовки
<!-- entities: LectureRecorder -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Lecture/LectureRecorder.swift -->
<!-- test_macos: VoicePasteTests/LectureRecorderTests.swift -->

Окно лекции SHALL быть не длиннее 10 секунд при перекрытии не меньше 1 секунды.

Замер (`docs/status.md`): накладная около 0,51 с на вызов плюс 0,063 с на
секунду речи. Окно в 10 с считается около 1,1 с — значит сказанное появляется
на экране примерно через секунду после того, как окно закрылось. Более длинное
окно экономило бы процессор, но ровно за счёт того, ради чего режим и сделан.

> Last verified: 2026-09-20

---

### Invariant: Порог паузы — от 1 до 10 секунд, по умолчанию 2
<!-- entities: AppSettings, LectureParagraphBuilder -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Settings/AppSettings.swift -->
<!-- test_macos: VoicePasteTests/LectureParagraphBuilderTests.swift -->

`lectureParagraphPauseSeconds` SHALL лежать в пределах от 1 до 10, по умолчанию
2. Значения вне пределов приводятся к ближайшему допустимому.

> Last verified: 2026-09-20

---

<!-- uncertainty: Экран учебного режима и перевод выделенного проверены только чтением кода — слой SwiftUI в проекте не тестируется. -->
