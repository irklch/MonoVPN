import Foundation

/// Ошибки разбора тела подписки.
enum SubscriptionParseError: LocalizedError, Equatable {
    /// Тело подписки пустое.
    case empty
    /// Формат не поддерживается (JSON, Clash YAML, HTML и т. п.); в значении — название формата.
    case unsupportedFormat(String)
    /// Ни одна ссылка не подошла; в значении — причины по каждой записи.
    case noSupportedServers([ParseIssue])

    /// Локализованный текст ошибки; для `noSupportedServers` показывает причину первой записи.
    var errorDescription: String? {
        switch self {
        case .empty:
            String(localized: "error.subscription.empty")
        case let .unsupportedFormat(format):
            String(localized: "error.subscription.unsupportedFormat \(format)")
        case let .noSupportedServers(issues):
            if let first = issues.first {
                String(localized: "error.subscription.noSupportedServers \(first.reason)")
            } else {
                String(localized: "error.subscription.empty")
            }
        }
    }
}

/// Результат разбора подписки: принятые серверы и пропущенные записи.
struct SubscriptionParseResult: Equatable {
    /// Серверы без дубликатов, в порядке появления.
    var servers: [ServerConfiguration]
    /// Записи, которые не удалось импортировать, с причинами.
    var issues: [ParseIssue]
}

/// Превращает тело подписки в серверы.
///
/// Поддерживается: список прокси-ссылок — простым текстом (по одной в строке) или в Base64
/// (стандартном или URL-safe); именно так большинство панелей (3x-ui, Marzban,
/// Remnawave, ...) отвечают обычным клиентам. Clash YAML и JSON sing-box / Xray
/// распознаются и отклоняются с понятным сообщением.
enum SubscriptionParser {
    /// Декодирует байты как UTF-8 (или Latin-1) и разбирает текст.
    static func parse(_ data: Data) throws -> SubscriptionParseResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SubscriptionParseError.unsupportedFormat("binary")
        }
        return try parse(text)
    }

    /// Разбирает текст подписки: при необходимости декодирует Base64, затем разбирает каждую ссылку.
    ///
    /// Неподдерживаемые и битые ссылки попадают в `issues`, дубликаты по `id` отбрасываются.
    /// Если не принят ни один сервер — бросает `noSupportedServers`.
    static func parse(_ text: String) throws -> SubscriptionParseResult {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard !body.isEmpty else { throw SubscriptionParseError.empty }

        let lines: [String]
        if body.contains("://") {
            lines = splitLines(body)
        } else if let decoded = Base64.decodeString(body), decoded.contains("://") {
            lines = splitLines(decoded)
        } else {
            throw SubscriptionParseError.unsupportedFormat(detectFormat(body))
        }

        var servers: [ServerConfiguration] = []
        var issues: [ParseIssue] = []
        var seen = Set<String>()

        for line in lines {
            guard ProxyLinkParser.isProxyLink(line) else {
                if line.contains("://") {
                    let scheme = line.components(separatedBy: "://")[0].lowercased()
                    issues.append(ParseIssue(
                        name: ProxyLinkParser.displayName(of: line),
                        reason: ProxyLinkError.unsupportedScheme(scheme).localizedDescription
                    ))
                }
                continue
            }
            do {
                let server = try ProxyLinkParser.parse(line)
                if seen.insert(server.id).inserted {
                    servers.append(server)
                }
            } catch {
                issues.append(ParseIssue(name: ProxyLinkParser.displayName(of: line), reason: error.localizedDescription))
            }
        }

        guard !servers.isEmpty else {
            throw SubscriptionParseError.noSupportedServers(issues)
        }
        return SubscriptionParseResult(servers: servers, issues: issues)
    }

    /// Делит текст на строки, обрезает пробелы и убирает пустые строки и комментарии (`#`, `//`).
    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
    }

    /// Угадывает формат неподдерживаемого тела, чтобы назвать его в сообщении об ошибке.
    private static func detectFormat(_ body: String) -> String {
        if body.hasPrefix("{") || body.hasPrefix("[") {
            return "JSON"
        }
        if body.contains("proxies:") || body.contains("proxy-groups:") {
            return "Clash YAML"
        }
        if body.lowercased().hasPrefix("<!doctype html") || body.lowercased().hasPrefix("<html") {
            return "HTML"
        }
        return String(localized: "format.unknown")
    }
}
