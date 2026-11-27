import Foundation
@testable import MonoVPN
import Testing

/// Тесты конфигурации Xray-core: генератор, подготовка в расширении, очистка ошибок.
/// Все данные вымышлены (адреса из документационных диапазонов, тестовые UUID и ключ).
struct XrayConfigurationTests {
    /// Сервер VLESS + REALITY с заданным транспортом.
    private func realityServer(_ transport: TransportSettings, host: String = "203.0.113.10", sni: String? = "www.example.com") -> ServerConfiguration {
        var server = ServerConfiguration(id: "t", name: "T", proxyProtocol: .vless, host: host, port: 443, uuid: Fixture.uuid)
        server.transport = transport
        server.tls = TLSSettings(
            serverName: sni,
            fingerprint: "chrome",
            reality: RealitySettings(publicKey: Fixture.realityKey, shortID: "6ba85179e30d4fc2")
        )
        return server
    }

    /// Декодирует JSON в словарь.
    private func decode(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// Outbound прокси и его `streamSettings` из полной конфигурации.
    private func proxy(_ config: [String: Any]) throws -> (outbound: [String: Any], stream: [String: Any]) {
        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        let outbound = try #require(outbounds.first)
        return (outbound, try #require(outbound["streamSettings"] as? [String: Any]))
    }

    /// Общая часть: TUN по fd, перехват DNS, LAN напрямую, без журнала доступа.
    @Test func tunDNSAndRouting() throws {
        var server = realityServer(.tcp)
        server.flow = "xtls-rprx-vision"
        let config = try decode(XrayConfigurationBuilder.build(for: server))

        let env = try #require(config["env"] as? [String: String])
        #expect(env["xray.tun.fd"] == XrayTunnelLayout.tunFdPlaceholder)
        let log = try #require(config["log"] as? [String: Any])
        #expect(log["access"] as? String == "none")

        let inbound = try #require((config["inbounds"] as? [[String: Any]])?.first)
        #expect(inbound["protocol"] as? String == "tun")
        #expect(inbound["tag"] as? String == XrayTunnelLayout.tunInboundTag)
        #expect((inbound["settings"] as? [String: Any])?["mtu"] as? Int == XrayTunnelLayout.mtu)

        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        #expect(outbounds.map { $0["tag"] as? String } == ["proxy", "direct", "dns-out"])
        #expect(outbounds.map { $0["protocol"] as? String } == ["vless", "freedom", "dns"])

        let dns = try #require(config["dns"] as? [String: Any])
        #expect(dns["servers"] as? [String] == ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query", "8.8.8.8"])

        let rules = try #require((config["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(rules.first?["port"] as? String == "53")
        #expect(rules.first?["outboundTag"] as? String == "dns-out")
        #expect((rules.last?["ip"] as? [String])?.contains("192.168.0.0/16") == true)
        #expect(rules.last?["outboundTag"] as? String == "direct")
    }

    /// VLESS + TCP + REALITY + Vision.
    @Test func vlessTCPReality() throws {
        var server = realityServer(.tcp)
        server.flow = "xtls-rprx-vision"
        let (outbound, stream) = try proxy(decode(XrayConfigurationBuilder.build(for: server)))

        let settings = try #require(outbound["settings"] as? [String: Any])
        let vnext = try #require((settings["vnext"] as? [[String: Any]])?.first)
        #expect(vnext["address"] as? String == "203.0.113.10")
        #expect(vnext["port"] as? Int == 443)
        let user = try #require((vnext["users"] as? [[String: Any]])?.first)
        #expect(user["id"] as? String == Fixture.uuid)
        #expect(user["encryption"] as? String == "none")
        #expect(user["flow"] as? String == "xtls-rprx-vision")

        #expect(stream["network"] as? String == "raw")
        #expect(stream["security"] as? String == "reality")
        let reality = try #require(stream["realitySettings"] as? [String: Any])
        #expect(reality["serverName"] as? String == "www.example.com")
        #expect(reality["publicKey"] as? String == Fixture.realityKey)
        #expect(reality["shortId"] as? String == "6ba85179e30d4fc2")
        #expect(reality["fingerprint"] as? String == "chrome")
    }

    /// VLESS + gRPC + REALITY: authority и SNI независимы.
    @Test func vlessGRPCRealityWithAuthority() throws {
        var server = realityServer(.grpc(serviceName: "svc"), sni: "sni.example.com")
        server.grpcAuthority = "front.example.com"
        let (_, stream) = try proxy(decode(XrayConfigurationBuilder.build(for: server)))
        #expect(stream["network"] as? String == "grpc")
        let grpc = try #require(stream["grpcSettings"] as? [String: Any])
        #expect(grpc["serviceName"] as? String == "svc")
        #expect(grpc["authority"] as? String == "front.example.com")
        #expect(grpc["multiMode"] as? Bool == false)
        #expect((stream["realitySettings"] as? [String: Any])?["serverName"] as? String == "sni.example.com")
    }

    /// VLESS + XHTTP: путь, Host, режим и `extra`; SNI берётся из имени сервера, если в ссылке его нет.
    @Test func vlessXHTTP() throws {
        var server = realityServer(.xhttp(path: "/x", host: nil, mode: nil), host: "edge.example.com", sni: nil)
        server.xhttpExtra = #"{"xPaddingBytes":"100-1000"}"#
        let (_, stream) = try proxy(decode(XrayConfigurationBuilder.build(for: server)))
        #expect(stream["network"] as? String == "xhttp")
        let xhttp = try #require(stream["xhttpSettings"] as? [String: Any])
        #expect(xhttp["path"] as? String == "/x")
        #expect(xhttp["host"] as? String == "edge.example.com", "Host is explicit: the extension may swap the address for an IP")
        #expect(xhttp["mode"] as? String == "auto")
        #expect((xhttp["extra"] as? [String: Any])?["xPaddingBytes"] as? String == "100-1000")
        #expect((stream["realitySettings"] as? [String: Any])?["serverName"] as? String == "edge.example.com")
    }

    /// `fm` из ссылки (фрагментация TLS ClientHello) попадает в `streamSettings.finalmask` как есть.
    @Test func finalMaskFromLink() throws {
        let mask = #"{"tcp":[{"type":"fragment","settings":{"length":"10-20","packets":"tlshello","interval":"10-20"}}]}"#
        let encoded = try #require(mask.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let link = "vless://\(Fixture.uuid)@203.0.113.10:443?security=reality&sni=www.example.com&fp=qq"
            + "&pbk=\(Fixture.realityKey)&sid=6ba85179e30d4fc2&type=tcp&flow=xtls-rprx-vision&spx=%2F&fm=\(encoded)#NL"
        let server = try ProxyLinkParser.parse(link)
        #expect(server.isSupported)
        #expect(server.finalMask == mask)
        #expect(!server.ignoredParameters.contains("fm"))

        let (_, stream) = try proxy(decode(XrayConfigurationBuilder.build(for: server)))
        let tcp = try #require(((stream["finalmask"] as? [String: Any])?["tcp"] as? [[String: Any]])?.first)
        #expect(tcp["type"] as? String == "fragment")
        #expect((tcp["settings"] as? [String: Any])?["packets"] as? String == "tlshello")
        #expect((stream["realitySettings"] as? [String: Any])?["fingerprint"] as? String == "qq")

        // Не JSON-объект — параметр не применяется, сервер остаётся доступным.
        let broken = try ProxyLinkParser.parse(link.replacingOccurrences(of: "fm=\(encoded)", with: "fm=oops"))
        #expect(broken.isSupported)
        #expect(broken.finalMask == nil)
        #expect(broken.ignoredParameters.contains("fm"))
    }

    /// WebSocket с early data и TLS; HTTP/2 и плагины Shadowsocks в Xray не поддерживаются.
    @Test func otherTransportsAndLimitations() throws {
        var ws = ServerConfiguration(id: "w", name: "W", proxyProtocol: .vless, host: "example.org", port: 443, uuid: Fixture.uuid)
        ws.transport = .webSocket(path: "/ws", host: nil, maxEarlyData: 2048)
        ws.tls = TLSSettings(serverName: "cdn.example.org", alpn: ["h2"], fingerprint: nil)
        let (_, stream) = try proxy(decode(XrayConfigurationBuilder.build(for: ws)))
        #expect((stream["wsSettings"] as? [String: Any])?["path"] as? String == "/ws?ed=2048")
        #expect((stream["wsSettings"] as? [String: Any])?["host"] as? String == "example.org")
        #expect((stream["tlsSettings"] as? [String: Any])?["alpn"] as? [String] == ["h2"])

        var h2 = ws
        h2.transport = .http(path: "/", hosts: [])
        #expect(throws: ProxyLinkError.unsupportedTransport("http")) {
            try XrayConfigurationBuilder.build(for: h2)
        }
        var ss = ServerConfiguration(id: "s", name: "S", proxyProtocol: .shadowsocks, host: "198.51.100.7", port: 8388, password: "p", method: "aes-256-gcm")
        ss.shadowsocksPlugin = "obfs-local"
        #expect(throws: ProxyLinkError.unsupportedShadowsocksPlugin("obfs-local")) {
            try XrayConfigurationBuilder.build(for: ss)
        }
        var unsupported = ws
        unsupported.incompatibility = .unsupportedTransport("quic")
        #expect(throws: ProxyLinkError.unsupportedTransport("quic")) {
            try XrayConfigurationBuilder.build(for: unsupported)
        }
    }

    /// Расширение подставляет дескриптор TUN и заранее разрешённый IP; остальное не меняется.
    @Test func runtimePreparation() throws {
        let server = realityServer(.xhttp(path: "/x", host: nil, mode: nil), host: "edge.example.com", sni: nil)
        let template = try XrayConfigurationBuilder.build(for: server)
        #expect(try XrayRuntimeConfiguration.serverHosts(in: template) == ["edge.example.com"])

        let prepared = try decode(XrayRuntimeConfiguration.prepare(template, tunFileDescriptor: 9, resolvedAddresses: ["edge.example.com": "198.51.100.20"]))
        #expect((prepared["env"] as? [String: String])?["xray.tun.fd"] == "9")
        let (outbound, stream) = try proxy(prepared)
        let vnext = try #require(((outbound["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first)
        #expect(vnext["address"] as? String == "198.51.100.20")
        #expect((stream["realitySettings"] as? [String: Any])?["serverName"] as? String == "edge.example.com")
        #expect((stream["xhttpSettings"] as? [String: Any])?["host"] as? String == "edge.example.com")

        let unchanged = try decode(XrayRuntimeConfiguration.prepare(template, tunFileDescriptor: 9, resolvedAddresses: [:]))
        let address = try #require(((try proxy(unchanged).outbound["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first?["address"])
        #expect(address as? String == "edge.example.com")

        #expect(throws: XrayRuntimeConfiguration.Failure.notAnObject) {
            try XrayRuntimeConfiguration.prepare("[]", tunFileDescriptor: 1, resolvedAddresses: [:])
        }
    }

    /// Путь журнала ошибок попадает в `log.error`, уровень и отключённый журнал доступа сохраняются.
    @Test func runtimePreparationSetsErrorLog() throws {
        let server = realityServer(.tcp)
        let template = try XrayConfigurationBuilder.build(for: server)
        let prepared = try decode(XrayRuntimeConfiguration.prepare(
            template, tunFileDescriptor: 3, resolvedAddresses: [:], errorLogPath: "/tmp/xray-error.log"
        ))
        let log = try #require(prepared["log"] as? [String: Any])
        #expect(log["error"] as? String == "/tmp/xray-error.log")
        #expect(log["loglevel"] as? String == "warning")
        #expect(log["access"] as? String == "none")
    }

    /// Подробный журнал меняет только уровень, путь журнала сохраняется.
    @Test func runtimePreparationSetsVerboseLevel() throws {
        let template = try XrayConfigurationBuilder.build(for: realityServer(.tcp))
        let prepared = try decode(XrayRuntimeConfiguration.prepare(
            template, tunFileDescriptor: 3, resolvedAddresses: [:], errorLogPath: "/tmp/e.log", logLevel: "info"
        ))
        let log = try #require(prepared["log"] as? [String: Any])
        #expect(log["loglevel"] as? String == "info")
        #expect(log["error"] as? String == "/tmp/e.log")
        #expect(log["access"] as? String == "none")
    }

    /// Строки журнала Xray: без даты и секретов, пути модулей сохраняются, новые — первыми.
    @Test func xrayErrorLogLines() {
        let text = """
        partial line
        2026/11/27 16:29:01.123456 [Warning] [1] app/dispatcher: failed to process outbound traffic > proxy/vless/outbound: failed to find an available destination > dial tcp 203.0.113.10:443: i/o timeout
        2026/11/27 16:29:02.000001 [Warning] [2] transport/internet/reality: key \(Fixture.realityKey) for \(Fixture.uuid)
        """
        let lines = XrayErrorLog.lines(from: text, droppingPartialFirstLine: true)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("16:29:02 [Warning]"))
        #expect(lines[0].contains("transport/internet/reality"))
        #expect(!lines[0].contains(Fixture.realityKey))
        #expect(!lines[0].contains(Fixture.uuid))
        #expect(lines[1].contains("proxy/vless/outbound"))
        #expect(lines[1].contains("i/o timeout"))
        #expect(!lines[1].contains("203.0.113.10"))
    }

    /// Текст ошибки ядра очищается от UUID, ключей, URL и IP-адресов.
    @Test func errorSanitizer() {
        let raw = "failed to dial 203.0.113.10:443 for \(Fixture.uuid): invalid \"password\": \(Fixture.realityKey) https://sub.example.com/token/abc"
        let clean = TunnelErrorSanitizer.sanitize(raw)
        for secret in [Fixture.uuid, Fixture.realityKey, "203.0.113.10", "sub.example.com", "token"] {
            #expect(!clean.contains(secret), "leaked: \(secret)")
        }
        #expect(clean.hasPrefix("failed to dial"))
        #expect(TunnelErrorSanitizer.sanitize(String(repeating: "a ", count: 400)).count <= TunnelErrorSanitizer.maxLength + 1)
    }

    /// Разбор ссылок в сборке с Xray: XHTTP, независимый authority, Vision на не-TCP отбрасывается.
    @Test(.enabled(if: VPNCore.current == .xray)) func parsingWithXrayCore() throws {
        let xhttp = try ProxyLinkParser.parse(
            "vless://\(Fixture.uuid)@edge.example.com:443?security=reality&pbk=\(Fixture.realityKey)&sni=a.example.com&type=xhttp&path=%2Fx&mode=packet-up&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#X"
        )
        #expect(xhttp.isSupported)
        #expect(xhttp.transport == .xhttp(path: "/x", host: nil, mode: "packet-up"))
        #expect(xhttp.xhttpExtra == #"{"xPaddingBytes":"100-1000"}"#)
        #expect(xhttp.protocolSummary == "VLESS · XHTTP · REALITY")

        let grpcVision = try ProxyLinkParser.parse(
            "vless://\(Fixture.uuid)@203.0.113.5:443?security=reality&pbk=\(Fixture.realityKey)&sni=s.example.com&type=grpc&serviceName=svc&authority=a.example.com&flow=xtls-rprx-vision#G"
        )
        #expect(grpcVision.isSupported)
        #expect(grpcVision.grpcAuthority == "a.example.com")
        #expect(grpcVision.flow == nil)
        #expect(grpcVision.ignoredParameters.contains("flow"))

        let h2 = try ProxyLinkParser.parse("vless://\(Fixture.uuid)@example.com:443?security=tls&type=http#H")
        #expect(h2.incompatibility == .unsupportedTransport("http"))
        let aes192 = try ProxyLinkParser.parse("ss://" + Data("aes-192-gcm:pass".utf8).base64EncodedString() + "@198.51.100.7:8388")
        #expect(aes192.incompatibility == .unsupportedShadowsocksMethod("aes-192-gcm"))

        // Сгенерированная конфигурация для разобранного XHTTP-сервера.
        _ = try TunnelConfigurationBuilder.build(for: xhttp)
    }
}
