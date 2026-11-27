import Foundation

/// Журнал ошибок Xray-core (`log.error` конфигурации) в контейнере App Group.
///
/// Расширение очищает его при каждом запуске туннеля и не даёт вырасти больше `maxSize`;
/// приложение показывает последние строки в диагностике. Уровень — `warning` (без журнала
/// доступа), но в сообщениях об ошибках подключения Xray может упоминать адрес назначения,
/// поэтому журнал никуда не отправляется и показывается только на устройстве, а IP, UUID,
/// URL и ключи из строк вырезаются.
enum XrayErrorLog {
    /// Максимальный размер файла: при превышении расширение очищает его.
    static let maxSize: UInt64 = 512 * 1024
    /// Сколько байт с конца файла читается для показа.
    static let tailBytes = 64 * 1024
    /// Сколько строк показывать.
    static let visibleLines = 150

    /// Ключ флага подробного журнала в общих настройках App Group.
    private static let verboseKey = "xrayVerboseLog"

    /// Подробный журнал (`loglevel: info`): Xray пишет ошибки каждого соединения через сервер.
    ///
    /// В таком журнале есть адреса посещённых сайтов, поэтому по умолчанию он выключен и
    /// включается вручную в диагностике. Действует со следующего подключения: флаг читает
    /// расширение при запуске туннеля.
    static var isVerbose: Bool {
        get { UserDefaults(suiteName: AppIdentifiers.appGroup)?.bool(forKey: verboseKey) ?? false }
        set { UserDefaults(suiteName: AppIdentifiers.appGroup)?.set(newValue, forKey: verboseKey) }
    }

    /// Путь к файлу журнала; `nil`, если App Group недоступна.
    static var url: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup)?
            .appendingPathComponent("Tunnel", isDirectory: true)
            .appendingPathComponent("xray-error.log")
    }

    /// Создаёт пустой файл журнала (или очищает существующий) и возвращает его путь.
    static func reset() -> String? {
        guard let url else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return url.path
    }

    /// Очищает журнал, если он вырос больше `maxSize`. Xray пишет в режиме дозаписи,
    /// поэтому после усечения продолжает писать с начала файла.
    static func trimIfNeeded() {
        guard let url,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
              size > maxSize,
              let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.close()
    }

    /// Последние строки журнала, очищенные от секретов, новые — первыми.
    static func recentLines() -> [String] {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        return lines(from: text, droppingPartialFirstLine: offset > 0)
    }

    /// Разбор текста журнала (вынесен для тестов).
    static func lines(from text: String, droppingPartialFirstLine: Bool) -> [String] {
        var raw = text.split(whereSeparator: \.isNewline).map(String.init)
        if droppingPartialFirstLine, !raw.isEmpty {
            raw.removeFirst()
        }
        return raw.suffix(visibleLines).reversed().map(sanitize)
    }

    /// Строка журнала без даты и секретов.
    ///
    /// Формат Xray: `2026/11/27 16:29:01.123456 [Warning] [12345] сообщение` — дата
    /// отбрасывается, время остаётся. Длинные токены (ключи, пароли, Base64) вырезаются,
    /// но пути модулей Xray в нижнем регистре (`transport/internet/reality`) сохраняются:
    /// по ним видно, на каком этапе произошла ошибка.
    static func sanitize(_ line: String) -> String {
        // Время отделяется до очистки: иначе шаблон IPv6 принял бы «16:29:01» за адрес.
        var time = ""
        var text = line
        if let match = line.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(\.\d+)? "#, options: .regularExpression) {
            time = String(line[match].dropFirst(11).prefix(8)) + " "
            text = String(line[match.upperBound...])
        }
        let patterns = [
            #"[A-Za-z][A-Za-z0-9+.-]*://\S+"#,
            #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            #"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{0,4}\b"#,
            #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "•••", options: .regularExpression)
        }
        text = time + maskTokens(in: text)
        if text.count > TunnelErrorSanitizer.maxLength {
            text = String(text.prefix(TunnelErrorSanitizer.maxLength)) + "…"
        }
        return text
    }

    /// Заменяет длинные токены с цифрами или заглавными буквами (ключи, пароли) на «•••».
    private static func maskTokens(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/_=-]{20,}"#) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = result[range]
            if token.contains(where: { $0.isNumber || $0.isUppercase }) {
                result.replaceSubrange(range, with: "•••")
            }
        }
        return result
    }
}
