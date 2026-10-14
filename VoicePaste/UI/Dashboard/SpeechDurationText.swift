/// Время речи в статистике: одна форма длительности на все экраны.
enum SpeechDurationText {
    static func text(milliseconds: Int) -> String {
        DisplayFormat.duration(milliseconds: milliseconds)
    }
}
