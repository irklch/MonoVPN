import Foundation

/// Единственная активная подписка.
struct Subscription: Codable, Hashable, Sendable {
    /// Откуда взята подписка.
    enum Source: Codable, Hashable, Sendable {
        /// HTTPS-URL подписки. Может содержать секретный токен: никогда не логировать и не показывать целиком.
        case remote(URL)
        /// Одна прокси-ссылка (`vless://...`), импортированная напрямую.
        case link(String)
    }

    /// Источник подписки.
    var source: Source
    /// Серверы, полученные при последнем импорте.
    var servers: [ServerConfiguration]
    /// Записи, пропущенные при последнем успешном импорте.
    var issues: [ParseIssue]
    /// Дата последнего успешного импорта или обновления.
    var lastUpdated: Date

    /// Можно ли обновить подписку: только для подписки по URL.
    var isRefreshable: Bool {
        if case .remote = source { return true }
        return false
    }

    /// Безопасное для показа представление: только хост URL подписки.
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

/// Запись подписки, которую не удалось импортировать, с понятной человеку причиной.
struct ParseIssue: Codable, Hashable, Sendable {
    /// Имя сервера из ссылки (фрагмент), если его удалось прочитать.
    var name: String?
    /// Причина, по которой запись пропущена.
    var reason: String
}

/// Всё, что сохраняет приложение. Хранится одним элементом Keychain, потому что содержит секреты.
struct AppState: Codable, Equatable, Sendable {
    /// Текущая подписка; `nil`, пока пользователь её не добавил.
    var subscription: Subscription?
    /// ID выбранного пользователем сервера.
    var selectedServerID: String?

    /// Заменяет подписку, сохраняя выбранный пользователем сервер, если он всё ещё есть;
    /// иначе выбранным становится первый сервер.
    mutating func replaceSubscription(with subscription: Subscription) {
        self.subscription = subscription
        if let id = selectedServerID, subscription.servers.contains(where: { $0.id == id }) {
            return
        }
        selectedServerID = subscription.servers.first?.id
    }

    /// Выбранный сервер; если ID не найден — первый сервер подписки.
    var selectedServer: ServerConfiguration? {
        guard let servers = subscription?.servers else { return nil }
        return servers.first { $0.id == selectedServerID } ?? servers.first
    }
}
