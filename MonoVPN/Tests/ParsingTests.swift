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

    /// Испорченные ссылки отклоняются с конкретной ошибкой.
    @Test func rejectsInvalidLinks() {
        #expect(throws: ProxyLinkError.invalidUUID) {
            try ProxyLinkParser.parse("vless://not-a-uuid@example.com:443?security=tls")
        }
        #expect(throws: ProxyLinkError.invalidPort) {
            try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:70000")
        }
        #expect(throws: ProxyLinkError.invalidRealityPublicKey) {
            try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?security=reality&pbk=short")
        }
    }

    /// Корректная ссылка с возможностью, которой нет в ядре, даёт неподдерживаемый сервер,
    /// а не ошибку; транспорт не подменяется.
    @Test func unsupportedTransportKeepsServer() throws {
        // QUIC и mKCP не поддерживает ни одно ядро; XHTTP — только Xray.
        let unsupported = ["quic", "kcp"] + (VPNCore.current.supportsXHTTP ? [] : ["xhttp", "splithttp"])
        for type in unsupported {
            let server = try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?security=tls&type=\(type)#X")
            #expect(server.name == "X")
            #expect(!server.isSupported)
            #expect(server.incompatibility == .unsupportedTransport(type))
            #expect(server.transport == .tcp, "partial settings are not kept")
            #expect(server.tls == nil)
            #expect(server.protocolSummary == "VLESS")
            #expect(throws: ProxyLinkError.unsupportedTransport(type)) {
                try VPNConfigurationBuilder.outbound(for: server)
            }
        }
        let vision = try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?flow=xtls-rprx-vision")
        #expect(vision.incompatibility == .flowRequiresTLS)
    }

    /// `headerType`: отсутствует, пустой или `none` — обычный TCP; `http` — ограничение ядра.
    @Test func tcpHeaderType() throws {
        let base = "vless://\(Fixture.uuid)@example.com:443?security=tls&type=tcp"
        for suffix in ["", "&headerType=", "&headerType=none", "&headerType=NONE"] {
            let server = try ProxyLinkParser.parse(base + suffix)
            #expect(server.isSupported, "suffix: \(suffix)")
            #expect(server.transport == .tcp)
            #expect(server.ignoredParameters.isEmpty)
        }
        // Пустой type тоже означает TCP.
        #expect(try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?type=&headerType=").isSupported)
        // VMess: пустое поле type в JSON.
        let vmessJSON = #"{"v":"2","ps":"VM","add":"example.com","port":443,"id":"\#(Fixture.uuid)","net":"tcp","type":""}"#
        #expect(try ProxyLinkParser.parse("vmess://" + Data(vmessJSON.utf8).base64EncodedString()).isSupported)

        let http = try ProxyLinkParser.parse(base + "&headerType=http&host=example.com")
        #expect(http.incompatibility == .unsupportedHeaderType("http"))
    }

    /// gRPC: authority, совпадающий с SNI, применяется; отличающийся — ограничение ядра.
    @Test func grpcAuthority() throws {
        let base = "vless://\(Fixture.uuid)@203.0.113.5:443?security=tls&sni=front.example.com&type=grpc&serviceName=svc"
        let plain = try ProxyLinkParser.parse(base)
        #expect(plain.transport == .grpc(serviceName: "svc"))
        #expect(plain.isSupported)

        for authority in ["front.example.com", "FRONT.example.com:443", ""] {
            let server = try ProxyLinkParser.parse(base + "&authority=\(authority)")
            #expect(server.isSupported, "authority: \(authority)")
            #expect(server.ignoredParameters.isEmpty)
        }
        let other = try ProxyLinkParser.parse(base + "&authority=other.example.com")
        if VPNCore.current.supportsIndependentGRPCAuthority {
            // Xray передаёт :authority независимо от SNI.
            #expect(other.isSupported)
            #expect(other.grpcAuthority == "other.example.com")
            #expect(other.tls?.serverName == "front.example.com")
        } else {
            #expect(other.incompatibility == .unsupportedGRPCAuthority("other.example.com"))
        }

        // Без SNI authority сравнивается с адресом сервера.
        let noSNI = try ProxyLinkParser.parse("trojan://p@grpc.example.com:443?type=grpc&serviceName=s&authority=grpc.example.com")
        #expect(noSNI.isSupported)
        // Пустой serviceName берётся из path.
        let fromPath = try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?security=tls&type=grpc&serviceName=&path=%2Fsvc2")
        #expect(fromPath.transport == .grpc(serviceName: "svc2"))
        // VMess: authority из JSON.
        let vmessJSON = #"{"v":"2","ps":"G","add":"example.com","port":"443","id":"\#(Fixture.uuid)","net":"grpc","path":"s","tls":"tls","sni":"a.example.com","authority":"b.example.com"}"#
        let vmess = try ProxyLinkParser.parse("vmess://" + Data(vmessJSON.utf8).base64EncodedString())
        if VPNCore.current.supportsIndependentGRPCAuthority {
            #expect(vmess.grpcAuthority == "b.example.com")
        } else {
            #expect(vmess.incompatibility == .unsupportedGRPCAuthority("b.example.com"))
        }
    }

    /// Плагины Shadowsocks, встроенные в sing-box, применяются; остальные — ограничение ядра.
    @Test func shadowsocksPlugins() throws {
        let base = "ss://" + Data("aes-256-gcm:pass".utf8).base64EncodedString() + "@198.51.100.7:8388"
        let obfs = try ProxyLinkParser.parse(base + "?plugin=simple-obfs%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#O")
        guard VPNCore.current.supportsShadowsocksPlugins else {
            // В Xray-core нет SIP003-плагинов.
            #expect(obfs.incompatibility == .unsupportedShadowsocksPlugin("simple-obfs"))
            return
        }
        #expect(obfs.isSupported)
        #expect(obfs.shadowsocksPlugin == "obfs-local")
        #expect(obfs.shadowsocksPluginOptions == "obfs=http;obfs-host=example.com")
        let outbound = try VPNConfigurationBuilder.outbound(for: obfs)
        #expect(outbound["plugin"] as? String == "obfs-local")
        #expect(outbound["plugin_opts"] as? String == "obfs=http;obfs-host=example.com")

        let quic = try ProxyLinkParser.parse(base + "?plugin=v2ray-plugin%3Bmode%3Dquic")
        #expect(!quic.isSupported)
        let kcp = try ProxyLinkParser.parse(base + "?plugin=kcptun")
        #expect(kcp.incompatibility == .unsupportedShadowsocksPlugin("kcptun"))
        let method = try ProxyLinkParser.parse("ss://" + Data("rc4-md5:pass".utf8).base64EncodedString() + "@198.51.100.7:8388")
        #expect(method.incompatibility == .unsupportedShadowsocksMethod("rc4-md5"))
    }

    /// Неприменённые параметры попадают в `ignoredParameters` — только имена, без значений.
    @Test func reportsIgnoredParameters() throws {
        let server = try ProxyLinkParser.parse(
            "vless://\(Fixture.uuid)@example.com:443?security=tls&allowInsecure=1&foo=secret-token#X"
        )
        // Проверка сертификата никогда не отключается; вместо этого параметр попадает в диагностику.
        #expect(server.ignoredParameters == ["allowInsecure", "foo"])
        #expect(!server.ignoredParameters.joined().contains("secret-token"))
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

    /// Смешанная подписка: все распознанные серверы в списке, неподдерживаемые выбрать нельзя,
    /// битые записи — только в `issues`; диагностика не раскрывает секреты.
    @Test func mixedSubscription() throws {
        let xhttp = "vless://\(Fixture.uuid)@example.com:443?security=reality&pbk=\(Fixture.realityKey)&sni=a.example.com&type=quic&path=%2Fx#XHTTP"
        let headerHTTP = "vmess://" + Data(#"{"ps":"HTTP","add":"example.com","port":"80","id":"\#(Fixture.uuid)","net":"tcp","type":"http"}"#.utf8).base64EncodedString()
        let emptyHeader = "vless://\(Fixture.uuid)@example.com:443?security=tls&type=tcp&headerType=#Empty"
        let broken = "vless://not-a-uuid@example.com:443#Broken"
        let body = [xhttp, Fixture.vlessReality, headerHTTP, emptyHeader, broken, "hysteria2://x@example.com:443#H2"].joined(separator: "\n")

        let result = try SubscriptionParser.parse(body)
        #expect(result.servers.map(\.name) == ["XHTTP", "Test Reality", "HTTP", "Empty"])
        #expect(result.servers.map(\.isSupported) == [false, true, false, true])
        #expect(result.issues.map(\.name) == ["Broken", "H2"])

        var state = AppState()
        let subscription = Subscription(source: .link(xhttp), servers: result.servers, issues: result.issues, lastUpdated: .now)
        state.replaceSubscription(with: subscription)
        #expect(state.selectedServer?.name == "Test Reality", "first supported server is selected")
        state.selectedServerID = result.servers[0].id
        #expect(state.selectedServer?.name == "Test Reality", "unsupported server is never selected")

        let entries = ImportDiagnostics.entries(for: subscription)
        #expect(entries.filter { $0.kind == .unsupported }.count == 2)
        #expect(entries.filter { $0.kind == .skipped }.count == 2)
        let text = entries.map { "\($0.name ?? "") \($0.detail)" }.joined(separator: "\n")
        #expect(!text.contains(Fixture.uuid))
        #expect(!text.contains(Fixture.realityKey))
    }

    /// Большая подписка импортируется целиком: ограничения количества нет, дубликаты убираются.
    @Test func largeSubscription() throws {
        let links = (0..<600).map { index in
            index.isMultiple(of: 3)
                ? "vless://\(Fixture.uuid)@example.com:\(1000 + index)?security=tls&type=quic#S\(index)"
                : "vless://\(Fixture.uuid)@example.com:\(1000 + index)?security=tls&type=tcp&headerType=#S\(index)"
        }
        let body = Data((links + links.prefix(50)).joined(separator: "\n").utf8).base64EncodedString()
        let result = try SubscriptionParser.parse(body)
        #expect(result.servers.count == 600)
        #expect(result.servers.filter(\.isSupported).count == 400)
        #expect(result.issues.isEmpty)
    }

    /// Подписка только из неподдерживаемых серверов импортируется, но сервер не выбирается.
    @Test func onlyUnsupportedServers() throws {
        let result = try SubscriptionParser.parse("vless://\(Fixture.uuid)@example.com:443?type=quic#X")
        #expect(result.servers.count == 1)
        var state = AppState()
        state.replaceSubscription(with: Subscription(source: .link("x"), servers: result.servers, issues: [], lastUpdated: .now))
        #expect(state.selectedServer == nil)
        #expect(state.selectedServerID == nil)
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
