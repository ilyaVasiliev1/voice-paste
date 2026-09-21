/// Время речи в статистике.
///
/// Меньше минуты показывается секундами: деление нацело превращало несколько
/// коротких диктовок в «0 мин», и ненулевая речь выглядела отсутствующей.
enum SpeechDurationText {
    static func text(milliseconds: Int) -> String {
        let seconds = milliseconds / 1_000
        if seconds < 60 { return "\(seconds) с" }
        if seconds < 3_600 { return "\(seconds / 60) мин" }
        return "\(seconds / 3_600) ч \((seconds % 3_600) / 60) мин"
    }
}
