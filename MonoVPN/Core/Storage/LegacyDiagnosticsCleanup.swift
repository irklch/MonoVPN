import Foundation

/// Удаляет данные необязательной диагностики, которую сохраняли версии до 1.0.0:
///
/// - `<App Group>/Tunnel/diagnostics.json` — события туннеля, время запуска, память;
/// - `<App Group>/Tunnel/xray-error.log` — журнал ошибок Xray (в подробном режиме — с адресами сайтов);
/// - флаг подробного журнала `xrayVerboseLog` в общих настройках App Group;
/// - поля `snapshot` (хеши ответа подписки) и `refreshReports` (отчёты об обновлениях)
///   в сохранённом состоянии в Keychain.
///
/// Выполняется только приложением, один раз: после успешной очистки в `UserDefaults`
/// приложения ставится отметка. Если какой-то шаг не удался, очистка повторится при
/// следующем запуске. Данные, нужные для работы (подписка, серверы, выбор сервера,
/// конфигурация туннеля), не затрагиваются.
enum LegacyDiagnosticsCleanup {
    /// Отметка о выполненной очистке в `UserDefaults.standard` (доступна только приложению).
    static let completedKey = "legacyDiagnosticsCleanup.v1"
    /// Ключ флага подробного журнала Xray в общих настройках App Group (прежние версии).
    static let verboseLogKey = "xrayVerboseLog"
    /// Файлы диагностики в каталоге `Tunnel` контейнера App Group (прежние версии).
    static let legacyFileNames = ["diagnostics.json", "xray-error.log"]

    /// Выполняет очистку, если она ещё не выполнялась.
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        groupDefaults: UserDefaults? = UserDefaults(suiteName: AppIdentifiers.appGroup),
        tunnelDirectory: URL? = defaultTunnelDirectory,
        store: AppStateStore = AppStateStore()
    ) {
        guard !defaults.bool(forKey: completedKey) else { return }
        var succeeded = removeFiles(in: tunnelDirectory)
        groupDefaults?.removeObject(forKey: verboseLogKey)
        do {
            try store.removeLegacyDiagnosticFields()
        } catch {
            succeeded = false
        }
        if succeeded {
            defaults.set(true, forKey: completedKey)
        }
    }

    /// `<App Group>/Tunnel`; `nil`, если контейнер недоступен (сборка без подписи).
    static var defaultTunnelDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("Tunnel", isDirectory: true)
    }

    /// Удаляет файлы диагностики и каталог `Tunnel`, если в нём больше ничего нет.
    /// Возвращает `false`, если существующий файл удалить не удалось.
    static func removeFiles(in directory: URL?, fileManager: FileManager = .default) -> Bool {
        guard let directory else { return true }
        var succeeded = true
        for name in legacyFileNames {
            let url = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                succeeded = false
            }
        }
        if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
        return succeeded
    }
}
