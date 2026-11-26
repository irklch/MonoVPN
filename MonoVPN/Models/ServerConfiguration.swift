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
    /// XHTTP (SplitHTTP) Xray: путь, заголовок Host и режим (`auto`, `packet-up`, `stream-up`, `stream-one`).
    /// Поддерживается только ядром Xray (`VPNCore.supportsXHTTP`).
    case xhttp(path: String, host: String?, mode: String?)

    /// Короткое название транспорта для интерфейса.
    var displayName: String {
        switch self {
        case .tcp: "TCP"
        case .webSocket: "WS"
        case .grpc: "gRPC"
        case .http: "HTTP/2"
        case .httpUpgrade: "HTTPUpgrade"
        case .xhttp: "XHTTP"
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
    /// Плагин Shadowsocks в терминах sing-box (`obfs-local`, `v2ray-plugin`); `nil` — без плагина.
    var shadowsocksPlugin: String?
    /// Параметры плагина Shadowsocks (`obfs=http;obfs-host=...`).
    var shadowsocksPluginOptions: String?

    /// Транспорт; по умолчанию TCP.
    var transport: TransportSettings = .tcp
    /// gRPC `:authority`, если он задан в ссылке и отличается от SNI (только ядро Xray).
    var grpcAuthority: String?
    /// Дополнительные параметры XHTTP (`extra` из ссылки) — JSON-объект как есть (только ядро Xray).
    var xhttpExtra: String?
    /// Параметры TLS; `nil` — соединение без TLS.
    var tls: TLSSettings?

    /// Имена безвредных параметров из ссылки, которые sing-box не поддерживает и которые
    /// поэтому не применены. Показываются только в диагностике импорта (без значений).
    var ignoredParameters: [String] = []

    /// Почему сервер нельзя запустить в подключённом sing-box; `nil` — сервер поддерживается.
    /// Неподдерживаемый сервер показывается в списке неактивным и никогда не выбирается.
    var incompatibility: ProxyLinkError?

    /// Можно ли выбрать сервер и подключиться к нему.
    var isSupported: Bool {
        incompatibility == nil
    }

    /// Короткое техническое описание для интерфейса, например «VLESS · REALITY».
    /// Для неподдерживаемого сервера — только протокол: транспорт и TLS не разобраны.
    var protocolSummary: String {
        var parts = [proxyProtocol.displayName]
        guard isSupported else { return parts[0] }
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
