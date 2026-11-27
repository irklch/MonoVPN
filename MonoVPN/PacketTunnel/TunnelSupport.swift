import Foundation

/// Ошибки запуска туннеля в расширении.
enum TunnelError: LocalizedError {
    /// В Keychain нет конфигурации ядра (приложение её ещё не сохранило).
    case missingConfiguration
    /// Ошибка ядра Xray или подготовки туннеля с текстом без секретов.
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
