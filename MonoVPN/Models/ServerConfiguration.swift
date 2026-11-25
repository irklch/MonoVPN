import Foundation

/// Прокси-протоколы, которые Mono VPN умеет разбирать и передавать в sing-box.
enum ProxyProtocol: String, Codable, Hashable, Sendable, CaseIterable {
    /// VLESS (в том числе с REALITY).
    case vless
    /// VMess.
    case vmess
    /// Trojan.
    case trojan
    /// Shadowsocks.
    case shadowsocks

    /// Название протокола для интерфейса. Названия протоколов не переводятся.
    var displayName: String {
        switch self {
        case .vless: "VLESS"
        case .vmess: "VMess"
        case .trojan: "Trojan"
        case .shadowsocks: "Shadowsocks"
        }
    }
}

/// Транспортный уровень сервера в стиле V2Ray.
enum TransportSettings: Codable, Hashable, Sendable {
    /// Обычный TCP без дополнительного транспорта.
    case tcp
    /// WebSocket: путь, заголовок Host и размер early data.
    case webSocket(path: String, host: String?, maxEarlyData: Int?)
    /// gRPC с именем сервиса.
    case grpc(serviceName: String)
    /// HTTP/2: путь и список хостов.
    case http(path: String, hosts: [String])
    /// HTTPUpgrade: путь и заголовок Host.
    case httpUpgrade(path: String, host: String?)

    /// Короткое название транспорта для интерфейса.
    var displayName: String {
        switch self {
        case .tcp: "TCP"
        case .webSocket: "WS"
        case .grpc: "gRPC"
        case .http: "HTTP/2"
        case .httpUpgrade: "HTTPUpgrade"
        }
    }
}

/// Параметры REALITY для VLESS.
struct RealitySettings: Codable, Hashable, Sendable {
    /// Публичный ключ сервера REALITY.
    var publicKey: String
    /// Short ID, по которому сервер узнаёт клиента.
    var shortID: String
}

/// Параметры TLS соединения с сервером.
struct TLSSettings: Codable, Hashable, Sendable {
    /// SNI. `nil` означает «использовать адрес сервера» (поведение sing-box по умолчанию).
    var serverName: String?
    /// Список протоколов ALPN; пустой — не передавать.
    var alpn: [String] = []
    /// Отпечаток uTLS (`chrome`, `safari`, ...). `nil` отключает uTLS.
    var fingerprint: String?
    /// Параметры REALITY; `nil` — обычный TLS.
    var reality: RealitySettings?
}

/// Один сервер из подписки, уже проверенный.
///
/// Содержит секреты (UUID / пароль), поэтому сохраняется только в Keychain.
struct ServerConfiguration: Codable, Hashable, Identifiable, Sendable {
    /// Стабильный идентификатор, полученный из исходного URI; переживает обновления подписки.
    var id: String
    /// Имя сервера для списка (из фрагмента ссылки).
    var name: String
    /// Прокси-протокол сервера.
    var proxyProtocol: ProxyProtocol
    /// Адрес сервера (домен или IP).
    var host: String
    /// Порт сервера.
    var port: Int

    /// ID пользователя VLESS / VMess.
    var uuid: String?
    /// Пароль Trojan / Shadowsocks.
    var password: String?
    /// Шифр Shadowsocks.
    var method: String?
    /// Flow для VLESS (`xtls-rprx-vision`).
    var flow: String?
    /// Security для VMess (`auto`, `aes-128-gcm`, ...).
    var vmessSecurity: String?
    /// alterId для VMess (устаревший параметр, передаётся как есть).
    var vmessAlterID: Int?

    /// Транспорт; по умолчанию TCP.
    var transport: TransportSettings = .tcp
    /// Параметры TLS; `nil` — соединение без TLS.
    var tls: TLSSettings?

    /// Параметры из ссылки, которые sing-box не поддерживает и которые поэтому
    /// не применены. Показываются пользователю, никогда не отбрасываются молча.
    var ignoredParameters: [String] = []

    /// Короткое техническое описание для интерфейса, например «VLESS · REALITY».
    var protocolSummary: String {
        var parts = [proxyProtocol.displayName]
        if transport != .tcp {
            parts.append(transport.displayName)
        }
        if tls?.reality != nil {
            parts.append("REALITY")
        } else if tls != nil {
            parts.append("TLS")
        }
        return parts.joined(separator: " · ")
    }
}
