import AppKit
import GRDB
import SwiftUI
import XCTest

@testable import VoicePaste

/// Снимки экранов для визуальной проверки — как скриншоты страницы при
/// веб-разработке. Экран размещается в настоящем окне приложения и снимается
/// его собственное содержимое: системные элементы отрисовываются как в жизни,
/// а разрешение на запись экрана не нужно — снимается своё окно, не чужой
/// экран. В обычный прогон не входит.
@MainActor
final class ScreenSnapshots: XCTestCase {

    /// Каталог задаёт `scripts/snapshots.sh`: xcodebuild передаёт тесту
    /// переменные с приставкой `TEST_RUNNER_`, срезая её.
    private let outDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("VoicePasteSnapshots").path)

    /// Приложение на настоящей базе во временном каталоге, с образцами
    /// истории и лекций: пустой экран дизайна не показывает.
    private func makeAppState() async throws -> AppState {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Snapshots-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON") }
        let pool = try DatabasePool(path: root.appendingPathComponent("db.sqlite").path, configuration: configuration)
        try Migrations.migrator.migrate(pool)
        let history = HistoryStore(dbPool: pool)
        let lectures = LectureStore(dbPool: pool)
        try await seed(history: history, lectures: lectures)

        let modelManager = ModelManager(modelDirectory: root, makeTranscriber: { _, _, _ in MockTranscriber() })
        let imports = ImportManager(
            modelManager: modelManager, historyStore: history,
            queueStore: InMemoryImportQueueStore(), settings: settings
        )
        let app = AppState(
            settings: settings, modelManager: modelManager, historyStore: history,
            importManager: imports, lectureStore: lectures, enableGlobalHotkey: false
        )
        await app.refreshSavedLectures()
        return app
    }

    private func seed(history: HistoryStore, lectures: LectureStore) async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let samples = [
            "Слушай, давай перенесём созвон на завтра, сегодня не успеваю закончить отчёт.",
            "Проверь, пожалуйста, почему сборка падает на шаге подписи — кажется, дело в сертификате.",
            "Купить молоко, хлеб и батарейки для мыши.",
        ]
        for (index, text) in samples.enumerated() {
            let stamp = now - Int64(index) * 3_600_000
            try await history.save(Transcript(
                id: UUID(), createdAt: stamp, updatedAt: stamp, source: .dictation, sourceFileName: nil,
                durationMilliseconds: 6_000 + index * 2_000, language: "ru", rawText: text, text: text,
                preview: Transcript.makePreview(from: text), status: .completed, insertionOutcome: .inserted
            ))
        }
        let lectureID = UUID()
        let texts = ["今天我们来讲一下并发模型中的执行者模式。", "让我们回到银行账户的例子，两个线程同时访问同一个余额。"]
        try await lectures.save(LectureDetail(
            lecture: Lecture(
                id: lectureID, createdAt: now - 86_400_000, updatedAt: now - 86_400_000,
                title: "Параллельное программирование", durationMilliseconds: 2_760_000, language: "zh", wordCount: 412
            ),
            paragraphs: texts.enumerated().map { index, text in
                StoredLectureParagraph(
                    id: UUID(), lectureID: lectureID, orderIndex: index,
                    startMilliseconds: index * 107_000, endMilliseconds: index * 107_000 + 5_000, text: text
                )
            }
        ))
    }

    /// Главное окно на нужном разделе — то, что видит владелец.
    private func mainWindow(_ app: AppState, section: MainContentSection) -> some View {
        app.requestedMainContentSection = section
        return MainWindowView()
            .environmentObject(app)
            .environmentObject(app.importManager)
    }

    /// Показывает вид в настоящем окне и снимает то, что окно нарисовало.
    ///
    /// Окно — с рамкой и заголовком, как главное окно приложения: панель
    /// инструментов SwiftUI живёт в заголовке и без него не рисуется. Стоит на
    /// экране, но позади остальных окон: окно за пределами экрана система не
    /// снимает («could not create image from window»), а перекрытое — снимает,
    /// потому что берёт его собственный буфер, а не пиксели экрана.
    private func snapshot<V: View>(_ view: V, size: CGSize, dark: Bool, name: String) async throws {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.title = "VoicePaste"
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.center()
        window.order(.below, relativeTo: 0)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        window.displayIfNeeded()

        // Снимок делает система по номеру окна: только это окно, не экран.
        // Всё остальное проверено и не годится — `cacheDisplay` теряет текст
        // SwiftUI, `ImageRenderer` не рисует системных элементов (выпадающие
        // списки выходят заглушками) и прокрутки, отрисовка дерева слоёв не
        // видит стеклянной боковой панели macOS 26, которая берёт фон из-под окна.
        //
        // Права на снимок у тестового процесса нет, и выдавать его ради
        // тестов незачем: номер окна пишется в файл, а снимает внешний
        // наблюдатель `scripts/snapshots.sh`, запущенный из терминала.
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let png = outDir.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: png)
        try String(window.windowNumber).write(
            to: outDir.appendingPathComponent("\(name).wid"), atomically: true, encoding: .utf8
        )
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: png.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "наблюдатель не снял окно \(name)")
    }

    private func skipUnlessRequested() throws {
        let marker = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePaste/run-benchmark")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: marker.path), "снимки")
    }

    private let windowSize = CGSize(width: MainWindowLayout.defaultWindowWidth, height: MainWindowLayout.defaultWindowHeight)

    func test_mainWindow_sections() async throws {
        try skipUnlessRequested()
        for section: MainContentSection in [.history, .lecture, .importQueue, .dashboard] {
            for dark in [true, false] {
                let app = try await makeAppState()
                try await snapshot(
                    mainWindow(app, section: section), size: windowSize, dark: dark,
                    name: "main-\(section)-\(dark ? "dark" : "light")"
                )
            }
        }
    }

    func test_selectedRecords() async throws {
        try skipUnlessRequested()
        for dark in [true, false] {
            let history = try await makeAppState()
            history.requestedHistorySelection = try await history.historyStore.fetchPage(after: nil).items.first?.id
            try await snapshot(
                mainWindow(history, section: .history), size: windowSize, dark: dark,
                name: "history-selected-\(dark ? "dark" : "light")"
            )

            let lecture = try await makeAppState()
            let lectureID = try XCTUnwrap(lecture.savedLectures.first?.id)
            await lecture.openSavedLecture(id: lectureID)
            try await snapshot(
                mainWindow(lecture, section: .lecture), size: windowSize, dark: dark,
                name: "lecture-opened-\(dark ? "dark" : "light")"
            )
        }
    }

    func test_lectureScreen_liveRecording() async throws {
        try skipUnlessRequested()
        for dark in [true, false] {
            let app = try await makeAppState()
            let engine = SnapshotEngine()
            try await app.lectureRecorder.beginStreaming(engine: engine, language: .zh, pauseSeconds: 2)
            // Настоящий путь начала требует микрофона; экрану нужен только флаг.
            app.isLectureRecording = true
            app.lectureElapsedSeconds = 754
            engine.emit(.init(text: "今天我们来讲一下并发模型中的执行者模式。", isFinal: true, startSeconds: 0, endSeconds: 4))
            engine.emit(.init(text: "让我们回到银行账户的例子，两个线程同时访问同一个余额。", isFinal: true, startSeconds: 107, endSeconds: 112))
            engine.emit(.init(text: "这里重要的是执行者不会阻塞", isFinal: false, startSeconds: 113, endSeconds: 115))
            try await Task.sleep(for: .milliseconds(200))
            try await snapshot(
                mainWindow(app, section: .lecture), size: windowSize, dark: dark,
                name: "lecture-live-\(dark ? "dark" : "light")"
            )
        }
    }
}

@MainActor
private final class SnapshotEngine: LiveTranscribing {
    private let stream: AsyncStream<LiveTranscriptUpdate>
    private let continuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    var updates: AsyncStream<LiveTranscriptUpdate> { stream }
    init() { (stream, continuation) = AsyncStream<LiveTranscriptUpdate>.makeStream() }
    func emit(_ update: LiveTranscriptUpdate) { continuation.yield(update) }
    func prepare(language: TranscriptionLanguage) async throws {}
    func append(samples: [Float]) {}
    func settle() async {}
    func finish() async { continuation.finish() }
    func cancel() { continuation.finish() }
}
