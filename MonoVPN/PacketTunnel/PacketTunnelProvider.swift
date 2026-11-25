import Foundation
import Libbox
import NetworkExtension
import os
import WidgetKit

/// Системный VPN-туннель на ядре sing-box (Libbox).
///
/// Перед запуском туннеля приложение записывает готовую конфигурацию sing-box в общий
/// Keychain, а расширение читает её здесь. Чтение из Keychain (вместо
/// `startVPNTunnel(options:)`) позволяет системе и Настройкам перезапускать туннель,
/// в том числе когда устройство заблокировано.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// Логгер категории «PacketTunnel»; пишет только события, без адресов и секретов.
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "PacketTunnel")

    /// Keychain с конфигурацией туннеля и последней ошибкой запуска.
    private let storage = SecureStorage()
    /// Командный сервер Libbox, в котором работает сервис sing-box; `nil`, пока ядро не запущено.
    private var commandServer: LibboxCommandServer?
    /// Мост между sing-box и NetworkExtension; создаётся лениво, потому что ему нужен `self`.
    private lazy var platformInterface = TunnelPlatformInterface(provider: self)

    /// Ставит обработчики сигналов падения Libbox до любой другой работы, чтобы получить отчёт о крэше ядра.
    override init() {
        LibboxPrepareCrashSignalHandlers()
        super.init()
    }

    /// Запускает ядро; при ошибке сохраняет её текст для приложения и виджета, останавливает ядро и пробрасывает ошибку системе.
    override func startTunnel(options _: [String: NSObject]?) async throws {
        try? storage.remove(.lastTunnelError)
        do {
            try startCore()
            Self.logger.info("Tunnel started")
            reloadWidget()
        } catch {
            let message = (error as NSError).localizedDescription
            try? storage.set(message, for: .lastTunnelError)
            Self.logger.error("Tunnel start failed")
            stopCore()
            reloadWidget()
            throw error
        }
    }

    /// Вызывается системой при остановке туннеля: останавливает ядро и обновляет виджет.
    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.logger.info("Stopping tunnel, reason \(reason.rawValue, privacy: .public)")
        stopCore()
        reloadWidget()
    }

    /// Даёт виджету на домашнем экране подхватить новый статус, в том числе когда VPN
    /// переключают в Настройках или система перезапускает его при закрытом приложении.
    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
    }

    // MARK: - Жизненный цикл ядра

    /// Читает конфигурацию из Keychain, настраивает Libbox (каталоги, версии, OOM-killer)
    /// и запускает сервис sing-box в командном сервере.
    private func startCore() throws {
        guard let configuration = try storage.string(for: .tunnelConfiguration), !configuration.isEmpty else {
            throw TunnelError.missingConfiguration
        }

        let paths = try TunnelPaths.prepare()
        let options = LibboxSetupOptions()
        options.basePath = paths.base.path
        options.workingPath = paths.working.path
        options.tempPath = paths.temp.path
        options.logMaxLines = 300
        options.debug = false
        options.crashReportSource = "NetworkExtension"
        options.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        options.appMarketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        // Позволяет sing-box сбрасывать соединения до того, как iOS убьёт расширение по лимиту памяти.
        options.oomKillerEnabled = true

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            throw TunnelError.core(setupError.localizedDescription)
        }
        LibboxReinstallCrashSignalHandlers()

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError) else {
            throw TunnelError.core(serverError?.localizedDescription ?? "command server")
        }
        commandServer = server
        do {
            try server.start()
            try server.startOrReloadService(configuration, options: LibboxOverrideOptions())
        } catch {
            throw TunnelError.core((error as NSError).localizedDescription)
        }
    }

    /// Закрывает сервис и командный сервер и сбрасывает состояние платформенного моста. Безопасно вызывать повторно.
    private func stopCore() {
        if let commandServer {
            try? commandServer.closeService()
            commandServer.close()
        }
        commandServer = nil
        platformInterface.reset()
    }

    /// Вызывается ядром, когда сервис просит остановить себя.
    func serviceStopRequested() {
        stopCore()
        cancelTunnelWithError(nil)
    }
}

/// Ошибки запуска туннеля в расширении.
enum TunnelError: LocalizedError {
    /// В Keychain нет конфигурации sing-box (приложение её ещё не сохранило).
    case missingConfiguration
    /// Ошибка ядра sing-box / Libbox с текстом от ядра.
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

/// Каталоги, которые Libbox использует внутри контейнера App Group.
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
