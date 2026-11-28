import Foundation

/// Ошибки импорта и обновления подписки, показываемые пользователю.
enum SubscriptionError: LocalizedError, Equatable {
    /// Пользователь ничего не ввёл.
    case emptyInput
    /// Ввод не похож ни на URL подписки, ни на прокси-ссылку.
    case invalidInput
    /// URL подписки использует `http://` вместо `https://`.
    case insecureURL
    /// Сервер подписки ответил кодом вне диапазона 2xx.
    case httpStatus(Int)
    /// Сетевая ошибка загрузки.
    case network(URLError.Code)
    /// Тело ответа больше `SubscriptionService.maxBodySize`.
    case tooLarge
    /// Не удалось разобрать тело подписки.
    case parse(SubscriptionParseError)
    /// Не удалось разобрать одиночную прокси-ссылку.
    case link(ProxyLinkError)

    /// Локализованный текст ошибки для интерфейса.
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

    /// Переводит код `URLError` в понятное сообщение: нет сети, таймаут, хост, TLS или общее.
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

/// Импортирует подписки: скачивает HTTPS-подписки или разбирает одиночную прокси-ссылку.
struct SubscriptionService: Sendable {
    /// Верхняя граница размера тела подписки; настоящие подписки весят несколько КБ.
    static let maxBodySize = 5 * 1024 * 1024

    /// Сессия для загрузки подписок.
    private let session: URLSession

    /// Создаёт сервис; в тестах можно передать свою `URLSession`.
    init(session: URLSession = SubscriptionService.makeSession()) {
        self.session = session
    }

    /// Создаёт эфемерную сессию без кэша и cookies, с таймаутами и своим User-Agent,
    /// чтобы URL подписки и её содержимое не оседали на диске.
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

    /// User-Agent вида `MonoVPN/<версия>`; панели подписок по нему отдают список ссылок.
    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "MonoVPN/\(version)"
    }

    /// Импортирует ввод пользователя: URL подписки `https://` или одиночную прокси-ссылку.
    func importSubscription(from input: String) async throws -> Subscription {
        let source = try Self.source(from: input)
        return try await refresh(source)
    }

    /// Скачивает (или заново разбирает) подписку. При ошибке бросает исключение без побочных
    /// эффектов, чтобы вызывающий мог сохранить последнюю рабочую конфигурацию.
    func refresh(_ source: Subscription.Source) async throws -> Subscription {
        // Xray: сначала готовые конфиги панели (`<подписка>/json`) — в них есть серверы,
        // которых нет в ссылках (балансировщики «Авто», Hysteria). Если панель их не отдаёт,
        // используется обычная подписка со ссылками.
        if case let .remote(url) = source, VPNCore.current == .xray,
           let subscription = try? await refreshJSON(source: source, url: url) {
            return subscription
        }

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
        return Subscription(
            source: source,
            servers: result.servers,
            issues: result.issues,
            lastUpdated: .now,
            core: VPNCore.current,
            format: .links,
            // Пустой словарь стирает конфиги прежней JSON-подписки.
            panelConfigurations: [:]
        )
    }

    /// Загружает JSON-подписку Xray; `nil` — панель её не отдаёт (ошибка, не JSON, нет серверов).
    private func refreshJSON(source: Subscription.Source, url: URL) async throws -> Subscription? {
        let data = try await download(Self.jsonURL(for: url))
        guard XrayJSONSubscriptionParser.looksLikeJSONSubscription(data) else { return nil }
        let result = try XrayJSONSubscriptionParser.parse(data)
        return Subscription(
            source: source,
            servers: result.servers,
            issues: result.issues,
            lastUpdated: .now,
            core: VPNCore.current,
            format: .xrayJSON,
            panelConfigurations: result.configurations
        )
    }

    /// Адрес JSON-подписки: `<путь подписки>/json`, query сохраняется.
    static func jsonURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.appendingPathComponent("json")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path + "/json"
        return components.url ?? url.appendingPathComponent("json")
    }

    /// Проверяет ввод пользователя, не обращаясь к сети.
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

    /// Скачивает тело подписки, проверяя HTTP-статус и предельный размер.
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
