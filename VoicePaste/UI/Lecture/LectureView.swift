import SwiftUI
import Translation

/// Экран учебного режима: запись лекции с расшифровкой, которая пополняется
/// по ходу.
///
/// Оформление — только абзацы по паузам и метки времени. Ничего, чего не было
/// сказано, на экране не появляется: заголовки и выводы продукт не сочиняет.
struct LectureView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var recorder: LectureRecorder

    @State private var selectedText = ""
    @State private var isTranslationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if recorder.paragraphs.isEmpty {
                ContentUnavailableView(
                    "lecture.empty.title",
                    systemImage: "text.book.closed",
                    description: Text("lecture.empty.description")
                )
                .frame(maxHeight: .infinity)
            } else {
                transcript
            }
        }
        // Системный переводчик macOS 15: работает на устройстве и текст
        // наружу не отправляет — иначе обещание офлайна было бы нарушено.
        .translationPresentation(isPresented: $isTranslationPresented, text: selectedText)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                appState.toggleLectureRecording()
            } label: {
                Label(
                    appState.isLectureRecording ? "lecture.stop" : "lecture.start",
                    systemImage: appState.isLectureRecording ? "stop.circle.fill" : "record.circle"
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

            Spacer()

            if let language = recorder.detectedLanguage {
                Text(language.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(recorder.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        LectureParagraphRow(
                            paragraph: paragraph,
                            onTranslate: {
                                selectedText = paragraph.text
                                isTranslationPresented = true
                            }
                        )
                        .id(index)
                    }
                }
                .padding(16)
                .textSelection(.enabled)
            }
            .onChange(of: recorder.paragraphs.count) { _, count in
                // Лекция идёт — экран держится конца, иначе за говорящим
                // придётся гоняться руками.
                guard appState.isLectureRecording, count > 0 else { return }
                withAnimation(.easeOut(duration: 0.2)) {
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
    let onTranslate: () -> Void

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
                        onTranslate()
                    } label: {
                        Label("lecture.translate", systemImage: "character.book.closed")
                    }
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
