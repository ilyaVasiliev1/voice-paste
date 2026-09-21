import SwiftUI

/// Список раздела лекций: строка новой (или идущей) лекции и сохранённые.
///
/// Список — не украшение: лекция, которую записали и не могут открыть,
/// записана впустую.
struct LectureListColumn: View {
    @EnvironmentObject private var appState: AppState
    @State private var renaming: Lecture?

    enum Item: Hashable {
        case current
        case saved(UUID)
    }

    var body: some View {
        List(selection: selection) {
            Section {
                currentRow.tag(Item.current)
            }
            if !appState.savedLectures.isEmpty {
                Section("lecture.saved") {
                    ForEach(appState.savedLectures) { lecture in
                        SavedLectureRow(lecture: lecture)
                            .tag(Item.saved(lecture.id))
                            // Открыть сохранённую посреди записи нельзя —
                            // `openSavedLecture` откажет. Выключено, а не
                            // молча не срабатывает.
                            .disabled(appState.isLectureRecording)
                            .contextMenu {
                                Button {
                                    renaming = lecture
                                } label: {
                                    Label("lecture.rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task { await appState.deleteLecture(id: lecture.id) }
                                } label: {
                                    Label("lecture.delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
        }
        .task { await appState.refreshSavedLectures() }
        .lectureRenameAlert(target: $renaming)
    }

    private var selection: Binding<Item?> {
        Binding(
            get: { appState.openedLecture.map { .saved($0.lecture.id) } ?? .current },
            set: { item in
                switch item {
                case .current: appState.closeOpenedLecture()
                case .saved(let id): Task { await appState.openSavedLecture(id: id) }
                case nil: break
                }
            }
        )
    }

    private var currentRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: appState.isLectureRecording ? "record.circle.fill" : "plus.circle")
                .foregroundStyle(appState.isLectureRecording ? Color.red : Color.accentColor)
            Text(appState.isLectureRecording ? "lecture.recordingNow" : "lecture.new")
            Spacer(minLength: 0)
            if appState.isLectureRecording {
                Text(LectureClock.text(appState.lectureElapsedSeconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}

/// Сохранённая лекция в списке: название, дата, длительность и объём.
private struct SavedLectureRow: View {
    let lecture: Lecture

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(lecture.title)
                .lineLimit(2)
            Text(lecture.createdAtDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(LectureSummary.text(for: lecture))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}

/// Деталь раздела лекций: идущая запись, открытая лекция или приглашение
/// начать.
///
/// Оформление — только абзацы по паузам и метки времени. Ничего, чего не было
/// сказано, на экране не появляется: заголовки и выводы продукт не сочиняет.
struct LectureView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var recorder: LectureRecorder
    @ObservedObject var settings: AppSettings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renaming: Lecture?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .toolbar { toolbar }
        .lectureRenameAlert(target: $renaming)
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(.title2.weight(.semibold))
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.detailPanePadding)
        .padding(.vertical, DesignTokens.Spacing.lg)
    }

    private var title: String {
        if let opened = appState.openedLecture { return opened.lecture.title }
        return NSLocalizedString(appState.isLectureRecording ? "lecture.recordingNow" : "lecture.new", comment: "")
    }

    /// Строка состояния. Таймер записи стоит здесь крупно и первым: прежде он
    /// терялся в ряду приглушённых списков, и не было видно, что запись идёт.
    private var statusLine: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            if appState.isLectureRecording {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Circle()
                        .fill(.red)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(LectureClock.text(appState.lectureElapsedSeconds))
                        .font(.title3.monospacedDigit().weight(.medium))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("lecture.elapsed"))
            } else if let opened = appState.openedLecture {
                Text(opened.lecture.createdAtDate.formatted(date: .long, time: .shortened))
                Text(LectureSummary.text(for: opened.lecture))
            }

            // Честный показатель вместо выдуманного «уточняемого» текста:
            // последние секунды ещё считаются и на экране их пока нет.
            if recorder.isCatchingUp {
                ProgressView().controlSize(.small)
                Text("lecture.catchingUp")
            }

            Spacer(minLength: 0)

            if settings.lectureLanguage == .auto, !appState.isLectureRecording, appState.openedLecture == nil {
                Text("lecture.language.autoWarning")
                    .multilineTextAlignment(.trailing)
            } else if let language = recorder.detectedLanguage, appState.openedLecture == nil {
                Text(language.uppercased())
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: - Панель инструментов

    /// Действия раздела. Язык и движок — меню с подписью словами: прежде это
    /// были два списка без подписей, и выбор движка назывался «По языку».
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if let opened = appState.openedLecture {
                Button {
                    TextInserter.copyToClipboard(opened.plainText)
                } label: {
                    Label("lecture.copyAll", systemImage: "doc.on.doc")
                }
                .help("lecture.copyAll")
                Button {
                    renaming = opened.lecture
                } label: {
                    Label("lecture.rename", systemImage: "pencil")
                }
                .help("lecture.rename")
                .disabled(appState.isLectureRecording)
            } else if !appState.isLectureRecording, !recorder.paragraphs.isEmpty {
                Button {
                    TextInserter.copyToClipboard(recorder.paragraphs.map(\.text).joined(separator: "\n\n"))
                } label: {
                    Label("lecture.copyAll", systemImage: "doc.on.doc")
                }
                .help("lecture.copyAll")
            }

            // Язык выбирается до записи и действует на всю лекцию. Во время
            // записи заблокирован: смена языка посреди неё разошлась бы с уже
            // распознанным.
            Menu {
                Picker("lecture.language", selection: $settings.lectureLanguage) {
                    ForEach(LectureMenuText.languages, id: \.self) { language in
                        Text(LectureMenuText.name(of: language)).tag(language)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(String(
                    format: NSLocalizedString("lecture.language.label", comment: ""),
                    LectureMenuText.name(of: settings.lectureLanguage)
                ))
            }
            .fixedSize()
            .disabled(appState.isLectureRecording)
            .help("lecture.language")
            .accessibilityIdentifier("lecture-language")

            if LectureEngine.isSystemEngineAvailable {
                Menu {
                    Picker("lecture.engine", selection: $settings.lectureEngine) {
                        Text("lecture.engine.auto").tag(LectureEngine?.none)
                        Text("lecture.engine.system").tag(LectureEngine?.some(.system))
                        Text("lecture.engine.whisper").tag(LectureEngine?.some(.whisper))
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(String(
                        format: NSLocalizedString("lecture.engine.label", comment: ""),
                        LectureMenuText.name(of: settings.lectureEngine)
                    ))
                }
                .fixedSize()
                .disabled(appState.isLectureRecording)
                .help("lecture.engine")
                .accessibilityIdentifier("lecture-engine")
            }

            Button {
                if appState.isLectureRecording {
                    appState.toggleLectureRecording()
                } else if appState.openedLecture != nil {
                    // У открытой лекции запись её продолжает. Новая лекция —
                    // строкой «Новая лекция» в списке.
                    appState.continueOpenedLecture()
                } else {
                    appState.toggleLectureRecording()
                }
            } label: {
                // `waveform` — общий значок голосового ввода в продукте.
                Label(startStopTitle, systemImage: appState.isLectureRecording ? "stop.fill" : "waveform")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .accessibilityIdentifier("lecture-toggle")
        }
    }

    private var startStopTitle: LocalizedStringKey {
        if appState.isLectureRecording { return "lecture.stop" }
        return appState.openedLecture == nil ? "lecture.start" : "lecture.continue"
    }

    // MARK: - Содержимое

    private func isContinuing(_ opened: LectureDetail) -> Bool {
        appState.isLectureRecording && appState.continuingLectureID == opened.lecture.id
    }

    /// Идёт запись — показываем живую расшифровку, даже пустую. Прежде экран
    /// переключался на неё только после первого устоявшегося абзаца, а
    /// системный распознаватель закрепляет текст редко: весь живой текст
    /// приходил уточняемым и на экран не попадал вовсе.
    private var showsLiveTranscript: Bool {
        appState.isLectureRecording || !recorder.paragraphs.isEmpty || !recorder.volatileText.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if let opened = appState.openedLecture {
            let saved = opened.paragraphs.map {
                LectureParagraph(
                    text: $0.text,
                    startSeconds: Double($0.startMilliseconds) / 1_000,
                    endSeconds: Double($0.endMilliseconds) / 1_000
                )
            }
            if isContinuing(opened) {
                // Дописываемое встаёт за сохранённым, со временем от конца
                // лекции — так же, как оно будет сохранено.
                let offset = Double(opened.lecture.durationMilliseconds) / 1_000
                let added = recorder.paragraphs.map {
                    LectureParagraph(
                        text: $0.text,
                        startSeconds: offset + $0.startSeconds,
                        endSeconds: offset + $0.endSeconds
                    )
                }
                paragraphList(saved + added, followsTail: true)
            } else {
                paragraphList(saved, followsTail: false)
            }
        } else if showsLiveTranscript {
            paragraphList(recorder.paragraphs, followsTail: true)
        } else {
            ContentUnavailableView {
                Label("lecture.detail.idle.title", systemImage: "text.book.closed")
            } description: {
                Text("lecture.detail.idle.description")
            } actions: {
                Button("lecture.start") { appState.toggleLectureRecording() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func paragraphList(
        _ paragraphs: [LectureParagraph],
        followsTail: Bool
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        LectureParagraphRow(paragraph: paragraph)
                        .id(index)
                    }
                    // Живой текст — продолжение расшифровки, а не сноска: то,
                    // что говорится прямо сейчас. Приглушён, потому что ещё
                    // уточнится, но стоит там, куда смотрит глаз.
                    if followsTail, !recorder.volatileText.isEmpty {
                        LiveTextRow(text: recorder.volatileText)
                            .id("live")
                    }
                    if followsTail, appState.isLectureRecording,
                        paragraphs.isEmpty, recorder.volatileText.isEmpty {
                        Text("lecture.listening")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .id("live")
                    }
                }
                .padding(DesignTokens.detailPanePadding)
                .textSelection(.enabled)
            }
            .onChange(of: recorder.volatileText) { _, _ in
                // Лекция идёт — экран держится за тем, что говорится сейчас,
                // иначе за говорящим придётся гоняться руками. У открытой на
                // чтение лекции прокрутка остаётся за человеком.
                guard followsTail, appState.isLectureRecording else { return }
                // Плавно, а не прыжком: текст подъезжает, пока его читают.
                // При включённом «уменьшить движение» — без анимации.
                withAnimation(reduceMotion ? nil : .easeOut(duration: DesignTokens.Motion.deliberate)) {
                    proxy.scrollTo("live", anchor: .bottom)
                }
            }
        }
    }
}

/// Время записи на часах: минуты и секунды.
enum LectureClock {
    static func text(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Длительность и объём лекции. Минутами не обойтись: лекция на сорок
/// секунд показывалась как «0 мин», и строка выглядела пустой.
enum LectureSummary {
    static func text(for lecture: Lecture) -> String {
        let seconds = lecture.durationMilliseconds / 1_000
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return String(
            format: NSLocalizedString("lecture.row.summary", comment: ""),
            clock,
            lecture.wordCount
        )
    }
}

/// Подписи меню языка и движка.
private enum LectureMenuText {
    static let languages: [TranscriptionLanguage] = [.zh, .ru, .en, .auto]

    static func name(of language: TranscriptionLanguage) -> String {
        NSLocalizedString("settings.language.\(language.rawValue)", comment: "")
    }

    static func name(of engine: LectureEngine?) -> String {
        switch engine {
        case nil: NSLocalizedString("lecture.engine.auto", comment: "")
        case .system: NSLocalizedString("lecture.engine.system", comment: "")
        case .whisper: NSLocalizedString("lecture.engine.whisper", comment: "")
        }
    }
}

private extension Lecture {
    var createdAtDate: Date { Date(timeIntervalSince1970: Double(createdAt) / 1_000) }
}

/// Переименование лекции — одно на список и деталь.
private struct LectureRenameAlert: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Binding var target: Lecture?
    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .alert("lecture.rename", isPresented: isPresented) {
                TextField("lecture.rename", text: $title)
                Button("lecture.rename.confirm") {
                    guard let id = target?.id else { return }
                    Task { await appState.renameLecture(id: id, title: title) }
                }
                Button("lecture.rename.cancel", role: .cancel) {}
            }
            .onChange(of: target) { _, lecture in
                if let lecture { title = lecture.title }
            }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }
}

private extension View {
    func lectureRenameAlert(target: Binding<Lecture?>) -> some View {
        modifier(LectureRenameAlert(target: target))
    }
}

/// Один абзац: время слева, текст справа. Время — не украшение: по нему
/// возвращаются к месту в записи.
private struct LectureParagraphRow: View {
    let paragraph: LectureParagraph

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Text(Self.timestamp(paragraph.startSeconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
                .accessibilityLabel(Text("lecture.paragraph.startsAt"))

            Text(paragraph.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button {
                        TextInserter.copyToClipboard(paragraph.text)
                    } label: {
                        Label("lecture.copyParagraph", systemImage: "doc.on.doc")
                    }
                }
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Текст, который говорится прямо сейчас. Приглушён: распознаватель его ещё
/// уточнит. Время слева пустое — абзаца у него пока нет.
private struct LiveTextRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Circle()
                .fill(.red.opacity(0.8))
                .frame(width: 6, height: 6)
                .padding(.top, DesignTokens.Spacing.sm)
                .frame(width: 48, alignment: .leading)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("lecture-volatile")
        }
    }
}
