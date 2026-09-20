import SwiftUI

/// Экран учебного режима: запись лекции с расшифровкой, которая пополняется
/// по ходу.
///
/// Оформление — только абзацы по паузам и метки времени. Ничего, чего не было
/// сказано, на экране не появляется: заголовки и выводы продукт не сочиняет.
struct LectureView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var recorder: LectureRecorder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRenaming = false
    @State private var renameTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await appState.refreshSavedLectures() }
        .alert("lecture.rename", isPresented: $isRenaming) {
            TextField("lecture.rename", text: $renameTitle)
            Button("lecture.rename.confirm") {
                guard let id = appState.openedLecture?.lecture.id else { return }
                Task { await appState.renameLecture(id: id, title: renameTitle) }
            }
            Button("lecture.rename.cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appState.openedLecture?.lecture.title ?? NSLocalizedString("lecture.section", comment: ""))
                .font(.title2.weight(.semibold))
            controls
        }
        .padding(.horizontal, DesignTokens.detailPanePadding)
        .padding(.vertical, 16)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                appState.toggleLectureRecording()
            } label: {
                // `waveform` — общий значок голосового ввода в продукте.
                // Своя пара символов на этом экране означала бы, что одно и
                // то же действие называется по-разному в разных местах.
                Label(
                    appState.isLectureRecording ? "lecture.stop" : "lecture.start",
                    systemImage: appState.isLectureRecording ? "stop.fill" : "waveform"
                )
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .accessibilityIdentifier("lecture-toggle")

            if appState.isLectureRecording {
                Text(Self.clock(appState.lectureElapsedSeconds))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("lecture.elapsed"))
            }

            // Честный показатель вместо выдуманного «уточняемого» текста:
            // последние секунды ещё считаются и на экране их пока нет.
            if recorder.isCatchingUp {
                ProgressView()
                    .controlSize(.small)
                Text("lecture.catchingUp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let opened = appState.openedLecture {
                Button {
                    appState.closeOpenedLecture()
                } label: {
                    Label("lecture.backToList", systemImage: "chevron.backward")
                }
                Button {
                    TextInserter.copyToClipboard(opened.plainText)
                } label: {
                    Label("lecture.copyAll", systemImage: "doc.on.doc")
                }
                Button {
                    renameTitle = opened.lecture.title
                    isRenaming = true
                } label: {
                    Label("lecture.rename", systemImage: "pencil")
                }
            }

            Spacer()

            if let language = recorder.detectedLanguage {
                Text(language.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Что показывать: открытую сохранённую лекцию, текущую запись или
    /// список сохранённых. Список — не украшение: лекция, которую записали и
    /// не могут открыть, записана впустую.
    @ViewBuilder
    private var content: some View {
        if let opened = appState.openedLecture {
            paragraphList(opened.paragraphs.map {
                LectureParagraph(
                    text: $0.text,
                    startSeconds: Double($0.startMilliseconds) / 1_000,
                    endSeconds: Double($0.endMilliseconds) / 1_000
                )
            }, followsTail: false)
        } else if !recorder.paragraphs.isEmpty {
            paragraphList(recorder.paragraphs, followsTail: true)
        } else if appState.savedLectures.isEmpty {
            ContentUnavailableView(
                "lecture.empty.title",
                systemImage: "text.book.closed",
                description: Text("lecture.empty.description")
            )
            .frame(maxHeight: .infinity)
        } else {
            savedList
        }
    }

    private var savedList: some View {
        List(appState.savedLectures) { lecture in
            Button {
                Task { await appState.openSavedLecture(id: lecture.id) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lecture.title).font(.headline)
                    Text(Self.summary(for: lecture))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    Task { await appState.deleteLecture(id: lecture.id) }
                } label: {
                    Label("lecture.delete", systemImage: "trash")
                }
            }
        }
    }

    private static func summary(for lecture: Lecture) -> String {
        let minutes = lecture.durationMilliseconds / 60_000
        return String(
            format: NSLocalizedString("lecture.row.summary", comment: ""),
            minutes,
            lecture.wordCount
        )
    }

    private func paragraphList(
        _ paragraphs: [LectureParagraph],
        followsTail: Bool
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        LectureParagraphRow(paragraph: paragraph)
                        .id(index)
                    }
                }
                .padding(DesignTokens.detailPanePadding)
                .textSelection(.enabled)
            }
            .onChange(of: paragraphs.count) { _, count in
                // Лекция идёт — экран держится конца, иначе за говорящим
                // придётся гоняться руками. У открытой на чтение лекции
                // прокрутка остаётся за человеком.
                guard followsTail, appState.isLectureRecording, count > 0 else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: DesignTokens.Motion.deliberate)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Один абзац: время слева, текст справа. Время — не украшение: по нему
/// возвращаются к месту в записи.
private struct LectureParagraphRow: View {
    let paragraph: LectureParagraph

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
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
