import Foundation
import Testing

/// Граница пакета конвейера: он не знает про AppKit, GRDB, сеть и файловую
/// систему моделей. Нарушение — красный тест, а не правило в документе.
@Suite("Граница пакета SpeechPipeline")
struct SpeechPipelineBoundaryTests {

    private static let allowedImports: Set<String> = ["Foundation"]

    static func imports(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line -> String? in
            let words = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "@_exported ", with: "")
                .replacingOccurrences(of: "@testable ", with: "")
                .split(separator: " ")
            guard words.first == "import" else { return nil }
            // `import struct GRDB.Row` называет модуль после вида объявления.
            let module = words.count > 2 ? words[2] : words[1]
            return String(module.split(separator: ".").first ?? module)
        }
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Packages/SpeechPipeline", isDirectory: true)
    }

    @Test("разбор находит запрещённые модули, в том числе в расширенной записи")
    func parserFindsForbiddenImports() {
        let source = """
        import Foundation
        import AppKit
        @_exported import GRDB
        import struct WhisperKit.TranscriptionResult
        // import SwiftUI
        """
        #expect(Self.imports(in: source) == ["Foundation", "AppKit", "GRDB", "WhisperKit"])
    }

    @Test("исходники пакета импортируют только разрешённое")
    func packageSourcesImportOnlyFoundation() throws {
        let sources = Self.packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        var violations: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            checked += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for module in Self.imports(in: source) where !Self.allowedImports.contains(module) {
                violations.append("\(url.lastPathComponent): \(module)")
            }
        }
        #expect(checked > 0)
        #expect(violations.isEmpty, "запрещённые импорты: \(violations)")
    }

    @Test("манифест пакета не объявляет зависимостей")
    func manifestDeclaresNoDependencies() throws {
        let manifest = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8
        )
        #expect(!manifest.contains(".package("))
    }
}
