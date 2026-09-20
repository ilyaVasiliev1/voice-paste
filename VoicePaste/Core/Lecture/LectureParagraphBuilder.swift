import Foundation

/// Абзац расшифровки: несколько сегментов подряд, между которыми говорящий не
/// делал заметной паузы.
nonisolated public struct LectureParagraph: Sendable, Equatable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Режет расшифровку на абзацы по паузам говорящего.
///
/// Это всё оформление, которое продукт себе позволяет. Заголовков, тезисов и
/// выводов он не сочиняет: языковая модель здесь не участвует вовсе, и ничего
/// сверх сказанного на экране не появится. Единственный сигнал — настоящая
/// пауза между сегментами, и она берётся из времени, а не из смысла.
///
/// Тип чистый: ни звука, ни модели, ни хранилища. Поэтому единственное правило
/// оформления в учебном режиме доказывается целиком, при том что экран вокруг
/// него тестами не покрыт.
nonisolated public enum LectureParagraphBuilder {

    /// Допустимые пороги паузы. Меньше секунды режет речь на середине мысли,
    /// больше десяти — склеивает всю лекцию в одно полотно.
    public static let pauseRange: ClosedRange<Double> = 1...10
    public static let defaultPauseSeconds: Double = 2

    /// Приводит порог к допустимым пределам.
    public static func clampPause(_ seconds: Double) -> Double {
        min(max(seconds, pauseRange.lowerBound), pauseRange.upperBound)
    }

    /// Собирает абзацы. Сегменты ожидаются в порядке речи.
    public static func build(
        from segments: [TranscribedSegment],
        pauseSeconds: Double
    ) -> [LectureParagraph] {
        let threshold = clampPause(pauseSeconds)
        var paragraphs: [LectureParagraph] = []
        var currentTexts: [String] = []
        var currentStart: Double = 0
        var currentEnd: Double = 0

        func flush() {
            guard !currentTexts.isEmpty else { return }
            paragraphs.append(LectureParagraph(
                text: currentTexts.joined(separator: " "),
                startSeconds: currentStart,
                endSeconds: currentEnd
            ))
            currentTexts = []
        }

        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Пустой сегмент — это тишина, которую модель не стала озвучивать.
            // Он не открывает абзаца и не удлиняет текущий, но и не считается
            // паузой сам по себе: паузу считает время следующего сегмента.
            guard !text.isEmpty else { continue }

            if currentTexts.isEmpty {
                currentStart = segment.startSeconds
            } else if segment.startSeconds - currentEnd >= threshold {
                flush()
                currentStart = segment.startSeconds
            }
            currentTexts.append(text)
            currentEnd = segment.endSeconds
        }
        flush()
        return paragraphs
    }
}
