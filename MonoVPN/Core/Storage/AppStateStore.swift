import Foundation
import os

/// Сохраняет `AppState` (подписка, серверы, выбор) и активную конфигурацию туннеля
/// в Keychain. Ничего секретного не попадает в `UserDefaults`.
struct AppStateStore: Sendable {
    /// Хранилище Keychain, через которое идут все чтения и записи.
    private let storage: SecureStorage
    /// Конфиги серверов JSON-подписки (файл, не Keychain).
    private let panelStore: PanelConfigurationStore
    #if DEBUG
    /// Логгер категории «Storage» (только DEBUG); пишет только тип ошибки, без данных.
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "Storage")
    #endif

    /// Создаёт хранилище; в тестах можно передать свой `SecureStorage`.
    init(storage: SecureStorage = SecureStorage(), panelStore: PanelConfigurationStore = PanelConfigurationStore()) {
        self.storage = storage
        self.panelStore = panelStore
    }

    /// Загружает сохранённое состояние приложения.
    ///
    /// При отсутствии данных или ошибке чтения/декодирования возвращает пустое `AppState`,
    /// чтобы приложение всегда могло запуститься.
    func load() -> AppState {
        do {
            guard let data = try storage.data(for: .appState) else { return AppState() }
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            #if DEBUG
            // Никогда не логируем сами данные, только вид ошибки.
            Self.logger.error("Failed to load app state: \(String(describing: type(of: error)), privacy: .public)")
            #endif
            return AppState()
        }
    }

    /// Сохраняет состояние приложения в Keychain в виде JSON.
    func save(_ state: AppState) throws {
        // Сначала конфиги JSON-подписки: состояние не должно ссылаться на несохранённые конфиги.
        if let configurations = state.subscription?.panelConfigurations {
            try panelStore.save(configurations)
        }
        let data = try JSONEncoder().encode(state)
        try storage.set(data, for: .appState)
    }

    /// Переписывает сохранённое состояние без полей диагностики прежних версий
    /// (`refreshReports`, `subscription.snapshot`). Ничего не делает, если состояния нет,
    /// этих полей в нём нет или оно не читается (повреждённое состояние не перезаписывается).
    func removeLegacyDiagnosticFields() throws {
        guard let data = try storage.data(for: .appState),
              let cleaned = try Self.withoutLegacyDiagnosticFields(data) else { return }
        try storage.set(cleaned, for: .appState)
    }

    /// Состояние без полей диагностики прежних версий; `nil`, если таких полей нет
    /// или данные не являются JSON-объектом. Бросает ошибку, если состояние не декодируется.
    static func withoutLegacyDiagnosticFields(_ data: Data) throws -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let subscription = object["subscription"] as? [String: Any]
        guard object["refreshReports"] != nil || subscription?["snapshot"] != nil else { return nil }
        let state = try JSONDecoder().decode(AppState.self, from: data)
        return try JSONEncoder().encode(state)
    }

    /// Сохраняет конфигурацию туннеля (Xray), которую Packet Tunnel читает при старте.
    func saveTunnelConfiguration(_ json: String) throws {
        try storage.set(json, for: .tunnelConfiguration)
    }

    /// Удаляет конфигурацию туннеля (например, когда сервер больше не выбран).
    func removeTunnelConfiguration() throws {
        try storage.remove(.tunnelConfiguration)
    }

    /// Удаляет все данные подписки: конфиги JSON-подписки (файл) и из Keychain — состояние,
    /// конфигурацию туннеля и последние ошибки туннеля и виджета.
    func removeAll() throws {
        try panelStore.removeAll()
        try storage.remove(.appState)
        try storage.remove(.tunnelConfiguration)
        try storage.remove(.lastTunnelError)
        try storage.remove(.widgetError)
    }
}

/// Несекретные настройки интерфейса.
enum Preferences {
    /// Ключ в `UserDefaults` для флага принятия уведомления о конфиденциальности.
    private static let privacyNoticeKey = "privacyNoticeAccepted"

    /// Принял ли пользователь уведомление о конфиденциальности; нужно, чтобы показать его один раз.
    static var isPrivacyNoticeAccepted: Bool {
        get { UserDefaults.standard.bool(forKey: privacyNoticeKey) }
        set { UserDefaults.standard.set(newValue, forKey: privacyNoticeKey) }
    }
}
