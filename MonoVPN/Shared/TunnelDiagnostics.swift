import Foundation

/// Диагностика расширения Packet Tunnel: запуск ядра, причины остановки и потребление памяти.
///
/// Пишет расширение, читает приложение (окно «Диагностика импорта»). Хранится файлом JSON
/// в контейнере App Group. Секретов не содержит: только время, длительности, коды причин,
/// размеры памяти и очищенные тексты ошибок (`TunnelErrorSanitizer`).
struct TunnelDiagnostics: Codable, Equatable, Sendable {
    /// Одно событие жизненного цикла туннеля.
    struct Event: Codable, Equatable, Sendable {
        /// Когда произошло.
        var date: Date
        /// Короткое описание без секретов.
        var message: String
    }

    /// Ядро и его версия, например `Xray 26.11.9`.
    var core: String?
    /// Начало последней попытки запуска туннеля.
    var startedAt: Date?
    /// Сколько секунд заняла последняя успешная попытка запуска (настройка сети + старт ядра).
    var startDuration: Double?
    /// Время запуска самого ядра в секундах.
    var coreStartDuration: Double?
    /// Очищенный текст ошибки последнего неудачного запуска.
    var lastStartError: String?
    /// Когда туннель последний раз остановился штатно (система вызвала `stopTunnel`).
    var stoppedAt: Date?
    /// Причина последней штатной остановки (`NEProviderStopReason`).
    var stopReason: String?
    /// Текущий объём памяти расширения (phys_footprint — то, что учитывает лимит iOS), МБ.
    var footprintMB: Double?
    /// Пиковый объём памяти за текущую сессию туннеля, МБ.
    var peakFootprintMB: Double?
    /// Сколько памяти ещё доступно расширению до лимита (`os_proc_available_memory`), МБ.
    var availableMB: Double?
    /// Когда последний раз измерялась память.
    var memorySampledAt: Date?
    /// Последние события (не больше `maxEvents`).
    var events: [Event] = []

    /// Сколько событий хранится.
    static let maxEvents = 30

    /// Сессия туннеля началась, но штатной остановки после неё не было.
    var endedWithoutStop: Bool {
        guard let startedAt else { return false }
        return (stoppedAt ?? .distantPast) < startedAt
    }

    /// Добавляет событие, оставляя последние `maxEvents`.
    mutating func record(_ message: String, at date: Date = .now) {
        events.append(Event(date: date, message: message))
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
    }
}

/// Чтение и запись `TunnelDiagnostics` в контейнере App Group.
struct TunnelDiagnosticsStore: Sendable {
    /// Файл диагностики; `nil`, если контейнер App Group недоступен (сборка без подписи).
    let url: URL?

    /// Создаёт хранилище в контейнере App Group (по умолчанию) или по заданному пути (тесты).
    init(url: URL? = TunnelDiagnosticsStore.defaultURL) {
        self.url = url
    }

    /// `<App Group>/Tunnel/diagnostics.json`.
    static var defaultURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("Tunnel", isDirectory: true)
            .appendingPathComponent("diagnostics.json")
    }

    /// Последняя сохранённая диагностика или пустая.
    func load() -> TunnelDiagnostics {
        guard let url, let data = try? Data(contentsOf: url),
              let diagnostics = try? JSONDecoder().decode(TunnelDiagnostics.self, from: data) else {
            return TunnelDiagnostics()
        }
        return diagnostics
    }

    /// Сохраняет диагностику атомарно; ошибки записи игнорируются — диагностика не должна мешать туннелю.
    func save(_ diagnostics: TunnelDiagnostics) {
        guard let url, let data = try? JSONEncoder().encode(diagnostics) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Изменяет сохранённую диагностику.
    func update(_ change: (inout TunnelDiagnostics) -> Void) {
        var diagnostics = load()
        change(&diagnostics)
        save(diagnostics)
    }
}
