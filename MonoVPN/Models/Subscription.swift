import Foundation

/// The single active subscription.
struct Subscription: Codable, Hashable, Sendable {
    enum Source: Codable, Hashable, Sendable {
        /// HTTPS subscription URL. May contain a secret token: never log or show it in full.
        case remote(URL)
        /// A single proxy link (`vless://...`) imported directly.
        case link(String)
    }

    var source: Source
    var servers: [ServerConfiguration]
    /// Entries that were skipped during the last successful import.
    var issues: [ParseIssue]
    /// Date of the last successful import or refresh.
    var lastUpdated: Date

    var isRefreshable: Bool {
        if case .remote = source { return true }
        return false
    }

    /// Representation safe to display: only the host of the subscription URL.
    var maskedSource: String {
        switch source {
        case let .remote(url):
            let host = url.host() ?? url.absoluteString
            return "\(host)/•••"
        case let .link(link):
            let scheme = link.split(separator: ":").first.map(String.init) ?? ""
            return "\(scheme)://•••"
        }
    }
}

/// A subscription entry that could not be imported, with a human readable reason.
struct ParseIssue: Codable, Hashable, Sendable {
    /// Server name from the link (fragment), if it could be read.
    var name: String?
    var reason: String
}

/// Everything the app persists. Stored as one Keychain item because it contains secrets.
struct AppState: Codable, Equatable, Sendable {
    var subscription: Subscription?
    var selectedServerID: String?

    var selectedServer: ServerConfiguration? {
        guard let servers = subscription?.servers else { return nil }
        return servers.first { $0.id == selectedServerID } ?? servers.first
    }
}
