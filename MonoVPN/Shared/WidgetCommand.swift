import Foundation
import NetworkExtension

/// Запрос на подключение / отключение от виджета — через его App Intent
/// или через URL `monovpn://`, который открывает приложение.
///
/// Команды идемпотентны («connect» никогда не останавливает работающий туннель), поэтому
/// повторное нажатие или дважды доставленная команда не могут переключить VPN обратно.
enum TunnelCommand: String, Sendable, Equatable {
    /// Подключить VPN.
    case connect
    /// Отключить VPN.
    case disconnect

    /// Схема URL, по которой виджет открывает приложение с командой.
    static let urlScheme = "monovpn"

    /// Разбирает команду из URL вида `monovpn://connect`; `nil` для чужих или неизвестных URL.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme, let host = url.host()?.lowercased() else { return nil }
        self.init(rawValue: host)
    }

    /// URL этой команды для ссылки из виджета.
    var url: URL {
        // Статическая строка из известной схемы и имени case: всегда корректна.
        URL(string: "\(Self.urlScheme)://\(rawValue)") ?? URL(fileURLWithPath: "/")
    }

    /// Действие, которое нужно выполнить с туннелем.
    enum Action: Equatable {
        /// Запустить туннель.
        case start
        /// Остановить туннель.
        case stop
        /// Ничего не делать: состояние уже соответствует команде.
        case none
    }

    /// Что делать по этой команде с учётом реального системного статуса.
    func action(status: NEVPNStatus, hasConfiguration: Bool) -> Action {
        switch self {
        case .connect:
            guard hasConfiguration else { return .none }
            switch status {
            case .disconnected, .invalid: return .start
            default: return .none // уже запускается/работает или ещё останавливается
            }
        case .disconnect:
            switch status {
            case .connecting, .connected, .reasserting: return .stop
            default: return .none
            }
        }
    }
}

/// Что показывает виджет. Каждый раз выводится из `NEVPNStatus`, никогда не хранится.
enum WidgetVPNState: Equatable, Sendable {
    /// Нет подписки или не выбран сервер: подключаться не к чему.
    case noServer
    /// Сервер выбран, но системная конфигурация VPN ещё не установлена
    /// (первое подключение должно пройти в приложении, которое покажет системный запрос).
    case needsSetup
    /// VPN отключён.
    case disconnected
    /// VPN подключается.
    case connecting
    /// VPN подключён.
    case connected
    /// VPN отключается.
    case disconnecting
    /// Последний запуск не удался (сообщил туннель или виджет).
    case failed

    /// Вычисляет состояние виджета из системного статуса, наличия конфигурации и последней ошибки.
    ///
    /// Переходные и подключённое состояния берутся из статуса в первую очередь,
    /// остальное зависит от того, есть ли сервер и установлена ли конфигурация.
    static func resolve(status: NEVPNStatus?, hasConfiguration: Bool, lastError: String?) -> WidgetVPNState {
        switch status {
        case .connecting?, .reasserting?: return .connecting
        case .connected?: return .connected
        case .disconnecting?: return .disconnecting
        default: break
        }
        guard hasConfiguration else { return .noServer }
        guard let status, status != .invalid else { return .needsSetup }
        if let lastError, !lastError.isEmpty { return .failed }
        return .disconnected
    }

    /// Команда, которую отправляет нажатие, или `nil`, если в этом состоянии виджет не интерактивен.
    var command: TunnelCommand? {
        switch self {
        case .needsSetup, .disconnected, .failed: .connect
        case .connected, .connecting: .disconnect
        case .noServer, .disconnecting: nil
        }
    }

    /// Идёт подключение или отключение — виджет показывает индикатор ожидания.
    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting
    }
}

/// Выполняет команды виджета через общий `TunnelController`. Работает в том процессе,
/// который выполняет App Intent (расширение виджета), — без интерфейса приложения.
enum WidgetCommandRunner {
    /// Читает текущее состояние для таймлайна виджета.
    static func currentState(storage: SecureStorage = SecureStorage()) async -> WidgetVPNState {
        let hasConfiguration = (try? storage.data(for: .tunnelConfiguration)) != nil
        let lastError = try? storage.string(for: .lastTunnelError)
        let manager = try? await TunnelController.loadManager()
        return .resolve(status: manager?.connection.status, hasConfiguration: hasConfiguration, lastError: lastError)
    }

    /// Выполняет команду и ждёт (ограниченное время), пока система подтвердит результат.
    /// Ошибки сохраняются, чтобы виджет их показал, а не делал вид, что всё удалось.
    static func perform(_ command: TunnelCommand, storage: SecureStorage = SecureStorage()) async {
        let hasConfiguration = (try? storage.data(for: .tunnelConfiguration)) != nil
        guard let manager = try? await TunnelController.loadManager() else { return }

        switch command.action(status: manager.connection.status, hasConfiguration: hasConfiguration) {
        case .none:
            return
        case .start:
            try? storage.remove(.lastTunnelError)
            do {
                try await TunnelController.start(manager)
            } catch {
                try? storage.set(error.localizedDescription, for: .lastTunnelError)
                return
            }
            _ = await TunnelController.waitForStatus(of: manager.connection, timeout: .seconds(10)) {
                $0 == .connected || $0 == .disconnected || $0 == .invalid
            }
        case .stop:
            await TunnelController.stop(manager, timeout: .seconds(10))
        }
    }
}
