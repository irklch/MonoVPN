import Foundation

enum SubscriptionParseError: LocalizedError, Equatable {
    case empty
    case unsupportedFormat(String)
    case noSupportedServers([ParseIssue])

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

struct SubscriptionParseResult: Equatable {
    var servers: [ServerConfiguration]
    var issues: [ParseIssue]
}

/// Turns a subscription body into servers.
///
/// Supported: a list of proxy links, either plain text (one per line) or Base64
/// encoded (standard or URL-safe), which is what most panels (3x-ui, Marzban,
/// Remnawave, ...) return to generic clients. Clash YAML and sing-box / Xray JSON
/// are detected and rejected with an explicit message.
enum SubscriptionParser {
    static func parse(_ data: Data) throws -> SubscriptionParseResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SubscriptionParseError.unsupportedFormat("binary")
        }
        return try parse(text)
    }

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

    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
    }

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
