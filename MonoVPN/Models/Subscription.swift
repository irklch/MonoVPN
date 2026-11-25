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
    /// Записи, пропущенные при последнем успешном импорте (битые ссылки, неизвестные схемы).
    /// Показываются только в диагностике импорта.
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

    /// Заменяет подписку, сохраняя выбранный пользователем сервер, если он всё ещё есть
    /// и поддерживается; иначе выбранным становится первый поддерживаемый сервер.
    mutating func replaceSubscription(with subscription: Subscription) {
        self.subscription = subscription
        let supported = subscription.servers.filter(\.isSupported)
        if let id = selectedServerID, supported.contains(where: { $0.id == id }) {
            return
        }
        selectedServerID = supported.first?.id
    }

    /// Выбранный сервер; если ID не найден — первый поддерживаемый сервер подписки.
    /// Неподдерживаемый сервер выбранным не бывает.
    var selectedServer: ServerConfiguration? {
        guard let servers = subscription?.servers.filter(\.isSupported) else { return nil }
        return servers.first { $0.id == selectedServerID } ?? servers.first
    }
}
