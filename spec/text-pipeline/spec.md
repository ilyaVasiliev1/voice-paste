# Spec: text-pipeline

> Извлечено из кода (spec-miner). Дата извлечения: 2026-09-20.
> Источник: VoicePaste/Core/Normalizer/TextNormalizer.swift,
> VoicePaste/Core/Transcription (Transcribing, WhisperKitTranscriber,
> TrailingHallucinationFilter), VoicePaste/Domain/VocabularyEntry.swift.
> Last verified: 2026-09-20 (commit 8f51051)

---

### Requirement: Нормализация пробелов и пунктуации
<!-- id: TextNormalizer.normalizeWhitespaceAndTypography -->
<!-- entities: TextNormalizer, NormalizationChange -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Normalizer/TextNormalizer.swift -->
<!-- test_macos: VoicePasteTests/TextNormalizerTests.swift:test_AT013_collapsesRepeatedSpaces_andRemovesSpaceBeforePunctuation -->

Распознанный текст SHALL проходить детерминированную чистку: повторные пробелы
и табуляции схлопываются в один, пробелы перед `,.!?:;` убираются, края
обрезаются. Других типографских правок нет.

#### Scenario: повторные пробелы и пробел перед знаком
<!-- test: TextNormalizerTests.test_AT013_collapsesRepeatedSpaces_andRemovesSpaceBeforePunctuation -->
- **WHEN** в тексте идут подряд пробелы и стоит пробел перед точкой
- **THEN** пробелы схлопнуты, пробел перед знаком убран, изменение
  зафиксировано как `whitespace`

#### Scenario: текст уже чистый
<!-- test: TextNormalizerTests.test_alreadyClean_text_reportsNoWhitespaceChange -->
- **WHEN** текст не требует чистки
- **THEN** текст не меняется и изменение `whitespace` не фиксируется

---

### Requirement: Словарь замен применяется по целому слову без учёта регистра
<!-- id: TextNormalizer.applyVocabulary -->
<!-- entities: TextNormalizer, VocabularyEntry -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Normalizer/TextNormalizer.swift -->
<!-- test_macos: VoicePasteTests/TextNormalizerTests.swift:test_AT016_activeVocabularyRule_isAppliedCaseInsensitively -->

Включённое правило с непустой заменой SHALL заменять произнесённую форму
по границам слова, без учёта регистра. Выключенные правила и правила без
замены не срабатывают. Правила применяются до проверки правописания.

#### Scenario: включённое правило
<!-- test: TextNormalizerTests.test_AT016_activeVocabularyRule_isAppliedCaseInsensitively -->
- **WHEN** в тексте встречается произнесённая форма в любом регистре
- **THEN** она заменена, изменение зафиксировано с указанием произнесённой формы

#### Scenario: выключенное правило
<!-- test: TextNormalizerTests.test_AT016_disabledVocabularyRule_isNotApplied -->
- **WHEN** правило помечено выключенным
- **THEN** текст не меняется

#### Scenario: правило-защита без замены
<!-- test: TextNormalizerTests.test_vocabularyRule_withNoReplacement_neverFires -->
- **WHEN** у правила пустая или отсутствующая замена
- **THEN** правило ничего не заменяет

---

### Requirement: Автоисправление только при единственной подсказке
<!-- id: TextNormalizer.applySpellcheck -->
<!-- entities: TextNormalizer, SpellChecking, NormalizationChange -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Normalizer/TextNormalizer.swift -->
<!-- test_macos: VoicePasteTests/TextNormalizerTests.swift:test_AT014_wordWithMultipleGuesses_isNotReplaced -->

Слово SHALL исправляться, только когда системная проверка правописания даёт
ровно одну подсказку и она отличается от исходного слова. Несколько подсказок
или их отсутствие означают, что слово остаётся как есть.

#### Scenario: единственная подсказка
<!-- test: TextNormalizerTests.test_singleUnambiguousGuess_isAppliedAndRecorded -->
- **WHEN** для помеченного слова вернулась ровно одна подсказка
- **THEN** слово заменено, изменение зафиксировано с исходником и заменой

#### Scenario: несколько подсказок
<!-- test: TextNormalizerTests.test_AT014_wordWithMultipleGuesses_isNotReplaced -->
- **WHEN** подсказок больше одной
- **THEN** слово остаётся неизменным

#### Scenario: автоисправление выключено в настройках
<!-- test: TextNormalizerTests.test_autoCorrectDisabled_skipsSpellcheckStep_regardlessOfLanguage -->
- **WHEN** `autoCorrectSafeTypos == false`
- **THEN** шаг проверки правописания пропускается целиком

---

### Requirement: Ссылки, числа и аббревиатуры не трогаются
<!-- id: TextNormalizer.isSafeToAutocorrect -->
<!-- entities: TextNormalizer -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Normalizer/TextNormalizer.swift -->
<!-- test_macos: VoicePasteTests/TextNormalizerTests.swift:test_AT014_doesNotTouch_URL_evenIfSpellcheckerFlagsIt -->

Даже когда проверка правописания помечает слово, оно SHALL оставаться без
изменений, если это ссылка (`http`, `://`, `www.`), содержит цифры или целиком
написано прописными и длиннее одного символа.

#### Scenario: ссылка
<!-- test: TextNormalizerTests.test_AT014_doesNotTouch_URL_evenIfSpellcheckerFlagsIt -->
- **WHEN** помеченное слово — ссылка
- **THEN** оно остаётся неизменным

#### Scenario: аббревиатура прописными
<!-- test: TextNormalizerTests.test_AT014_doesNotTouch_allCapsAbbreviation -->
- **WHEN** помеченное слово целиком прописное
- **THEN** оно остаётся неизменным

#### Scenario: слово с цифрами
<!-- test: TextNormalizerTests.test_EC012_doesNotTouch_wordsContainingDigits -->
- **WHEN** помеченное слово содержит цифру
- **THEN** оно остаётся неизменным

---

### Requirement: Отсутствие словаря языка не блокирует нормализацию
<!-- id: NSSpellCheckerAdapter.misspelledRanges -->
<!-- entities: TextNormalizer, SpellChecking, TranscriptionLanguage -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Normalizer/TextNormalizer.swift -->
<!-- test_macos: VoicePasteTests/TextNormalizerTests.swift:test_AT015_EC011_missingLanguage_skipsSpellcheckStep_withoutBlocking -->

Если для выбранного языка в системе нет проверки правописания, шаг SHALL
пропускаться, а результат предыдущих шагов — возвращаться без ошибки.
В режиме `auto` код языка берётся из текущей локали.

#### Scenario: язык без установленного словаря
<!-- test: TextNormalizerTests.test_AT015_EC011_missingLanguage_skipsSpellcheckStep_withoutBlocking -->
- **WHEN** проверка правописания сообщает, что язык недоступен
- **THEN** текст возвращается после словаря и чистки, ошибки нет

---

### Requirement: Удаление концевой галлюцинации модели
<!-- id: TrailingHallucinationFilter.filtering -->
<!-- entities: TrailingHallucinationFilter, TranscriptionResult -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/TrailingHallucinationFilter.swift -->
<!-- test_macos: VoicePasteTests/TrailingHallucinationFilterTests.swift:test_removesModelTerminalFillerOnlyInTrailingSilence -->

Известный концевой наполнитель («продолжение следует», «to be continued»)
SHALL удаляться только при доказательстве из аудио: в конце записи есть
длинная тишина, а сегмент с наполнителем начинается позже последней речи.
Текста самого по себе недостаточно.

#### Scenario: наполнитель после тишины
<!-- test: TrailingHallucinationFilterTests.test_removesModelTerminalFillerOnlyInTrailingSilence -->
- **WHEN** хвост записи молчит и последний сегмент — известный наполнитель
- **THEN** наполнитель убран из текста

#### Scenario: фраза произнесена человеком
<!-- test: TrailingHallucinationFilterTests.test_preservesLegitimatelySpokenPhraseWithoutSilentTailEvidence -->
- **WHEN** длинной тишины в конце нет
- **THEN** текст не изменяется

#### Scenario: вся реплика состоит из этой фразы
<!-- test: TrailingHallucinationFilterTests.test_preservesPhraseWhenItIsTheWholeUtteranceEvenAfterNaturalPause -->
- **WHEN** после нормализации текст равен самой фразе
- **THEN** текст сохраняется целиком

#### Scenario: декодер склеил речь и наполнитель в один сегмент
<!-- test: TrailingHallucinationFilterTests.test_removesTerminalFillerWithoutSeparateSegment -->
- **WHEN** отдельного сегмента нет, но хвост молчит и текст кончается фразой
- **THEN** фраза убрана из конца текста

---

### Requirement: Выдуманные титры о субтитрах снимаются в любом месте
<!-- id: SubtitleCreditFilter -->
<!-- entities: SubtitleCreditFilter, TranscribedSegment, TranscriptionResult -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/SubtitleCreditFilter.swift, VoicePaste/Core/Transcription/WhisperKitTranscriber.swift -->
<!-- test_macos: VoicePasteTests/SubtitleCreditFilterTests.swift:test_creditLine_isRecognized_realSpeechIsNot -->

Строка-титр о субтитрах («Субтитры делал DimaTorzok», «Редактор субтитров
А. Семкин», «Субтитры создавал …», «Subtitles by …», «amara.org») SHALL
сниматься из сегментов и из итогового текста, где бы она ни стояла.

Это не речь, а выдумка Whisper: модель учили на видео, где в конце идут титры
переводчиков, и на музыке или тишине она их «вспоминает». 21.09.2026 такая
строка появилась в лекции, записанной на песню, — в середине, а не в конце,
поэтому правило про концевой наполнитель её не ловило.

Размен сделан сознательно: фраза, действительно продиктованная о том, кто
делал субтитры, тоже будет снята. Такая фраза в диктовке почти невероятна, а
выдумка на музыке — частая.

#### Scenario: титр посреди лекции
<!-- test: SubtitleCreditFilterTests.test_creditSegment_removedFromTheMiddle -->
- **WHEN** среди сегментов есть строка-титр
- **THEN** она снята, соседние сегменты на месте

#### Scenario: обычная речь со словом «субтитры»
<!-- test: SubtitleCreditFilterTests.test_creditLine_isRecognized_realSpeechIsNot -->
- **WHEN** сказано «включи субтитры к этому видео»
- **THEN** текст не изменяется

---

### Requirement: Длинная тишина обрезается до распознавания
<!-- id: TrailingHallucinationFilter.trimmingLongTrailingSilence -->
<!-- entities: TrailingHallucinationFilter, TranscriptionRequest -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/TrailingHallucinationFilter.swift, VoicePaste/Core/Transcription/WhisperKitTranscriber.swift -->
<!-- test_macos: VoicePasteTests/TrailingHallucinationFilterTests.swift:test_trimsOnlyLongTrailingSilenceBeforeWhisper -->

Перед выводом модели хвостовая тишина SHALL обрезаться с запасом в 0,25 с —
это устраняет причину концевых галлюцинаций, а не прячет одну известную фразу.
Короткая естественная пауза не обрезается.

#### Scenario: длинный молчащий хвост
<!-- test: TrailingHallucinationFilterTests.test_trimsOnlyLongTrailingSilenceBeforeWhisper -->
- **WHEN** после последней речи молчание длится 0,6 с и больше
- **THEN** сэмплы обрезаны до момента последней речи плюс 0,25 с

#### Scenario: естественная пауза
- **WHEN** после последней речи молчание короче 0,6 с
- **THEN** сэмплы не обрезаются

---

### Requirement: План декодирования по выбранному языку
<!-- id: WhisperKitTranscriber.decodingPlan -->
<!-- entities: WhisperDecodingPlan, TranscriptionLanguage -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/WhisperKitTranscriber.swift -->
<!-- test_macos: VoicePasteTests/WhisperDecodingPlanTests.swift:test_autoDetectsLanguageAndNeverTranslates -->

Выбор языка SHALL превращаться в чистое значение плана: в режиме `auto` язык
не задан и включено определение, в `ru`/`en` язык задан явно и определение
выключено. Задача декодера всегда «расшифровать».

#### Scenario: автоопределение
<!-- test: WhisperDecodingPlanTests.test_autoDetectsLanguageAndNeverTranslates -->
- **WHEN** выбран режим `auto`
- **THEN** код языка не задан, определение включено, перевод выключен

#### Scenario: явно выбранный русский
<!-- test: WhisperDecodingPlanTests.test_ruForcesLanguageAndNeverTranslates -->
- **WHEN** выбран `ru`
- **THEN** код языка `ru`, определение выключено, перевод выключен

---

### Requirement: Склейка соседних окон распознавания без повторов
<!-- id: TranscriptChunkMerger.merge -->
<!-- entities: TranscriptChunkMerger, TranscriptionResult -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/Transcribing.swift -->
<!-- test_macos: VoicePasteTests/WhisperDecodingPlanTests.swift:test_chunkMerger_removesExactTwoWordOverlap -->

При склейке текста соседних окон SHALL отбрасываться точное совпадение
нормализованного хвоста предыдущего фрагмента и начала следующего длиной
не менее двух токенов. Слова никогда не переписываются.

#### Scenario: перекрытие в два слова
<!-- test: WhisperDecodingPlanTests.test_chunkMerger_removesExactTwoWordOverlap -->
- **WHEN** два соседних фрагмента повторяют два одинаковых слова на стыке
- **THEN** повтор убран, текст склеен один раз

#### Scenario: случайное совпадение одного слова
<!-- test: WhisperDecodingPlanTests.test_chunkMerger_doesNotDropSingleCoincidentalWord -->
- **WHEN** совпадает единственное слово на стыке
- **THEN** оно сохраняется — это не перекрытие

---

### Requirement: Пустой результат распознавания считается ошибкой
<!-- id: WhisperInferenceWorker.transcribe -->
<!-- entities: TranscribingError, TranscriptionResult -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/WhisperKitTranscriber.swift -->

Пустой набор сэмплов и пустой текст после фильтрации SHALL приводить к
`TranscribingError.emptyAudio`, а не к сохранению пустой расшифровки.

#### Scenario: пустые сэмплы
- **WHEN** запрос пришёл с пустым массивом сэмплов
- **THEN** бросается `emptyAudio`, вывод модели не запускается

#### Scenario: после фильтрации ничего не осталось
- **WHEN** текст после удаления наполнителя состоит из пробелов
- **THEN** бросается `emptyAudio`

---

### Invariant: Перевод никогда не включается
<!-- entities: WhisperDecodingPlan -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/WhisperKitTranscriber.swift -->
<!-- verified_by_macos: VoicePasteTests/WhisperDecodingPlanTests.swift:test_isTranslateIsAlwaysFalseAcrossAllLanguages -->

Для любого режима языка план декодирования SHALL иметь `isTranslate == false`:
продукт расшифровывает речь, но не переводит её.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Пороги тишины измеряются окнами по 20 мс при RMS 0.004
<!-- entities: TrailingHallucinationFilter -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/TrailingHallucinationFilter.swift -->
<!-- verified_by_macos: VoicePasteTests/TrailingHallucinationFilterTests.swift:test_trimsOnlyLongTrailingSilenceBeforeWhisper -->

Момент последней речи SHALL искаться окнами длиной 0,02 с при пороге RMS
0.004 — том же, что отделяет тихую речь от шума микрофона при проверке
записи. Длинной считается тишина от 0,6 с; сегмент-наполнитель должен
начинаться не раньше чем через 0,2 с после последней речи; при обрезке
сохраняется запас 0,25 с.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Перекрытие при склейке — от 2 до 24 токенов
<!-- entities: TranscriptChunkMerger -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Transcription/Transcribing.swift -->
<!-- verified_by_macos: VoicePasteTests/WhisperDecodingPlanTests.swift:test_chunkMerger_doesNotDropSingleCoincidentalWord -->

Поиск перекрытия SHALL идти от минимума из 24, длины левого и длины правого
фрагмента вниз до двух токенов. Сравнение ведётся по токенам, приведённым
к нижнему регистру и очищенным от небуквенно-цифровых символов.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Порядок конвейера: чистка, затем словарь, затем правописание
<!-- entities: TextNormalizer, VocabularyEntry -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Normalizer/TextNormalizer.swift -->
<!-- verified_by_macos: VoicePasteTests/TextNormalizerTests.swift:test_pipelineOrder_vocabularyRunsBeforeSpellcheck -->

Порядок шагов SHALL быть неизменным: типографская чистка, затем словарные
замены, затем безопасные исправления. Иначе системная проверка правописания
успевала бы испортить слово, которое словарь обязан был подставить.

> Last verified: 2026-09-20 (commit 8f51051)

---

### Invariant: Нормализация никогда не выполняется на главном акторе
<!-- entities: TextNormalizer -->
<!-- platforms: macos -->
<!-- enforced_macos: VoicePaste/Core/Normalizer/TextNormalizer.swift -->

Весь конвейер SHALL запускаться через `normalizeInBackground` на отдельной
задаче с приоритетом `utility`: расшифровка многочасового видео не должна
задерживать прокрутку, анимацию HUD и обработку системных событий.

> Last verified: 2026-09-20 (commit 8f51051)

---

<!-- uncertainty: Реальный вывод WhisperKit проверяется только через MockTranscriber: пакет WhisperKit изолирован в WhisperKitTranscriber.swift под `#if canImport`, и в тестовом окружении его ветка не исполняется. -->
