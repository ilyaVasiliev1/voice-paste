# Аудит анимаций, переходов и отзывчивости интерфейса VoicePaste

Дата: 14.10.2026. Только чтение: код не менялся, приложение не запускалось, сборка не шла.
Метки: [код] найдено в файле; [источник] из исходников или документации с URL; [вывод] мой вывод,
не проверенный запуском; [не измерено] числа, которых у меня нет.

Границы: плашку диктовки (HUD) владелец принял — раздел про неё предлагает только то, что не меняет
её вид (выход, прогрев, фон). Любая правка HUD — по слову владельца (`docs/status.md`: «Плашку диктовки не трогать»).

---

## 1. Инвентарь

### 1.1 Что анимируется

Поиск по `VoicePaste/` на `withAnimation`, `.animation(`, `.transition`, `matchedGeometry`,
`NSAnimationContext`, `CABasicAnimation`, `.spring`, `symbolEffect`, `contentTransition`: **нет**
ни `.transition`, ни `matchedGeometryEffect`, ни `NSAnimationContext`, ни `CABasicAnimation`, ни пружин.
Всё движение — шесть вызовов `easeInOut`/`easeOut` с длительностью из `DesignTokens.Motion`
(0,12 / 0,18 / 0,24 с — `UI/DesignTokens.swift:26-30`). [код]

| # | Место | Что анимируется | Длительность, кривая | Прерывание | Reduce Motion |
|---|---|---|---|---|---|
| A1 | `Core/HUD/HUDContentView.swift:37` | ширина, высота, радиус капсулы; смена содержимого (вставка/удаление вида = неявное растворение); появление капсулы | `.easeInOut(0.18)`, `value: layout` | да, SwiftUI перенацеливает с текущего значения; у easeInOut нет скорости, поэтому при быстрой смене (запись → ошибка за < 180 мс) движение «встаёт» [вывод] | учтён: `nil` → мгновенная смена. HIG советует растворение вместо «ничего» |
| A2 | `HUDContentView.swift:253` | заливка и рамка зоны приёма файла | `.easeOut(0.12)`, `value: isImportTargeted` | да | учтён |
| A3 | `HUDContentView.swift:363` | подсветка кнопки при наведении | `withAnimation(.easeOut(0.12))` | да | **не учтён** (только цвет — допустимо) |
| A4 | `UI/Import/ImportQueueView.swift:75` | зона приёма файла в главном окне | `.easeOut(0.12)` | да | **не учтён** (только цвет) |
| A5 | `UI/Lecture/LectureView.swift:368` | `scrollTo("live")` на каждое изменение `volatileText` | `.easeOut(0.24)` | перезапускается на каждое обновление текста [вывод]; частота обновлений распознавателя [не измерено] | учтён |
| A6 | `HUDWindowController.swift:75` | **исчезновение плашки**: `panel.orderOut(nil)` | нет анимации — жёсткий обрыв | — | — |
| A7 | `HUDContentView.swift:329-335` | полоска автозакрытия (только `cancelledWithUndo`, `importFinished`) | не анимируется; ширина пересчитывается 30 раз в секунду | — | — |

Без движения вовсе [код]: переключение разделов (`MainWindowView.swift:69-87`, жёсткая смена вида),
шаги онбординга (`OnboardingView.swift:85-91`), появление секции «Сохранённые» и «В процессе»,
смена выбранного столбца графика (`DashboardView.swift:108`, прозрачность меняется скачком),
`HotkeyRecorderView` (ручная отрисовка `draw(_:)`, смена заливки мгновенная).

Смена между состояниями HUD с **одинаковым** `HUDLayout` вообще не анимируется: `.animation(value: layout)`
срабатывает только при изменении размера. Ширина 176 у `.processing`, `.copied`, `.cancelledWithUndo`
(`HUDContentView.swift:395-399`), поэтому «Расшифровка… → Скопировано» — жёсткая замена текста. [код + вывод]

### 1.2 Фоновые такты и фиксированные паузы

| Место | Что | Зачем / замечание |
|---|---|---|
| `HUDWindowController.swift:161-181` | цикл `Task.sleep(33 мс)`, пишет `stateHolder.dismissProgress` | шаг 30 Гц идёт для **всех** состояний с автозакрытием (1,5 с и 4 с), а полоска видна только у двух из них; каждый шаг перевычисляет тело `HUDContentView` с `compositingGroup`. Лишняя работа ≈ 45–120 вычислений на показ [код + вывод] |
| `App/AppState.swift:423` | тикер записи 200 мс; склейка до 100 мс (`:433`) | осознанно ограничен |
| `Core/Audio/AudioCaptureService.swift:325` | опрос уровня 100 мс | нужен только пока идёт запись |
| `AppState.swift:491` | 4 с до отмены паузы Esc | поведение, не задержка |
| `HUDContentView.swift:310` | `Task.sleep(16,7 мс)` перед `onImportFileDropped` | одна кадровая пауза, обоснована |
| `AppState+Lecture.swift:318` | тикер лекции 500 мс → `@Published lectureElapsedSeconds` | см. 2.4: перерисовывает все виды, что наблюдают `AppState` |
| `OnboardingView.swift:236, 247, 262` | 1,5 с до запасной кнопки; 1,0 с защита от двойного клика; опрос доверия 1,5 с | только на экране онбординга; опрос гасится при уходе со шага |
| `ReadinessCoordinator.swift:242, 263` | опрос активности 50 мс (≤ 1 с) + 100 мс | только на запросе разрешения |
| `HistoryListModel.swift:102` | 250 мс debounce поиска | см. раздел 3 |
| `UI/History/DetailEditor.swift:68` | 500 мс debounce записи правки | не влияет на показ текста |

Ничего вечного в фоне при закрытом окне и без записи я не нашёл. Опрос онбординга и ticker'ы
останавливаются. [код]

### 1.3 Где интерфейс ждёт

| Место | Что ждёт | Что видит человек |
|---|---|---|
| `UI/History/HistoryView.swift:31-37` + `HistoryListModel.swift:44-48` | первая загрузка истории стартует из `.task` главного окна | **неверное пустое состояние**: `model.items.isEmpty` истинно до первой выборки, и показывается «Нет записей» (`ContentUnavailableView`), хотя записей 2 400+. Флага «загружено» нет [код] |
| `DashboardView.swift:10-11, 83-98` | `stats = .empty` до первой выборки | «Здесь появится статистика» мигает до прихода данных [код] |
| `HistoryListModel.swift:14-21, 89-95` | выбор записи: `Task { await loadDetail }` без отмены; `detail` не очищается | на время выборки держится прежняя деталь; при быстрой навигации стрелками порядок завершения не гарантирован (поздний ответ на ранний выбор перетирает) [вывод] |
| `DetailEditor.swift:27-29` | `editedText` подставляется в `.task` **после** первого кадра | один кадр: метаданные новой записи и текст прежней [вывод] |
| `HistoryListModel.swift:59-68` | удаление: ждёт запись в БД, потом `loadFirstPage()` | строка остаётся в списке до круга БД; не оптимистично [код] |
| `UI/Lecture/LectureView.swift:55-60` (`selection` get) | выделение строки берётся из `appState.openedLecture`, который ставится после `await fetchDetail` (`AppState+Lecture.swift:257-262`) | подсветка нажатой строки запаздывает на выборку [код] |
| `AppState.swift:369-390` | HUD показывается **после** `audioCapture.start()`, а он на главном акторе создаёт новый `AVAudioEngine`, читает формат входа, ставит tap, `prepare()`, `start()` (`AudioCaptureService.swift:245-290`) | время «горячая клавиша → первый кадр плашки» включает запуск аудиодвижка [код]; величина [не измерено] |
| `App/App.swift:64` | `AppDatabase.makePool()` + миграции синхронно в `init` приложения | запуск, не открытие окна; растёт с историей [код] |
| `ModelLifecycleView.swift:29,36` | `ProgressView()` без значения (прогрев с диска, проверка) | вращение без прогресса и без времени |

Положительное [код]: импорт файла оптимистичен — `enqueue` возвращает `UUID` синхронно и добавляет
задачу в `jobs` до начала работы (`ImportManager.swift:108-113`), HUD сразу `.importing`
(`AppState.swift:659-664`); прогресс импорта склеивается `ImportProgressGate`; правка текста в редакторе
показывается сразу (запись с debounce).

---

## 2. Холодное открытие

### 2.1 Плашка диктовки (HUD)

1. Горячая клавиша → `AppState.handleHotkeyDown` → `beginRecording` (`AppState.swift:294-393`).
2. `captureFrontAppSnapshot()` — быстрый вызов `NSWorkspace` [код].
3. `modelManager.prewarm()` — не блокирует, запускает фоновую загрузку.
4. `audioCapture.start()` — **синхронно на MainActor**: `AVAudioEngine()`, `inputNode.outputFormat`,
   `AVAudioConverter`, `installTap`, `prepare()`, `start()`.
5. Только после успеха `refreshRecordingHUD(force: true)` → `hud.present(.recording)`.
6. `present`: `stateHolder.state = …`, `reposition()`, `orderFrontRegardless()` (`HUDWindowController.swift:68-111`).

Что уже сделано хорошо [код]: панель и `NSHostingView` создаются **заранее**, в `AppState.init`
(`private let hud = HUDWindowController()`, `AppState.swift:57`); размер хоста фиксирован 360×144, окно
не ресайзится, внутри морфится одна форма (`HUDWindowController.swift:210-214`); принудительного layout нет.

Чего нет [код + вывод]:
- панель ни разу не показывалась до первой диктовки: первый кадр сессии платит за создание
  поверхности в оконном сервере, `regularMaterial` и рендер SF Symbols;
- плашка не показывается оптимистично — она ждёт старта микрофона;
- появление = растворение 0,18 с `easeInOut` (капсула вставляется в `ZStack` из `EmptyView`); у
  `easeInOut` старт медленный — именно в момент, когда глаз смотрит.

### 2.2 Главное окно

Клик в меню (`.menu`-стиль, нативный `NSMenu`, быстрый) → `openMainOrOnboarding`
(`AppState.swift:616-624`): `NSApp.activate(ignoringOtherApps:)`, проверка готовности,
`requestedMainContentSection = …`, `WindowRouter.open("main")` → `openWindow(id: "main")`.

Дальше SwiftUI **лениво** строит сцену `Window("main")` (`App.swift:166`) при первом открытии:
`MainWindowView` → `NavigationSplitView` из трёх колонок + тулбар + `.searchable`. `HistoryListModel`
создаётся как `@StateObject` (`MainWindowView.swift:13`) — то есть вместе с окном; первая загрузка
стартует из `.task { await history.observeChanges() }` (`:60`), открывает наблюдение GRDB
и только потом тянет первую страницу (`HistoryStore.changes()` «тикает сразу при подписке»,
`HistoryListModel.swift:42-43`). Итог: первый кадр окна — разметка без данных и с пустым состоянием
«Нет записей» [код]; скелетонов и заглушек нет. Окно не создаётся заранее и данные заранее не
подгружаются. Жив ли `HistoryListModel` после закрытия окна — не проверено (комментарий в
`HistoryListModel.swift:39-41` предполагает, что нет) [вывод].

### 2.3 Настройки, онбординг

`Settings { SettingsView() }` — тоже лениво; на появлении `SettingsView.swift:53-62` обновляет
автозапуск (`SMAppService`) и словарь. Онбординг — фиксированное окно 480×360, шаги сменяются
без перехода. Оба открываются редко — по таблице частоты (`animate`) бюджет «иногда/редко»,
так что их холодный старт менее важен, чем окно истории и плашка.

### 2.4 Веер перерисовок

`AppState` пересылает `objectWillChange` от `readiness`, `modelManager`, `importManager`,
`lectureRecorder` (`AppState.swift:144-160`). Любое их изменение (тикер лекции 2 Гц,
`volatileText`, прогресс загрузки модели, состояния импорта) инвалидирует **каждый** вид с
`@EnvironmentObject appState`: `MainWindowView`, `HistoryListColumn`, `HistoryDetailColumn`,
`DetailEditor` (с `TextEditor`), `DashboardView`. Для открытого окна истории во время лекции
это перевычисление дерева два раза в секунду без видимой причины [код + вывод]; стоимость
[не измерено]. Прямо противоречит «ничего лишнего в фоне».

---

## 3. Список истории (2 400+ записей)

Факты [код]:
- `List(selection:)` + `ForEach(model.items)` — на macOS это `NSTableView`, ряды ленивые
  (`HistoryView.swift:38-64`). Не `LazyVStack`.
- Страница 100 записей (`TranscriptListItem.swift:67`), ключевая пагинация без `OFFSET`
  (`HistoryStore.swift:88-125`), в список не попадает `text`/`rawText` — только `preview`.
- Следующая страница подгружается, когда на экране появляется **последний** ряд
  (`HistoryListModel.swift:50-57`).
- FTS5: префиксы всех токенов, JOIN по `rowid`, тот же порядок (`HistoryStore.swift:64-86`).
- Поиск: debounce 250 мс + отмена прежней задачи (`HistoryListModel.swift:99-113`). Результаты
  не очищаются на время ожидания (хорошо).
- Живое обновление: `ValueObservation` по `COUNT(*)` и `MAX(updatedAt)` (`HistoryStore.swift:135-165`).

Что не так [код + вывод]:

1. **Тик обновления сбрасывает список на первую страницу.** `refreshCurrentQuery` →
   `loadFirstPage` → `items = page.items` (`HistoryListModel.swift:73-87`). Пока человек прокрутил
   до 1 500-й записи, любой тик (новая диктовка, правка) схлопывает список до 100 строк, и прокрутка
   возвращается к началу.
2. **Просмотр записи пишет в БД (вероятный дефект, не запускался).** `DetailEditor.swift:24-29`:
   `.task(id:)` присваивает `editedText`, `.onChange(of: editedText)` вызывает `scheduleSave` без
   проверки «текст изменился», через 500 мс — `historyStore.edit(... updatedAt: now)`. Это меняет
   `MAX(updatedAt)` → тик → пункт 1. Каждый выбор записи = UPDATE + перестроение FTS-триггером +
   перезагрузка списка. Тестов на SwiftUI-слой нет (`spec/history/spec.md:435`).
3. **Гонка подгрузки.** Нет флага «идёт загрузка»: два `onAppear` последнего ряда подряд запускают
   две `Task` с одним курсором и дважды дописывают те же 100 строк с теми же `id`.
4. **Подгрузка в конце, а не с запасом**: при быстрой прокрутке упираешься в конец списка и ждёшь круг БД.
5. **Формат даты в каждой строке** `Date.formatted(date:time:)` (`HistoryView.swift:205-208`) — на
   вид дорого при 100+ рядах на первом показе [вывод, не измерено].
6. Фильтр `appState.importManager.jobs.filter(\.state.isActive)` пересчитывается в теле на
   каждую инвалидацию (`HistoryView.swift:30`).
7. Поиск: debounce 250 мс — потолок ощущаемой скорости. FTS на 2,4 тыс. строк, по порядку величины,
   мс [вывод, не измерено]; 80–100 мс хватило бы.

Выбор записи не имеет искусственных задержек; задержка = круг `fetchDetail` (`SELECT *` одной строки)
[код]. Для одной строки по первичному ключу — доли миллисекунды [вывод].

---

## 4. Принципы для сравнения

### 4.1 Telegram Desktop — числа и приёмы

Где что лежит: библиотека интерфейса — отдельный репозиторий `desktop-app/lib_ui` (подмодуль
tdesktop), а не `tdesktop/ui/…`. Поэтому пути `ui/effects/animations.*` из задания лежат там.

| Что | Значение | Источник |
|---|---|---|
| Кривые | `linear`, `sineInOut`, `halfSine`, `easeOutBack`, `easeInCirc/OutCirc`, `easeInCubic/OutCubic`, `easeInQuint/OutQuint`, `bumpy(b)`; по умолчанию у `Animations::Simple::start` — **`anim::linear`** | [источник] https://github.com/desktop-app/lib_ui/blob/master/ui/effects/animation_value.cpp , `…/animations.h` (`anim::transition transition = anim::linear`) |
| `universalDuration` | **120 мс** (переключатели, чек-боксы, радио, ширина списка диалогов) | [источник] https://github.com/desktop-app/lib_ui/blob/master/ui/basic.style |
| `slideDuration` | **240 мс** (+ `slideShift` 100 px); `slideWrapDuration` **150**; `fadeWrapDuration` **200** | то же, `basic.style` |
| Меню: показ / скрытие | показ `showDuration` **200 мс**, скрытие `duration` **150 мс**; ширина идёт 0,6, высота 0,9, прозрачность 0,3 от отрезка показа, кривая `easeOutCirc`, начало из угла-источника | [источник] https://github.com/desktop-app/lib_ui/blob/master/ui/widgets/widgets.style (`defaultPopupMenu`, `defaultPanelAnimation`), `…/effects/panel_animation.cpp:327-341` |
| Ripple | показ **650 мс** `easeOutQuint`, скрытие **200 мс** линейно | `widgets.style` (`defaultRippleAnimation`), `…/effects/ripple_animation.cpp:86,99` |
| Тост | fade-in **200**, fade-out **1000**, slide **160 мс** | `widgets.style:1557-1559` |
| Полоса прокрутки | **150 мс** на реакцию, **1000 мс** до скрытия | `widgets.style:825-826` |
| Вкладки фильтров диалогов | **200 мс**; на свайпе **140 мс** | https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/dialogs/dialogs.style (`dialogsFilterSlideDuration`, `dialogsFilterSwipeSlideDuration`) |
| Индикатор «соединение» | **150 мс** | `window/window.style` (`connectingDuration`) |
| Дрожание (ошибка) | **300 мс**, сдвиг 4 px | `basic.style` (`shakeDuration`) |
| Пилюльные вкладки | **300 мс** | `widgets.style:1010` |

Приёмы, которые видно в коде:
- **Перенацеливание от текущего значения:** `Simple::change` берёт `from = _data->value`
  (`animations.h`, `startPrepared`) — прерывание без скачка, но **без** переноса скорости.
- **Глобальный выключатель:** `anim::SetDisabled(bool)`; при `Disabled()` время считается
  завершённым сразу (`BasicCallback`). Аналог — Reduce Motion, один флаг на всё.
- **Показ меню — по растровому кэшу:** `PopupMenu::prepareCache()` делает `GrabWidget(this)`,
  анимация идёт по готовой картинке, без layout на кадр (`popup_menu.cpp:764-775`).
  Для SwiftUI аналог — фиксированный размер хоста и анимация только `opacity`/`scale`/`offset` (HUD так уже сделан).
- **Скрытие короче показа** (150 против 200) и **показ асимметричен по осям** (ширина быстрее высоты).
- **Оптимистичный список:** отправка создаёт локальное сообщение до ответа сервера —
  `history->addNewLocalMessage({...})` и только затем запрос; ошибка → `api->sendMessageFail(...)`
  [источник] https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/api/api_sending.cpp (строки 284, 350).
- **Правила авторов:** «Animation durations should NOT go in `.style` files, this is a legacy
  approach» — длительность лежит рядом с компонентом (`kName = crl::time(N)`)
  [источник] https://github.com/telegramdesktop/tdesktop/blob/dev/AGENTS.md (строка 737).

Что переносимо в SwiftUI/AppKit: сами числа (120/150/200/240 мс); ease-out для появления;
скрытие быстрее показа; отмена с текущего значения; глобальный флаг (у нас `accessibilityReduceMotion`
и `Transaction.disablesAnimations`); поверхность неизменного размера; оптимистичное локальное
состояние с откатом.
Что нет: собственный кадровый таймер (`crl::time`, `Animations::Manager`) и ручная отрисовка
пикселей (Qt); растровый кэш меню как таковой; ripple (материал Telegram, чужой язык macOS);
дефолт `linear` (на macOS это «неестественно», см. ниже).

Приближения кривых к `timingCurve` — стандартные кривые easings.net, **не из исходников**
Telegram [вывод]: easeOutCirc ≈ (0, 0.55, 0.45, 1); easeOutQuint ≈ (0.22, 1, 0.36, 1);
easeOutCubic ≈ (0.33, 1, 0.68, 1); sineInOut ≈ (0.37, 0, 0.63, 1).

### 4.2 Apple

- WWDC23 «Animate with springs» [источник] https://developer.apple.com/videos/play/wwdc2023/10158/ :
  «springs are the only type of animation that maintains continuity both for static cases and cases
  with an initial velocity»; при перенацеливании пружина берёт скорость на момент прерывания;
  `bounce` выше ≈ 0,4 «may feel too exaggerated»; без `bounce` — «great general purpose spring»;
  не ждать времени успокоения (`settling duration`), а использовать воспринимаемую длительность.
- HIG «Motion» (https://developer.apple.com/design/human-interface-guidelines/motion): страница
  отдалась без текста; смысл (по навыку `animate`, `references/swiftui.md`, прочитанному
  скриптом 30.09.2026): движение несёт смысл, коротко, не заставляет ждать, при Reduce Motion
  заменяется на растворение. Дословной цитаты из первоисточника у меня нет.
- Навык `animate` (Emil Kowalski, `plugins/depo/skills/animate/SKILL.md`): частые действия — без
  анимации; вход — `ease-out`, перемещение на экране — `ease-in-out`; интерфейс < 300 мс;
  `ease-in` никогда; Reduce Motion — «меньше и мягче», не «ноль».
- Навык `apple-design`: ответ на нажатие, а не на отпускание; прерываемость; не блокировать ввод
  на время перехода; пружина критически демпфированная по умолчанию.

### 4.3 Что из этого говорит про VoicePaste

[вывод]
- Окно истории открывается часто и по горячей клавише/кнопке меню — по таблице частоты это
  «десятки раз в день»: либо едва заметное движение, либо вовсе без него; **ожидание данных
  страшнее отсутствия анимации**.
- У HUD частота выше (каждая диктовка), и его морф уже на пороге «чуть дольше, чем надо»
  для 0,18 с `easeInOut`; не трогать без слова владельца.
- Шкала `0,12/0,18/0,24` из `DesignTokens.Motion` совпадает с Telegram (120 — `universalDuration`,
  150–200 — меню, 240 — `slideDuration`): числа в порядке, не в порядке кривые и прерываемость.

---

## 5. Итог: что сделать

Усилие: S — до часа, одна правка и тест; M — полдня, несколько файлов; L — день и больше или нужна
перепроектировка.

| № | Место | Что не так | Что сделать | Ус. |
|---|---|---|---|---|
| 1 | `HistoryListModel.swift`, `HistoryView.swift:31-37` | пустое состояние «Нет записей» мигает до первой выборки | флаг `isLoaded` (или `items: [..]?`); до загрузки — пусто или 6–8 строк-заглушек без мерцания; «Нет записей» — только после загрузки | S |
| 2 | `DetailEditor.swift:24-29, 65-92` | просмотр записи пишет UPDATE и перезагружает список | не вызывать `scheduleSave`, пока `newText == transcript.text`; проставлять `editedText` через `init(_State)` + `.id(transcript.id)`; тест на «выбор не пишет» | S |
| 3 | `HistoryListModel.swift:73-87` | тик обновления схлопывает список до 100 строк | `refresh` запрашивает `max(100, items.count)` (с потолком) или заменяет только головной отрезок; не сбрасывать курсор | S–M |
| 4 | `HistoryListModel.swift:50-57` | гонка двойной подгрузки; подгрузка только на последнем ряду | флаг `isLoadingNextPage`; триггер на ряду `items.count - 20`; страницу в конце — не больше 100 | S |
| 5 | `HistoryListModel.swift:14-21, 89-95` | нет отмены выборки; `detail` не очищается | `detailTask?.cancel()` + проверка `selection == id` после `await`; мгновенно обновлять `detail` минимальной записью из `TranscriptListItem` (метаданные), текст дополнять | S |
| 6 | `HistoryListModel.swift:59-68` | удаление ждёт БД и перезагрузку | убрать строку из `items` сразу, выбрать соседа; при ошибке вернуть строку и показать отказ | S |
| 7 | `LectureView.swift:55-60`, `AppState+Lecture.swift:257` | подсветка выбора запаздывает на `await` | локальный `pendingSelection`, подсветка сразу, откат при ошибке | S |
| 8 | `DashboardView.swift:83-98` | «Здесь появится статистика» мигает до загрузки | `hasLoaded`; выбор столбца — `.animation(.easeOut(0.12), value: selectedDay?.day)` | S |
| 9 | `HUDWindowController.swift:73-78` | плашка исчезает обрывом | выход 0,12 с `ease-out` по `alphaValue` панели (`NSAnimationContext`, `orderOut` в completion; сбрасывать `alpha=1` при повторном `present`). **Только по слову владельца** — HUD принят | S–M |
| 10 | `HUDWindowController.swift:161-181` | тик 30 Гц для всех состояний | цикл только для `cancelledWithUndo`/`importFinished`; для остальных — один `sleep(delay)`; для полоски — один `withAnimation(.linear(duration: remaining))` на ширину | S |
| 11 | `HUDWindowController.init` / запуск | первая плашка сессии платит за создание поверхности | один раз после запуска показать панель с `alphaValue = 0` и сразу скрыть (или `hostingView.layoutSubtreeIfNeeded()` + `displayIfNeeded()`); измерить до/после | S |
| 12 | `AppState.swift:369-390` | HUD ждёт запуск `AVAudioEngine` | показать `.recording(0, 0)` до `start()`, на ошибке — морф в `.error` (плашка это уже умеет); сначала измерить `os_signpost` «клавиша → orderFront» | M |
| 13 | `AppState.swift:144-160`, `DetailEditor.swift:9` | веер перерисовок всех видов от лекции, импорта, модели | `DetailEditor` получает `historyStore`, а не `AppState`; `LectureView`/`DashboardView` наблюдают свои объекты; тикер лекции — только у вида, который его показывает | M |
| 14 | `HUDContentView.swift:37, 395-399` | смена состояний одной ширины — жёсткая; easeInOut без скорости | дополнить `.animation(…, value: state.kind)` (растворение содержимого 0,12 с); пружина `.snappy(duration: 0.2)` вместо `easeInOut(0.18)` — только по слову владельца | S |
| 15 | `HUDContentView.swift:37` | при Reduce Motion — «ничего» | вместо `nil` — `.easeOut(0.12)` на растворение; движение размера оставить убранным | S |
| 16 | `HistoryListModel.swift:102` | debounce 250 мс | 80–100 мс; сначала замерить запрос на копии базы (не на ноутбуке через туннель — локально это честно) | S |
| 17 | `HistoryView.swift:205-208, 30` | формат даты в каждой строке; `filter` в теле | кэш `FormatStyle`/форматтер статикой; `activeImports` вынести | S |
| 18 | окно истории | данные начинают грузиться после открытия окна | перенести `HistoryListModel` в `AppState`/прогреть первую страницу через 2–3 с после запуска; окно открывается с готовым списком | M |
| 19 | `OnboardingView.swift:85-91` | шаги сменяются без перехода | `.transition(.opacity)` + `.animation(.easeOut(0.18), value: step)`; Reduce Motion — то же без смещения | S |
| 20 | `LectureView.swift:361-371` | `scrollTo` с анимацией перезапускается на каждое обновление текста | при частых обновлениях — пружина `.smooth(duration: 0.25)` или без анимации, если прошлое обновление < 0,25 с назад | S |
| 21 | `ImportQueueView.swift:75`, `HUDContentView.swift:363` | Reduce Motion не учитывается (только цвет) | один помощник `Motion.animation(_ base:, reduce:)` в `DesignTokens`, использовать во всех шести местах | S |
| 22 | `DesignTokens.Motion` | есть длительности, нет кривых | добавить `Motion.enter` (`.timingCurve(0.22,1,0.36,1)`), `Motion.state` (`.snappy`), `Motion.exit`; не плодить числа в видах | S |

Сквозное: до любого пункта из M — измерение. Метки `os_signpost` на «горячая клавиша → `orderFront`»
и «`openWindow` → первая строка списка» (точки: `AppState.handleHotkeyDown`, `MainWindowView.onAppear`,
конец `loadFirstPage`) дают реальные миллисекунды; без них порядок M-пунктов — угадывание.

---

## 6. Десять приёмов, которые дадут больше всего ощущения скорости

Каждый привязан к найденному.

1. **Не показывать ложное «пусто».** Состояние «загрузка» отдельно от «нет данных» в истории и
   статистике (пп. 1, 8). Самый заметный дефект при открытии окна, правится за час.
2. **Просмотр не пишет.** Выбор записи сейчас порождает UPDATE и перезагрузку (п. 2) — и это
   прячется под «список прыгает». Исправление убирает целый класс подёргиваний.
3. **Список не теряет место.** Обновление сохраняет прокрутку и подгруженные страницы (пп. 3, 4).
4. **Прогрев при простое.** Через 2–3 с после запуска — первая страница истории в памяти и
   панель HUD один раз показана невидимо (пп. 11, 18). Окно и плашка открываются на готовом.
5. **Оптимистичное отражение действия.** Удаление, подсветка лекции, плашка записи (пп. 6, 7, 12) —
   сначала состояние, потом сверка с БД/микрофоном, откат с понятной ошибкой. Приём Telegram:
   локальное сообщение до ответа сервера.
6. **Отмена вместо ожидания.** Выборка детали, поиск, подгрузка — каждая отменяет предыдущую
   (п. 5); пока человек листает стрелками, устаревшие ответы не перетирают новое.
7. **Пружина вместо `easeInOut` там, где прерывают.** `.snappy(duration: 0.2)` для морфа HUD и
   `.smooth(duration: 0.25)` для прокрутки лекции переносят скорость при перенацеливании
   (пп. 14, 20; WWDC23). Для появления — ease-out, не easeInOut.
8. **Выход быстрее входа и не обрыв.** 120 мс на исчезновение плашки (п. 9), как меню Telegram
   (150 против 200); без переходов, которые заставляют ждать.
9. **Тишина в фоне.** Один тик вместо 30 Гц на HUD (п. 10), узкая подписка вместо веера
   `objectWillChange` (п. 13): ничего не считается, пока ничего не видно.
10. **Один помощник движения.** Шесть мест → одна функция, которая знает про Reduce Motion
    (растворение вместо «ничего») и берёт кривые из токенов (пп. 15, 21, 22). Без него новые
    анимации снова разойдутся — именно так возникли «пять длительностей на пять точек» из заголовка
    `DesignTokens.swift`.

---

## 7. Что не проверено

- Все времена запуска (клавиша → плашка, меню → окно, окно → первая строка): [не измерено], только
  чтение кода. Для них нужны `os_signpost` или Instruments (шаблон SwiftUI) и сборка через очередь Depo.
- Поведение `Window("main")` при закрытии (сохраняется ли `HistoryListModel`): по коду не решить.
- Пункт 2 из раздела 3 (запись при выборе) и пункт 3 (гонка подгрузки): выведены из кода; нужен тест
  с `HistoryListModel`/`DetailEditor` и счётчик вызовов `HistoryStoring.edit` / `fetchPage`.
- Текст HIG «Motion» первоисточника не получен (страница отдала только заголовок).
- Кривые easings.net приведены по памяти как приближения, не как данные Telegram.
