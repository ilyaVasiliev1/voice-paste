import Foundation

/// Где лежат приватные тест-фикстуры — реальные голосовые сообщения.
///
/// Предпочтительное место — **вне репозитория**. Причин две, и обе весомые.
///
/// Первая: эти файлы намеренно не в git, потому что в настоящей речи могут
/// быть личные данные. Раз они всё равно не версионируются, держать их внутри
/// рабочей копии незачем — там они только ждут случайного `git add -f`.
///
/// Вторая: пока они лежат в `~/Documents`, тестовый хост читает оттуда при
/// каждом прогоне, и macOS спрашивает доступ к папке «Документы» снова и
/// снова — пересобранный и заново подписанный пакет для TCC каждый раз новое
/// приложение, и прежнее разрешение к нему не относится.
///
/// Путь внутри репозитория остаётся запасным, чтобы уже разложенные фикстуры
/// продолжали работать.
enum TestFixtureLocator {

    /// `~/Library/Application Support/VoicePaste/TestFixtures`
    static var externalRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoicePaste/TestFixtures", isDirectory: true)
    }

    /// Ищет фикстуру сначала снаружи, затем в рабочей копии.
    ///
    /// - Parameters:
    ///   - relativePath: путь вроде `TelegramOGG/sample-01.ogg`.
    ///   - sourceFile: `#filePath` вызывающего теста — по нему считается
    ///     запасное место внутри `VoicePasteTests/Fixtures`.
    static func url(for relativePath: String, sourceFile: String) -> URL? {
        let external = externalRoot.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: external.path) { return external }

        let inRepository = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: inRepository.path) { return inRepository }

        return nil
    }

    /// Текст пропуска: говорит, чего не хватает и куда это положить, чтобы
    /// разбираться не пришлось по коду.
    static func absenceReason(for relativePath: String) -> String {
        """
        Фикстура \(relativePath) не найдена. Она приватная и в git не входит.
        Предпочтительное место: \(externalRoot.path)/\(relativePath)
        Запасное: VoicePasteTests/Fixtures/\(relativePath)
        """
    }
}
