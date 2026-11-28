import Foundation

/// Удаляет данные необязательной диагностики, которую сохраняли версии до 1.0.0:
///
/// - `<App Group>/Tunnel/diagnostics.json` — события туннеля, время запуска, память;
/// - `<App Group>/Tunnel/xray-error.log` — журнал ошибок Xray (в подробном режиме — с адресами сайтов);
/// - флаг подробного журнала `xrayVerboseLog` в общих настройках App Group;
/// - поля `snapshot` (хеши ответа подписки) и `refreshReports` (отчёты об обновлениях)
///   в сохранённом состоянии в Keychain.
///
/// Выполняется только приложением. Отметка об успешной очистке ставится в `UserDefaults`
/// приложения, только если все шаги действительно выполнены: контейнер App Group и его общие
/// настройки доступны, файлы удалены или их нет, состояние в Keychain прочитано. Иначе
/// (сборка без подписи, Keychain до первой разблокировки, ошибка удаления) очистка
/// повторяется при следующем запуске.
///
/// Удаляются только перечисленные файлы и ключ. Данные, нужные для работы VPN, не
/// затрагиваются: подписка, серверы и выбранный сервер (Keychain, `panel-configurations.json`
/// в Application Support), конфигурация туннеля и последняя ошибка (Keychain), а также любые
/// другие файлы в контейнере App Group, включая подкаталоги `Tunnel`.
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
        // Контейнер недоступен — файлы проверить нельзя, значит очистка не выполнена.
        var succeeded = tunnelDirectory.map { removeFiles(in: $0) } ?? false
        if let groupDefaults {
            groupDefaults.removeObject(forKey: verboseLogKey)
        } else {
            succeeded = false
        }
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

    /// Удаляет файлы диагностики из каталога `Tunnel` и сам каталог, если в нём больше
    /// ничего нет. Удаляются только обычные файлы с именами из `legacyFileNames`; каталог
    /// с таким именем или другие файлы не трогаются.
    ///
    /// Возвращает `true`, если после вызова файлов диагностики в каталоге нет (в том числе
    /// если каталога нет), и `false`, если существующий файл удалить не удалось.
    static func removeFiles(in directory: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue else { return true }
        var succeeded = true
        for name in legacyFileNames {
            let url = directory.appendingPathComponent(name)
            var isItemDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isItemDirectory),
                  !isItemDirectory.boolValue else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                succeeded = false
            }
        }
        if succeeded, let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
        return succeeded
    }
}
