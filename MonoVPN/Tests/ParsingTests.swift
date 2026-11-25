import Foundation
@testable import MonoVPN
import Testing

/// Тестовые данные. Ни один из них не является настоящим сервером или учётными данными.
enum Fixture {
    /// Тестовый UUID пользователя.
    static let uuid = "11111111-2222-4333-8444-555555555555"
    /// Пример ключа из документации sing-box.
    static let realityKey = "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0"

    /// Ссылка VLESS + REALITY + Vision.
    static let vlessReality = "vless://\(uuid)@203.0.113.10:443?encryption=none&security=reality&sni=www.example.com&fp=chrome&pbk=\(realityKey)&sid=6ba85179e30d4fc2&type=tcp&flow=xtls-rprx-vision#Test%20Reality"
    /// Ссылка VLESS через WebSocket с TLS, early data и ALPN.
    static let vlessWebSocketTLS = "vless://\(uuid)@example.org:8443?security=tls&sni=cdn.example.org&type=ws&host=cdn.example.org&path=%2Fws%3Fed%3D2048&alpn=h2,http/1.1#WS"
    /// Ссылка Trojan.
    static let trojan = "trojan://secret-password@example.net:443?sni=example.net#Trojan"
    /// Ссылка Shadowsocks в формате SIP002 (userinfo в Base64).
    static let shadowsocks = "ss://" + Data("aes-256-gcm:pass".utf8).base64EncodedString() + "@198.51.100.7:8388#SS"
}

/// Тесты разбора отдельных прокси-ссылок.
struct ProxyLinkParserTests {
    /// VLESS + REALITY: все поля разобраны, лишних параметров нет.
    @Test func vlessReality() throws {
        let server = try ProxyLinkParser.parse(Fixture.vlessReality)
        #expect(server.proxyProtocol == .vless)
        #expect(server.name == "Test Reality")
        #expect(server.host == "203.0.113.10")
        #expect(server.port == 443)
        #expect(server.uuid == Fixture.uuid)
        #expect(server.flow == "xtls-rprx-vision")
        #expect(server.transport == .tcp)
        #expect(server.tls?.serverName == "www.example.com")
        #expect(server.tls?.fingerprint == "chrome")
        #expect(server.tls?.reality == RealitySettings(publicKey: Fixture.realityKey, shortID: "6ba85179e30d4fc2"))
        #expect(server.ignoredParameters.isEmpty)
        #expect(server.protocolSummary == "VLESS · REALITY")
    }

    /// VLESS через WebSocket с TLS: путь, early data, SNI и ALPN.
    @Test func vlessWebSocketTLS() throws {
        let server = try ProxyLinkParser.parse(Fixture.vlessWebSocketTLS)
        #expect(server.transport == .webSocket(path: "/ws", host: "cdn.example.org", maxEarlyData: 2048))
        #expect(server.tls?.serverName == "cdn.example.org")
        #expect(server.tls?.alpn == ["h2", "http/1.1"])
        #expect(server.tls?.reality == nil)
    }

    /// Trojan (TLS по умолчанию), Shadowsocks и VMess в формате v2rayN.
    @Test func otherProtocols() throws {
        let trojan = try ProxyLinkParser.parse(Fixture.trojan)
        #expect(trojan.proxyProtocol == .trojan)
        #expect(trojan.password == "secret-password")
        #expect(trojan.tls != nil, "Trojan defaults to TLS")

        let ss = try ProxyLinkParser.parse(Fixture.shadowsocks)
        #expect(ss.proxyProtocol == .shadowsocks)
        #expect(ss.method == "aes-256-gcm")
        #expect(ss.password == "pass")

        let vmessJSON = #"{"v":"2","ps":"VM","add":"example.com","port":"443","id":"\#(Fixture.uuid)","aid":"0","net":"ws","path":"/v","host":"example.com","tls":"tls"}"#
        let vmess = try ProxyLinkParser.parse("vmess://" + Data(vmessJSON.utf8).base64EncodedString())
        #expect(vmess.proxyProtocol == .vmess)
        #expect(vmess.name == "VM")
        #expect(vmess.transport == .webSocket(path: "/v", host: "example.com", maxEarlyData: nil))
    }

    /// Некорректные и неподдерживаемые ссылки отклоняются с конкретной ошибкой.
    @Test func rejectsInvalidOrUnsupportedLinks() {
        #expect(throws: ProxyLinkError.invalidUUID) {
            try ProxyLinkParser.parse("vless://not-a-uuid@example.com:443?security=tls")
        }
        #expect(throws: ProxyLinkError.invalidPort) {
            try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:70000")
        }
        #expect(throws: ProxyLinkError.unsupportedTransport("xhttp")) {
            try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?security=tls&type=xhttp")
        }
        #expect(throws: ProxyLinkError.invalidRealityPublicKey) {
            try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?security=reality&pbk=short")
        }
        #expect(throws: ProxyLinkError.flowRequiresTLS) {
            try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?flow=xtls-rprx-vision")
        }
    }

    /// Неприменённые параметры попадают в `ignoredParameters`, а не теряются молча.
    @Test func reportsIgnoredParameters() throws {
        let server = try ProxyLinkParser.parse(
            "vless://\(Fixture.uuid)@example.com:443?security=tls&allowInsecure=1&foo=bar#X"
        )
        // Проверка сертификата никогда не отключается; вместо этого параметр показывается пользователю.
        #expect(server.ignoredParameters.contains("allowInsecure=1"))
        #expect(server.ignoredParameters.contains("foo=bar"))
    }
}

/// Тесты разбора тела подписки и проверки ввода.
struct SubscriptionParserTests {
    /// Список в Base64: поддерживаемые серверы приняты, неподдерживаемая схема попала в `issues`.
    @Test func base64List() throws {
        let body = [Fixture.vlessReality, Fixture.trojan, "hysteria2://x@example.com:443#H2"].joined(separator: "\n")
        let result = try SubscriptionParser.parse(Data(Data(body.utf8).base64EncodedString().utf8))
        #expect(result.servers.map(\.proxyProtocol) == [.vless, .trojan])
        #expect(result.issues.count == 1)
        #expect(result.issues.first?.name == "H2")
    }

    /// Простой список: пустые строки и комментарии пропускаются, дубликаты убираются.
    @Test func plainListDeduplicates() throws {
        let body = "\n\(Fixture.vlessWebSocketTLS)\r\n\(Fixture.vlessWebSocketTLS)\n# comment\n"
        let result = try SubscriptionParser.parse(body)
        #expect(result.servers.count == 1)
    }

    /// Clash YAML, JSON, пустое тело и подписка без рабочих серверов отклоняются.
    @Test func rejectsUnsupportedFormats() {
        #expect(throws: SubscriptionParseError.unsupportedFormat("Clash YAML")) {
            try SubscriptionParser.parse("proxies:\n  - name: a\n")
        }
        #expect(throws: SubscriptionParseError.unsupportedFormat("JSON")) {
            try SubscriptionParser.parse(#"{"outbounds":[]}"#)
        }
        #expect(throws: SubscriptionParseError.empty) {
            try SubscriptionParser.parse("  \n ")
        }
        #expect(throws: (any Error).self) {
            try SubscriptionParser.parse("vless://broken@example.com:443?security=reality")
        }
    }

    /// Проверка ввода: HTTPS-URL, одиночная ссылка, запрет `http://` и пустого ввода.
    @Test func inputValidation() throws {
        let url = try #require(URL(string: "https://example.com/sub/token"))
        #expect(try SubscriptionService.source(from: " https://example.com/sub/token ") == .remote(url))
        #expect(try SubscriptionService.source(from: Fixture.trojan) == .link(Fixture.trojan))
        #expect(throws: SubscriptionError.insecureURL) {
            try SubscriptionService.source(from: "http://example.com/sub")
        }
        #expect(throws: SubscriptionError.emptyInput) {
            try SubscriptionService.source(from: "   ")
        }
    }
}
