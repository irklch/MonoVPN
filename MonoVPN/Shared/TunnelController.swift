import Foundation
@preconcurrency import NetworkExtension

/// Состояние подключения, один к одному отражающее `NEVPNStatus` — единственный источник истины.
enum VPNConnectionState: Equatable, Sendable {
    /// Конфигурация VPN отсутствует или недействительна.
    case invalid
    /// Туннель отключён.
    case disconnected
    /// Туннель подключается.
    case connecting
    /// Туннель подключён.
    case connected
    /// Система восстанавливает соединение (например, после смены сети).
    case reasserting
    /// Туннель отключается.
    case disconnecting

    /// Преобразует системный `NEVPNStatus`; неизвестные значения считаются `.invalid`.
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid: self = .invalid
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        @unknown default: self = .invalid
        }
    }

    /// Туннель поднят или поднимается: новая конфигурация требует перезапуска.
    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reasserting: true
        default: false
        }
    }

    /// Идёт переходное состояние — интерфейс показывает ожидание и блокирует кнопку.
    var isTransitioning: Bool {
        switch self {
        case .connecting, .reasserting, .disconnecting: true
        default: false
        }
    }
}

/// Ошибки управления VPN, показываемые пользователю.
enum VPNError: LocalizedError, Equatable {
    /// Пользователь не разрешил добавить конфигурацию VPN.
    case permissionDenied
    /// Не удалось сохранить или загрузить конфигурацию VPN.
    case configurationFailed(String)
    /// Система не смогла запустить туннель.
    case startFailed(String)
    /// Ошибка, о которой сообщило само расширение туннеля.
    case tunnel(String)
    /// Система не подтвердила изменение статуса вовремя.
    case timeout

    // Строки лежат в общей таблице "Tunnel", чтобы их мог показать и виджет.
    /// Локализованный текст ошибки для интерфейса.
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            String(localized: "error.vpn.permissionDenied", table: "Tunnel")
        case let .configurationFailed(message):
            String(localized: "error.vpn.configuration \(message)", table: "Tunnel")
        case let .startFailed(message):
            String(localized: "error.vpn.start \(message)", table: "Tunnel")
        case let .tunnel(message):
            String(localized: "error.vpn.tunnel \(message)", table: "Tunnel")
        case .timeout:
            String(localized: "error.vpn.timeout", table: "Tunnel")
        }
    }
}

/// Операции NetworkExtension без собственного состояния, общие для приложения (`VPNManager`) и
/// App Intent виджета. Каждый вызов работает с переданным менеджером и перечитывает статус
/// из системы, поэтому их безопасно вызывать из любого процесса приложения.
enum TunnelController {
    /// Конфигурация VPN, созданная Mono VPN, или `nil`, если она ни разу не устанавливалась
    /// (или была удалена в Настройках).
    static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppIdentifiers.tunnelBundleID
        }
    }

    /// Создаёт или обновляет конфигурацию VPN и включает её.
    ///
    /// При создании система показывает алерт «Добавить конфигурацию VPN», поэтому отсутствующую
    /// конфигурацию нужно создавать из приложения, а не из виджета.
    static func install(_ existing: NETunnelProviderManager?) async throws -> NETunnelProviderManager {
        let manager = existing ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppIdentifiers.tunnelBundleID
        // Показывается в Настройки → VPN. Это не настоящий адрес: сервер хранится в Keychain.
        proto.serverAddress = "Mono VPN"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Mono VPN"
        manager.isEnabled = true
        try await save(manager)
        return manager
    }

    /// Запускает туннель. Если управление перехватило другое VPN-приложение, сначала снова
    /// включает Mono VPN (существующая конфигурация обновляется без системного запроса).
    static func start(_ manager: NETunnelProviderManager) async throws {
        if !manager.isEnabled {
            manager.isEnabled = true
            try await save(manager)
        }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            throw VPNError.startFailed(error.localizedDescription)
        }
    }

    /// Останавливает туннель и ждёт, пока система подтвердит `.disconnected`.
    /// Возвращает `false`, если подтверждение не пришло за `timeout`.
    @discardableResult
    static func stop(_ manager: NETunnelProviderManager, timeout: Duration = .seconds(15)) async -> Bool {
        let connection = manager.connection
        switch connection.status {
        case .disconnected, .invalid:
            return true
        default:
            connection.stopVPNTunnel()
        }
        let status = await waitForStatus(of: connection, timeout: timeout) { $0 == .disconnected || $0 == .invalid }
        return status == .disconnected || status == .invalid
    }

    /// Ждёт (без опроса) уведомлений `NEVPNStatusDidChange`, пока не выполнится `predicate`
    /// или не истечёт таймаут. Возвращает последний статус, сообщённый системой.
    static func waitForStatus(
        of connection: NEVPNConnection,
        timeout: Duration,
        until predicate: @escaping @Sendable (NEVPNStatus) -> Bool
    ) async -> NEVPNStatus {
        nonisolated(unsafe) let connection = connection
        // Подписываемся до чтения статуса, чтобы не пропустить изменение между ними.
        let changes = NotificationCenter.default.notifications(named: .NEVPNStatusDidChange, object: connection)
        if predicate(connection.status) { return connection.status }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in changes where predicate(connection.status) {
                    return
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        return connection.status
    }

    /// Сохраняет менеджер в системные настройки и сразу перечитывает его.
    ///
    /// Отказ пользователя в системном алерте превращается в `VPNError.permissionDenied`,
    /// остальные ошибки — в `VPNError.configurationFailed`.
    private static func save(_ manager: NETunnelProviderManager) async throws {
        do {
            try await manager.saveToPreferences()
            // Обязательно после сохранения, иначе следующий запуск может взять устаревшую конфигурацию.
            try await manager.loadFromPreferences()
        } catch {
            let nsError = error as NSError
            let deniedCodes = [NEVPNError.configurationReadWriteFailed.rawValue, NEVPNError.configurationDisabled.rawValue]
            if nsError.domain == NEVPNErrorDomain, deniedCodes.contains(nsError.code) {
                // Пользователь нажал «Не разрешать» в системном алерте.
                throw VPNError.permissionDenied
            }
            throw VPNError.configurationFailed(error.localizedDescription)
        }
    }
}
