// swift-tools-version: 6.0
import PackageDescription

// Без зависимостей намеренно: конвейер не знает про AppKit, GRDB, сеть и файловую систему моделей.
let package = Package(
    name: "SpeechPipeline",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SpeechPipeline", targets: ["SpeechPipeline"])],
    targets: [.target(name: "SpeechPipeline")]
)
