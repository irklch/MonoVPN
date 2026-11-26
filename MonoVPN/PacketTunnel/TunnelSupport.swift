import Foundation

/// Ошибки запуска туннеля в расширении.
enum TunnelError: LocalizedError {
    /// В Keychain нет конфигурации ядра (приложение её ещё не сохранило).
    case missingConfiguration
    /// Ошибка ядра (sing-box / Xray) или подготовки туннеля с текстом без секретов.
    case core(String)

    /// Локализованный текст ошибки; показывается в приложении и виджете.
    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            String(localized: "tunnel.error.missingConfiguration", table: "Tunnel")
        case let .core(message):
            String(localized: "tunnel.error.core \(message)", table: "Tunnel")
        }
    }
}

/// Каталоги ядра внутри контейнера App Group.
struct TunnelPaths {
    /// Базовый каталог данных ядра.
    let base: URL
    /// Рабочий каталог ядра (кэши правил и т. п.).
    let working: URL
    /// Каталог временных файлов в Library/Caches.
    let temp: URL

    /// Возвращает пути в контейнере App Group и создаёт каталоги, если их нет.
    static func prepare() throws -> TunnelPaths {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup
        ) else {
            throw TunnelError.core("App Group container is unavailable")
        }
        let base = container.appendingPathComponent("Tunnel", isDirectory: true)
        let working = base.appendingPathComponent("Working", isDirectory: true)
        let temp = container.appendingPathComponent("Library/Caches/Tunnel", isDirectory: true)
        for url in [base, working, temp] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return TunnelPaths(base: base, working: working, temp: temp)
    }
}
