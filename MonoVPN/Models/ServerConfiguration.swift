import Foundation

/// Proxy protocols Mono VPN can parse and pass to sing-box.
enum ProxyProtocol: String, Codable, Hashable, Sendable, CaseIterable {
    case vless
    case vmess
    case trojan
    case shadowsocks

    /// Protocol name as shown in the UI. Protocol names are not translated.
    var displayName: String {
        switch self {
        case .vless: "VLESS"
        case .vmess: "VMess"
        case .trojan: "Trojan"
        case .shadowsocks: "Shadowsocks"
        }
    }
}

/// Transport layer of a V2Ray-style server.
enum TransportSettings: Codable, Hashable, Sendable {
    case tcp
    case webSocket(path: String, host: String?, maxEarlyData: Int?)
    case grpc(serviceName: String)
    case http(path: String, hosts: [String])
    case httpUpgrade(path: String, host: String?)

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

struct RealitySettings: Codable, Hashable, Sendable {
    var publicKey: String
    var shortID: String
}

struct TLSSettings: Codable, Hashable, Sendable {
    /// SNI. `nil` means "use the server address" (sing-box default).
    var serverName: String?
    var alpn: [String] = []
    /// uTLS fingerprint (`chrome`, `safari`, ...). `nil` disables uTLS.
    var fingerprint: String?
    var reality: RealitySettings?
}

/// One server from a subscription, already validated.
///
/// Contains secrets (UUID / password) and therefore is only persisted in the Keychain.
struct ServerConfiguration: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier derived from the source URI, survives subscription refreshes.
    var id: String
    var name: String
    var proxyProtocol: ProxyProtocol
    var host: String
    var port: Int

    /// VLESS / VMess user ID.
    var uuid: String?
    /// Trojan / Shadowsocks password.
    var password: String?
    /// Shadowsocks cipher.
    var method: String?
    /// VLESS flow (`xtls-rprx-vision`).
    var flow: String?
    /// VMess security (`auto`, `aes-128-gcm`, ...).
    var vmessSecurity: String?
    var vmessAlterID: Int?

    var transport: TransportSettings = .tcp
    var tls: TLSSettings?

    /// Parameters present in the link that sing-box does not support and that were
    /// therefore not applied. Shown to the user, never dropped silently.
    var ignoredParameters: [String] = []

    /// Short technical description for the UI, e.g. "VLESS · REALITY".
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
