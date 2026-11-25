import Foundation

enum SubscriptionError: LocalizedError, Equatable {
    case emptyInput
    case invalidInput
    case insecureURL
    case httpStatus(Int)
    case network(URLError.Code)
    case tooLarge
    case parse(SubscriptionParseError)
    case link(ProxyLinkError)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            String(localized: "error.input.empty")
        case .invalidInput:
            String(localized: "error.input.invalid")
        case .insecureURL:
            String(localized: "error.input.insecure")
        case let .httpStatus(code):
            String(localized: "error.network.status \(code)")
        case let .network(code):
            Self.describe(code)
        case .tooLarge:
            String(localized: "error.network.tooLarge")
        case let .parse(error):
            error.errorDescription
        case let .link(error):
            error.errorDescription
        }
    }

    private static func describe(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            String(localized: "error.network.offline")
        case .timedOut:
            String(localized: "error.network.timeout")
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            String(localized: "error.network.host")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            String(localized: "error.network.tls")
        default:
            String(localized: "error.network.generic \(code.rawValue)")
        }
    }
}

/// Imports subscriptions: downloads HTTPS subscriptions or parses a single proxy link.
struct SubscriptionService: Sendable {
    /// Upper bound for a subscription body; real ones are a few KB.
    static let maxBodySize = 5 * 1024 * 1024

    private let session: URLSession

    init(session: URLSession = SubscriptionService.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: configuration)
    }

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "MonoVPN/\(version)"
    }

    /// Imports user input: an `https://` subscription URL or a single proxy link.
    func importSubscription(from input: String) async throws -> Subscription {
        let source = try Self.source(from: input)
        return try await refresh(source)
    }

    /// Downloads (or re-parses) the subscription. Throws without side effects on failure,
    /// so the caller can keep the last valid configuration.
    func refresh(_ source: Subscription.Source) async throws -> Subscription {
        let result: SubscriptionParseResult
        switch source {
        case let .remote(url):
            let data = try await download(url)
            do {
                result = try SubscriptionParser.parse(data)
            } catch let error as SubscriptionParseError {
                throw SubscriptionError.parse(error)
            }
        case let .link(link):
            do {
                result = SubscriptionParseResult(servers: [try ProxyLinkParser.parse(link)], issues: [])
            } catch let error as ProxyLinkError {
                throw SubscriptionError.link(error)
            }
        }
        return Subscription(source: source, servers: result.servers, issues: result.issues, lastUpdated: .now)
    }

    /// Validates user input without touching the network.
    static func source(from input: String) throws -> Subscription.Source {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SubscriptionError.emptyInput }

        if ProxyLinkParser.isProxyLink(trimmed) {
            return .link(trimmed)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host() != nil else {
            throw SubscriptionError.invalidInput
        }
        switch scheme {
        case "https":
            return .remote(url)
        case "http":
            throw SubscriptionError.insecureURL
        default:
            if trimmed.contains("://") {
                throw SubscriptionError.link(.unsupportedScheme(scheme))
            }
            throw SubscriptionError.invalidInput
        }
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw SubscriptionError.network(error.code)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SubscriptionError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maxBodySize else { throw SubscriptionError.tooLarge }
        return data
    }
}
