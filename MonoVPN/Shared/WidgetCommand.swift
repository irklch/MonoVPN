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

/// Что виджет узнал о системной конфигурации VPN (упрощённый `TunnelLookup` для вычисления состояния).
enum WidgetConfigurationAccess: Equatable, Sendable {
    /// Конфигурация найдена, статус известен.
    case found
    /// Конфигурации нет (или процесс виджета её не видит) — создать её может только приложение.
    case notInstalled
    /// Чтение конфигурации завершилось ошибкой (отказ в доступе или системная ошибка).
    case unavailable
}

/// Что показывает виджет. Каждый раз выводится из `NEVPNStatus`, никогда не хранится.
enum WidgetVPNState: Equatable, Sendable {
    /// Нет подписки или не выбран сервер: подключаться не к чему.
    case noServer
    /// Сервер выбран, но системная конфигурация VPN не найдена: первое подключение
    /// должно пройти в приложении, которое покажет системный запрос.
    case needsSetup
    /// Процесс виджета не смог прочитать конфигурацию VPN (отказ в доступе / системная ошибка):
    /// статус неизвестен, нажатие открывает приложение.
    case unavailable
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

    /// Вычисляет состояние виджета.
    ///
    /// Подключённое и переходные состояния берутся только из реального системного статуса,
    /// поэтому «Подключено» без подтверждения системы показано быть не может.
    /// - Parameters:
    ///   - status: системный статус; `nil`, если конфигурация не найдена или не прочитана.
    ///   - access: результат чтения конфигурации.
    ///   - hasConfiguration: выбран ли сервер (в Keychain есть конфигурация туннеля).
    ///   - hasError: есть ли невыпущенная ошибка туннеля или виджета.
    static func resolve(
        status: NEVPNStatus?,
        access: WidgetConfigurationAccess,
        hasConfiguration: Bool,
        hasError: Bool
    ) -> WidgetVPNState {
        if access == .found {
            switch status {
            case .connecting?, .reasserting?: return .connecting
            case .connected?: return .connected
            case .disconnecting?: return .disconnecting
            default: break
            }
        }
        if access == .unavailable { return .unavailable }
        guard hasConfiguration else { return .noServer }
        guard access == .found, let status, status != .invalid else { return .needsSetup }
        return hasError ? .failed : .disconnected
    }

    /// Команда, которую отправляет нажатие через App Intent, или `nil`, если кнопка не интерактивна
    /// (в `needsSetup` и `unavailable` нажатие открывает приложение через `opensApp`).
    var command: TunnelCommand? {
        switch self {
        case .disconnected, .failed: .connect
        case .connected, .connecting: .disconnect
        case .noServer, .disconnecting, .needsSetup, .unavailable: nil
        }
    }

    /// Нажатие открывает приложение с командой «connect» — безопасный путь через основное
    /// приложение, когда виджет не может управлять туннелем сам. «connect» идемпотентна:
    /// работающий VPN приложение не остановит.
    var opensApp: Bool {
        self == .needsSetup || self == .unavailable
    }

    /// Идёт подключение или отключение — виджет показывает индикатор ожидания.
    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting
    }
}

/// Пропускает в процессе виджета только одну команду за раз: повторное нажатие, пока
/// предыдущая ещё ждёт ответа системы, игнорируется.
actor WidgetCommandGate {
    /// Выполняется ли сейчас команда.
    private var isRunning = false

    /// Занимает шлюз; `false`, если команда уже выполняется.
    func tryBegin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// Освобождает шлюз.
    func end() {
        isRunning = false
    }
}

/// Выполняет команды виджета через общий `TunnelController`. Работает в процессе
/// расширения виджета, без интерфейса приложения.
///
/// Межпроцессной блокировки между приложением и виджетом NetworkExtension не даёт, поэтому
/// согласованность держится на перепроверке реального `NEVPNStatus` перед каждым действием
/// (`TunnelCommand.action`, `TunnelController.start/stop`).
enum WidgetCommandRunner {
    /// Шлюз от повторных нажатий внутри процесса виджета.
    static let gate = WidgetCommandGate()

    /// Читает текущее состояние для таймлайна виджета. После подтверждённого подключения
    /// сбрасывает устаревшую ошибку виджета.
    static func currentState(storage: SecureStorage = SecureStorage()) async -> WidgetVPNState {
        let hasConfiguration = (try? storage.data(for: .tunnelConfiguration)) != nil
        let status: NEVPNStatus?
        let access: WidgetConfigurationAccess
        switch await TunnelController.lookupManager() {
        case let .found(manager):
            status = manager.connection.status
            access = .found
        case .notInstalled:
            status = nil
            access = .notInstalled
        case .unavailable:
            status = nil
            access = .unavailable
        }
        if status == .connected {
            try? storage.remove(.widgetError)
        }
        return .resolve(status: status, access: access, hasConfiguration: hasConfiguration, hasError: hasError(storage))
    }

    /// Выполняет команду и ждёт (ограниченное время), пока система подтвердит результат.
    /// Любая ошибка сохраняется, чтобы виджет показал «Ошибка», а не делал вид, что всё удалось.
    static func perform(_ command: TunnelCommand, storage: SecureStorage = SecureStorage()) async {
        guard await gate.tryBegin() else { return }
        await run(command, storage: storage)
        await gate.end()
    }

    /// Тело `perform` без шлюза.
    private static func run(_ command: TunnelCommand, storage: SecureStorage) async {
        let manager: NETunnelProviderManager
        switch await TunnelController.lookupManager() {
        case let .found(found):
            manager = found
        case .notInstalled:
            // Виджет покажет «Настройте в приложении»; конфигурацию создаёт только приложение.
            return
        case let .unavailable(error):
            record(error, storage: storage)
            return
        }

        let hasConfiguration = (try? storage.data(for: .tunnelConfiguration)) != nil
        switch command.action(status: manager.connection.status, hasConfiguration: hasConfiguration) {
        case .none:
            return
        case .start:
            try? storage.remove(.widgetError)
            do {
                try await TunnelController.start(manager, timeout: .seconds(10))
            } catch {
                record(error, storage: storage)
                return
            }
            let status = await TunnelController.waitForStatus(of: manager.connection, timeout: .seconds(10)) {
                $0 == .connected || $0 == .disconnected || $0 == .invalid
            }
            if status == .disconnected || status == .invalid, !hasTunnelError(storage) {
                // Система остановила туннель, а расширение не оставило причину.
                record(VPNError.startFailed(String(localized: "error.vpn.timeout", table: "Tunnel")), storage: storage)
            }
        case .stop:
            do {
                try await TunnelController.stop(manager, timeout: .seconds(10))
                try? storage.remove(.widgetError)
            } catch {
                record(error, storage: storage)
            }
        }
    }

    /// Сохраняет текст ошибки для виджета и приложения.
    private static func record(_ error: Error, storage: SecureStorage) {
        try? storage.set(error.localizedDescription, for: .widgetError)
    }

    /// Есть ли непустая ошибка, которую оставил туннель.
    private static func hasTunnelError(_ storage: SecureStorage) -> Bool {
        ((try? storage.string(for: .lastTunnelError)) ?? nil).map { !$0.isEmpty } ?? false
    }

    /// Есть ли ошибка туннеля или виджета.
    private static func hasError(_ storage: SecureStorage) -> Bool {
        let widgetError = (try? storage.string(for: .widgetError)) ?? nil
        return hasTunnelError(storage) || !(widgetError ?? "").isEmpty
    }
}
