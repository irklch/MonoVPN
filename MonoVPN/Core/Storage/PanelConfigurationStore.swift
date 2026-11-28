import Foundation
import os

/// Конфиги серверов из JSON-подписки Xray (`ServerConfiguration.panel`), по ID сервера.
///
/// Вместе они занимают мегабайты (балансировщик «Авто» — около 200 КБ), поэтому хранятся
/// не в Keychain вместе с состоянием, а в файле в Application Support приложения:
/// с защитой данных «до первой разблокировки» (приложение собирает конфиг туннеля и при
/// запуске в фоне из виджета) и без резервного копирования. Расширение этот файл не читает:
/// конфиг выбранного сервера приложение, как и раньше, кладёт в общий Keychain.
struct PanelConfigurationStore: Sendable {
    #if DEBUG
    /// Логгер (только DEBUG): пишет только тип ошибки, без данных.
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "Storage")
    #endif

    /// Путь к файлу; `nil` — хранилище недоступно.
    let url: URL?

    init(url: URL? = PanelConfigurationStore.defaultURL) {
        self.url = url
    }

    /// `Application Support/panel-configurations.json`.
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("panel-configurations.json")
    }

    /// Все конфиги; пустой словарь, если файла нет или он повреждён.
    func load() -> [String: String] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            #if DEBUG
            Self.logger.error("Failed to read panel configurations: \(String(describing: type(of: error)), privacy: .public)")
            #endif
            return [:]
        }
    }

    /// Конфиг сервера или `nil`.
    func configuration(for id: String) -> String? {
        load()[id]
    }

    /// Заменяет все конфиги.
    func save(_ configurations: [String: String]) throws {
        guard var url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(configurations)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Удаляет файл.
    func removeAll() throws {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
