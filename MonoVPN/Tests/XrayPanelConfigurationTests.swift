import Foundation
@testable import MonoVPN
import Testing

/// Тесты JSON-подписки Xray: адаптация конфигов панели, разбор подписки, подготовка в расширении.
/// Все данные вымышлены (адреса из документационных диапазонов и домены example.*).
struct XrayPanelConfigurationTests {
    // MARK: - Данные

    /// Один сервер VLESS + XHTTP + REALITY в новом «плоском» формате `settings`.
    private func singleConfig(name: String = "🇳🇱 Test", key: String = "pbk-1") -> [String: Any] {
        [
            "remarks": name,
            "log": ["error": "error.log", "access": "access.log", "loglevel": "none"],
            "dns": ["servers": [
                "1.1.1.1",
                ["address": "77.88.8.8", "domains": ["regexp:.*\\.ru$", "geosite:category-ru"]],
                ["address": "77.88.8.1", "domains": ["geosite:yandex"]],
            ]],
            "inbounds": [
                ["tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks",
                 "sniffing": ["enabled": true, "routeOnly": false, "destOverride": ["http", "tls", "quic"]]],
                ["tag": "http", "port": 10809, "listen": "127.0.0.1", "protocol": "http"],
            ],
            "outbounds": [
                ["tag": "proxy", "protocol": "vless",
                 "settings": ["address": "edge.example.com", "port": 8443, "users": [["id": "11111111-2222-4333-8444-555555555555", "encryption": "none"]]],
                 "streamSettings": [
                     "network": "xhttp", "xhttpSettings": ["mode": "packet-up", "host": "", "path": "/x"],
                     "security": "reality",
                     "realitySettings": ["serverName": "sni.example.com", "publicKey": key, "shortId": "ab", "fingerprint": "qq"],
                 ]],
                ["tag": "direct", "protocol": "freedom", "settings": ["domainStrategy": "UseIPv4"]],
                ["tag": "block", "protocol": "blackhole"],
                ["tag": "dns-out", "protocol": "dns"],
            ],
            "routing": ["rules": [
                ["type": "field", "ip": ["77.88.8.8"], "outboundTag": "direct"],
                ["type": "field", "port": 53, "network": "udp", "inboundTag": ["socks", "http"], "outboundTag": "dns-out"],
                ["type": "field", "domain": ["geosite:vk", "geosite:yandex"], "outboundTag": "direct"],
                ["type": "field", "domain": ["domain:example.ru", "geosite:category-ru"], "outboundTag": "direct"],
                ["type": "field", "ip": ["geoip:private"], "outboundTag": "direct"],
                ["type": "field", "network": "tcp,udp", "outboundTag": "proxy"],
            ]],
        ]
    }

    /// Балансировщик из трёх серверов (VLESS и Hysteria) без outbound `dns`.
    private func balancerConfig() -> [String: Any] {
        [
            "remarks": "🇪🇺 Auto",
            "inbounds": [["tag": "socks", "protocol": "socks", "port": 10808]],
            "outbounds": [
                ["tag": "proxy-a", "protocol": "vless", "settings": ["vnext": [["address": "a.example.com", "port": 443, "users": [["id": "x"]]]]],
                 "streamSettings": ["network": "ws", "wsSettings": ["path": "/w"], "security": "tls", "tlsSettings": [:]]],
                ["tag": "proxy-b", "protocol": "vless", "settings": ["address": "198.51.100.7", "port": 443, "users": [["id": "y"]]]],
                ["tag": "proxy-c", "protocol": "hysteria", "settings": ["address": "c.example.com", "port": 443, "version": 2],
                 "streamSettings": ["network": "hysteria", "security": "tls", "tlsSettings": ["serverName": "c.example.com"]]],
                ["tag": "direct", "protocol": "freedom"],
            ],
            "routing": [
                "balancers": [["tag": "proxy-balancer", "selector": ["proxy-"], "strategy": ["type": "leastLoad"]]],
                "rules": [["type": "field", "network": "tcp,udp", "balancerTag": "proxy-balancer"]],
            ],
            "burstObservatory": ["subjectSelector": ["proxy-"]],
        ]
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func data(_ array: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: array)
    }

    // MARK: - Адаптация

    /// Входы панели заменяются TUN с тем же sniffing, правила — на `tun-in`, журнал — наш.
    @Test func replacesInboundsAndLog() throws {
        let adapted = try XrayPanelConfiguration.adapt(singleConfig())
        let root = try decode(adapted.json)
        #expect(root["remarks"] == nil)

        let inbounds = try #require(root["inbounds"] as? [[String: Any]])
        #expect(inbounds.count == 1)
        #expect(inbounds[0]["tag"] as? String == "tun-in")
        #expect(inbounds[0]["protocol"] as? String == "tun")
        #expect((inbounds[0]["sniffing"] as? [String: Any])?["destOverride"] as? [String] == ["http", "tls", "quic"])

        let log = try #require(root["log"] as? [String: Any])
        #expect(log["loglevel"] as? String == "warning")
        #expect(log["access"] as? String == "none")
        #expect(log["error"] == nil)
        #expect((root["env"] as? [String: String])?["xray.tun.fd"] == "-1")

        let rules = try #require((root["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        let dnsRules = rules.filter { $0["outboundTag"] as? String == "dns-out" }
        #expect(dnsRules.count == 1, "the panel's own hijack rule is reused, not duplicated")
        #expect(dnsRules.first?["inboundTag"] as? [String] == ["tun-in"])
    }

    /// Геобазы убираются; правило, оставшееся без условий, удаляется; `geoip:private` — частные сети.
    @Test func stripsGeoReferences() throws {
        let adapted = try XrayPanelConfiguration.adapt(singleConfig())
        #expect(adapted.droppedGeoEntries == ["geosite:category-ru", "geosite:vk", "geosite:yandex"])
        let root = try decode(adapted.json)
        let rules = try #require((root["routing"] as? [String: Any])?["rules"] as? [[String: Any]])

        #expect(rules.count == 5, "the vk/yandex-only rule would match everything without its domains")
        #expect(rules.contains { $0["domain"] as? [String] == ["domain:example.ru"] })
        let privateRule = try #require(rules.first { ($0["ip"] as? [String])?.contains("10.0.0.0/8") == true })
        #expect(privateRule["ip"] as? [String] == XrayConfigurationBuilder.privateNetworks)
        #expect(!adapted.json.contains("geosite:") && !adapted.json.contains("geoip:"))

        let servers = try #require((root["dns"] as? [String: Any])?["servers"] as? [Any])
        #expect(servers.count == 2, "a DNS server left without domains would answer every query")
        #expect((servers[1] as? [String: Any])?["domains"] as? [String] == ["regexp:.*\\.ru$"])
    }

    /// Без outbound `dns` он добавляется в конец, а перехват DNS из TUN — первым правилом.
    @Test func addsDNSHijackWhenMissing() throws {
        let root = try decode(XrayPanelConfiguration.adapt(balancerConfig()).json)
        let outbounds = try #require(root["outbounds"] as? [[String: Any]])
        #expect(outbounds.first?["tag"] as? String == "proxy-a", "the default outbound stays first")
        #expect(outbounds.last?["protocol"] as? String == "dns")
        let rules = try #require((root["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        #expect(rules.first?["inboundTag"] as? [String] == ["tun-in"])
        #expect(rules.first?["outboundTag"] as? String == outbounds.last?["tag"] as? String)
        #expect(root["burstObservatory"] != nil)
        #expect((root["routing"] as? [String: Any])?["balancers"] != nil)
    }

    /// Описание для списка: транспорт и защита одного сервера, число серверов балансировщика.
    @Test func summaries() throws {
        let single = XrayPanelConfiguration.summary(of: singleConfig())
        #expect(single.text == "VLESS · XHTTP · REALITY")
        #expect(single.serverCount == 1)
        #expect(single.host == "edge.example.com")
        #expect(single.port == 8443)

        let balancer = XrayPanelConfiguration.summary(of: balancerConfig())
        #expect(balancer.serverCount == 3)
        #expect(balancer.text.contains("3"))

        var hysteria = balancerConfig()
        hysteria["routing"] = ["rules": [[String: Any]]()]
        hysteria["outbounds"] = [(balancerConfig()["outbounds"] as! [[String: Any]])[2]]
        #expect(XrayPanelConfiguration.summary(of: hysteria).text == "Hysteria")
    }

    @Test func rejectsConfigWithoutOutbounds() {
        #expect(throws: XrayPanelConfiguration.Failure.noOutbounds) {
            try XrayPanelConfiguration.adapt(["remarks": "x"] as [String: Any])
        }
    }

    // MARK: - Разбор подписки

    /// Серверы — по конфигу на элемент; ID зависит от имени, а не от ключей.
    @Test func parsesSubscription() throws {
        let payload = try data([singleConfig(), balancerConfig(), ["remarks": "broken"]])
        #expect(XrayJSONSubscriptionParser.looksLikeJSONSubscription(payload))
        #expect(!XrayJSONSubscriptionParser.looksLikeJSONSubscription(Data("vless://x".utf8)))

        let result = try XrayJSONSubscriptionParser.parse(payload)
        #expect(result.servers.map(\.name) == ["🇳🇱 Test", "🇪🇺 Auto"])
        #expect(result.issues.map(\.name) == ["broken"])
        let first = result.servers[0]
        #expect(first.isSupported)
        #expect(first.panel?.summary == "VLESS · XHTTP · REALITY")
        #expect(first.protocolSummary == "VLESS · XHTTP · REALITY")
        #expect(result.configurations[first.id]?.contains("\"tun-in\"") == true)
        #expect(result.servers[1].panel?.serverCount == 3)

        // Панель сменила ключ: ID тот же (выбор сохраняется), хеш конфига — другой (перезапуск).
        let rotated = try XrayJSONSubscriptionParser.parse(data([singleConfig(key: "pbk-2")]))
        #expect(rotated.servers[0].id == first.id)
        #expect(rotated.servers[0].panel?.configHash != first.panel?.configHash)
    }

    @Test func duplicateNamesGetDistinctIDs() throws {
        let result = try XrayJSONSubscriptionParser.parse(data([singleConfig(name: "A"), singleConfig(name: "A")]))
        #expect(Set(result.servers.map(\.id)).count == 2)
    }

    @Test func jsonURL() throws {
        let base = try #require(URL(string: "https://sub.example.com/sub/token/"))
        #expect(SubscriptionService.jsonURL(for: base).absoluteString == "https://sub.example.com/sub/token/json")
        let query = try #require(URL(string: "https://sub.example.com/sub/token?x=1"))
        #expect(SubscriptionService.jsonURL(for: query).absoluteString == "https://sub.example.com/sub/token/json?x=1")
    }

    /// Конфиги в Keychain не попадают и не теряются при кодировании состояния.
    @Test func panelConfigurationsAreNotEncoded() throws {
        let result = try XrayJSONSubscriptionParser.parse(data([singleConfig()]))
        let subscription = Subscription(
            source: .remote(try #require(URL(string: "https://sub.example.com/s"))),
            servers: result.servers, issues: [], lastUpdated: .now,
            format: .xrayJSON, panelConfigurations: result.configurations
        )
        let encoded = try JSONEncoder().encode(subscription)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("tun-in"))
        let decoded = try JSONDecoder().decode(Subscription.self, from: encoded)
        #expect(decoded.panelConfigurations == nil)
        #expect(decoded.format == .xrayJSON)
        #expect(decoded.servers == subscription.servers)
    }

    @Test func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID().uuidString).json")
        let store = PanelConfigurationStore(url: url)
        try store.save(["a": "{}"])
        #expect(store.configuration(for: "a") == "{}")
        try store.removeAll()
        #expect(store.load().isEmpty)
    }

    // MARK: - Расширение

    /// Все имена серверов собираются; при подстановке IP имя закрепляется в SNI/Host.
    @Test func runtimeResolvesAllServers() throws {
        let json = try XrayPanelConfiguration.adapt(balancerConfig()).json
        #expect(try XrayRuntimeConfiguration.serverHosts(in: json) == ["a.example.com", "c.example.com"])

        let prepared = try decode(XrayRuntimeConfiguration.prepare(
            json, tunFileDescriptor: 5,
            resolvedAddresses: ["a.example.com": "203.0.113.1", "c.example.com": "203.0.113.3"]
        ))
        let outbounds = try #require(prepared["outbounds"] as? [[String: Any]])
        let a = outbounds[0]
        let vnext = try #require(((a["settings"] as? [String: Any])?["vnext"] as? [[String: Any]])?.first)
        #expect(vnext["address"] as? String == "203.0.113.1")
        let aStream = try #require(a["streamSettings"] as? [String: Any])
        #expect((aStream["tlsSettings"] as? [String: Any])?["serverName"] as? String == "a.example.com")
        #expect((aStream["wsSettings"] as? [String: Any])?["host"] as? String == "a.example.com")

        #expect((outbounds[1]["settings"] as? [String: Any])?["address"] as? String == "198.51.100.7")
        let c = outbounds[2]
        #expect((c["settings"] as? [String: Any])?["address"] as? String == "203.0.113.3")
        #expect(((c["streamSettings"] as? [String: Any])?["tlsSettings"] as? [String: Any])?["serverName"] as? String == "c.example.com")
    }

    /// XHTTP без Host: Xray взял бы его из SNI REALITY, поэтому закрепляется SNI, а не адрес.
    @Test func runtimePinsXHTTPHostFromRealitySNI() throws {
        let json = try XrayPanelConfiguration.adapt(singleConfig()).json
        let prepared = try decode(XrayRuntimeConfiguration.prepare(
            json, tunFileDescriptor: 5, resolvedAddresses: ["edge.example.com": "203.0.113.9"]
        ))
        let proxy = try #require((prepared["outbounds"] as? [[String: Any]])?.first)
        #expect((proxy["settings"] as? [String: Any])?["address"] as? String == "203.0.113.9")
        let stream = try #require(proxy["streamSettings"] as? [String: Any])
        #expect((stream["xhttpSettings"] as? [String: Any])?["host"] as? String == "sni.example.com")
        #expect((stream["realitySettings"] as? [String: Any])?["serverName"] as? String == "sni.example.com")
    }
}
