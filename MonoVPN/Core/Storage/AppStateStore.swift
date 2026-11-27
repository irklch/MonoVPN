import Foundation
import os

/// Сохраняет `AppState` (подписка, серверы, выбор) и активную конфигурацию туннеля
/// в Keychain. Ничего секретного не попадает в `UserDefaults`.
struct AppStateStore: Sendable {
    /// Хранилище Keychain, через которое идут все чтения и записи.
    private let storage: SecureStorage
    /// Конфиги серверов JSON-подписки (файл, не Keychain).
    private let panelStore: PanelConfigurationStore
    /// Логгер категории «Storage»; пишет только тип ошибки, без данных.
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "Storage")

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
            // Никогда не логируем сами данные, только вид ошибки.
            Self.logger.error("Failed to load app state: \(String(describing: type(of: error)), privacy: .public)")
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

    /// Сохраняет конфигурацию sing-box, которую Packet Tunnel читает при старте.
    func saveTunnelConfiguration(_ json: String) throws {
        try storage.set(json, for: .tunnelConfiguration)
    }

    /// Удаляет конфигурацию туннеля (например, когда сервер больше не выбран).
    func removeTunnelConfiguration() throws {
        try storage.remove(.tunnelConfiguration)
    }

    /// Удаляет все данные приложения из Keychain: состояние, конфигурацию и последнюю ошибку.
    func removeAll() throws {
        try panelStore.removeAll()
        try storage.remove(.appState)
        try storage.remove(.tunnelConfiguration)
        try storage.remove(.lastTunnelError)
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
