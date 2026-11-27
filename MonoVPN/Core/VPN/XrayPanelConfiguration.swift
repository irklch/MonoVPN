import Foundation

/// Готовые конфиги Xray из JSON-подписки панели (Remnawave и подобных, `<подписка>/json`).
///
/// Панель отдаёт клиентам вроде Streisand полный конфиг Xray на каждый сервер: свои DNS,
/// маршруты (часть сайтов напрямую), балансировщики `leastLoad` с десятками серверов,
/// `burstObservatory`, Hysteria. В виде ссылок такие серверы либо отсутствуют, либо
/// заменены заглушками (`ss://…@example.com:1000`). Здесь конфиг запускается почти как
/// есть; меняется только то, что нужно для работы в Packet Tunnel:
///
/// - входы `socks`/`http` (локальные порты 10808/10809) заменяются встроенным TUN Xray
///   (`tun-in`) с теми же настройками sniffing, а правила маршрутизации, ссылавшиеся на эти
///   входы, — на `tun-in`;
/// - DNS-запросы приложений (порт 53 из TUN) всегда уходят в outbound `dns`: если такого
///   правила или outbound нет, они добавляются;
/// - ссылки на `geosite:`/`geoip:`/`ext:` убираются: файлов геобаз в сборке нет, и без этого
///   Xray не запустится. `geoip:private` заменяется списком частных сетей. Правило или
///   DNS-сервер, у которого после этого не осталось условий, удаляется целиком (иначе оно
///   совпало бы со всем трафиком);
/// - журнал — наш (`warning`, без журнала доступа); путь к файлу задаёт расширение.
enum XrayPanelConfiguration {
    /// Протоколы outbound, которые считаются серверами (а не служебными `freedom`, `dns`, ...).
    static let serverProtocols: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "hysteria", "hysteria2", "wireguard", "socks", "http",
    ]

    /// Результат адаптации.
    struct Adapted: Equatable {
        /// Конфиг для расширения (JSON с заглушкой дескриптора TUN).
        var json: String
        /// Убранные ссылки на геобазы, без повторов и по алфавиту (для диагностики).
        var droppedGeoEntries: [String]
    }

    /// Ошибки разбора конфига панели.
    enum Failure: Error, Equatable {
        /// Конфиг не является JSON-объектом.
        case notAnObject
        /// В конфиге нет ни одного outbound.
        case noOutbounds
    }

    // MARK: - Адаптация

    /// Адаптирует конфиг панели (JSON-строка) для запуска в расширении.
    static func adapt(_ json: String) throws -> Adapted {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.notAnObject
        }
        return try adapt(root)
    }

    /// Адаптирует разобранный конфиг панели.
    static func adapt(_ original: [String: Any]) throws -> Adapted {
        var root = original
        guard var outbounds = root["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            throw Failure.noOutbounds
        }
        root.removeValue(forKey: "remarks")
        var dropped = Set<String>()

        // Входы: только наш TUN; sniffing — как у входов панели (нужен для правил по доменам).
        let oldInbounds = root["inbounds"] as? [[String: Any]] ?? []
        let replacedTags = Set(oldInbounds.compactMap { $0["tag"] as? String })
        var tun: [String: Any] = [
            "tag": XrayTunnelLayout.tunInboundTag,
            "protocol": "tun",
            "port": 0,
            "settings": ["name": "utun", "mtu": XrayTunnelLayout.mtu],
        ]
        if let sniffing = oldInbounds.lazy.compactMap({ $0["sniffing"] as? [String: Any] }).first {
            tun["sniffing"] = sniffing
        }
        root["inbounds"] = [tun]

        root["log"] = ["loglevel": "warning", "access": "none", "dnsLog": false]
        var env = root["env"] as? [String: Any] ?? [:]
        env[XrayTunnelLayout.tunFdEnvKey] = XrayTunnelLayout.tunFdPlaceholder
        root["env"] = env

        // Маршрутизация.
        var routing = root["routing"] as? [String: Any] ?? [:]
        var rules = (routing["rules"] as? [[String: Any]] ?? []).compactMap {
            adaptRule($0, replacedInboundTags: replacedTags, dropped: &dropped)
        }

        // DNS-запросы из TUN — в outbound `dns`.
        let dnsTag: String
        if let existing = outbounds.first(where: { $0["protocol"] as? String == "dns" })?["tag"] as? String {
            dnsTag = existing
        } else {
            let tags = Set(outbounds.compactMap { $0["tag"] as? String })
            dnsTag = tags.contains(XrayConfigurationBuilder.Tag.dns) ? "mono-dns-out" : XrayConfigurationBuilder.Tag.dns
            // В конец: первый outbound остаётся outbound по умолчанию.
            outbounds.append(["tag": dnsTag, "protocol": "dns"])
        }
        let hijacksDNS = rules.contains { rule in
            stringList(rule["inboundTag"])?.contains(XrayTunnelLayout.tunInboundTag) == true
                && rule["outboundTag"] as? String == dnsTag
        }
        if !hijacksDNS {
            rules.insert([
                "type": "field",
                "inboundTag": [XrayTunnelLayout.tunInboundTag],
                "port": "53",
                "outboundTag": dnsTag,
            ], at: 0)
        }
        routing["rules"] = rules
        root["routing"] = routing
        root["outbounds"] = outbounds

        // DNS-серверы со списками доменов и ожидаемых IP.
        if var dns = root["dns"] as? [String: Any], let servers = dns["servers"] as? [Any] {
            dns["servers"] = servers.compactMap { adaptDNSServer($0, dropped: &dropped) }
            root["dns"] = dns
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else { throw Failure.notAnObject }
        return Adapted(json: json, droppedGeoEntries: dropped.sorted())
    }

    /// Правило маршрутизации без геобаз и со входом `tun-in`; `nil` — правило удалено.
    private static func adaptRule(
        _ original: [String: Any],
        replacedInboundTags: Set<String>,
        dropped: inout Set<String>
    ) -> [String: Any]? {
        var rule = original
        if let tags = stringList(rule["inboundTag"]) {
            var mapped: [String] = []
            for tag in tags {
                let target = replacedInboundTags.contains(tag) ? XrayTunnelLayout.tunInboundTag : tag
                if !mapped.contains(target) {
                    mapped.append(target)
                }
            }
            rule["inboundTag"] = mapped
        }
        for key in ["domain", "domains"] {
            guard let list = stringList(rule[key]) else { continue }
            let filtered = filterDomains(list, dropped: &dropped)
            if filtered.isEmpty { return nil }
            rule[key] = filtered
        }
        for key in ["ip", "source", "sourceIP"] {
            guard let list = stringList(rule[key]) else { continue }
            let filtered = filterIPs(list, dropped: &dropped)
            if filtered.isEmpty { return nil }
            rule[key] = filtered
        }
        return rule
    }

    /// DNS-сервер без геобаз; `nil` — у сервера были только домены из геобаз, и без них
    /// он стал бы сервером для всех запросов.
    private static func adaptDNSServer(_ original: Any, dropped: inout Set<String>) -> Any? {
        guard var server = original as? [String: Any] else { return original }
        if let list = stringList(server["domains"]) {
            let filtered = filterDomains(list, dropped: &dropped)
            if filtered.isEmpty { return nil }
            server["domains"] = filtered
        }
        for key in ["expectIPs", "expectedIPs", "unexpectedIPs"] {
            guard let list = stringList(server[key]) else { continue }
            let filtered = filterIPs(list, dropped: &dropped)
            if filtered.isEmpty {
                server.removeValue(forKey: key)
            } else {
                server[key] = filtered
            }
        }
        return server
    }

    /// Домены без `geosite:`/`ext:`.
    private static func filterDomains(_ list: [String], dropped: inout Set<String>) -> [String] {
        list.filter { entry in
            let lower = entry.lowercased()
            guard lower.hasPrefix("geosite:") || lower.hasPrefix("ext:") || lower.hasPrefix("ext-domain:") else { return true }
            dropped.insert(entry)
            return false
        }
    }

    /// IP без `geoip:`/`ext:`; `geoip:private` заменяется частными сетями.
    private static func filterIPs(_ list: [String], dropped: inout Set<String>) -> [String] {
        var result: [String] = []
        for entry in list {
            let lower = entry.lowercased()
            if lower == "geoip:private" {
                for network in XrayConfigurationBuilder.privateNetworks where !result.contains(network) {
                    result.append(network)
                }
            } else if lower.hasPrefix("geoip:") || lower.hasPrefix("ext:") || lower.hasPrefix("ext-ip:") {
                dropped.insert(entry)
            } else if !result.contains(entry) {
                result.append(entry)
            }
        }
        return result
    }

    /// Строка или массив строк (Xray принимает оба вида).
    static func stringList(_ value: Any?) -> [String]? {
        if let list = value as? [String] { return list }
        if let single = value as? String { return [single] }
        return nil
    }

    // MARK: - Описание сервера

    /// Описание конфига для списка серверов.
    struct Summary: Equatable {
        /// «VLESS · XHTTP · REALITY», «Hysteria», «Авто-выбор из 191».
        var text: String
        /// Число outbound-серверов.
        var serverCount: Int
        /// Протокол основного сервера (`vless`, `hysteria`, ...).
        var mainProtocol: String?
        /// Адрес и порт основного сервера (для сопоставления при обновлении подписки).
        var host: String?
        var port: Int?
    }

    /// Описывает конфиг: балансировщик или один сервер (первый outbound-сервер).
    static func summary(of root: [String: Any]) -> Summary {
        let outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let servers = outbounds.filter { serverProtocols.contains(($0["protocol"] as? String ?? "").lowercased()) }
        let balancers = (root["routing"] as? [String: Any])?["balancers"] as? [[String: Any]] ?? []
        let main = servers.first
        let endpoint = main.flatMap(endpoint(of:))

        if !balancers.isEmpty, servers.count > 1 {
            return Summary(
                text: String(localized: "server.summary.balancer \(servers.count)"),
                serverCount: servers.count,
                mainProtocol: main?["protocol"] as? String,
                host: endpoint?.host,
                port: endpoint?.port
            )
        }
        var parts: [String] = []
        if let main {
            let proto = (main["protocol"] as? String ?? "").lowercased()
            parts.append(protocolName(proto))
            let stream = main["streamSettings"] as? [String: Any] ?? [:]
            let network = (stream["network"] as? String ?? "tcp").lowercased()
            switch network {
            case "ws", "websocket": parts.append("WS")
            case "grpc", "gun": parts.append("gRPC")
            case "xhttp", "splithttp": parts.append("XHTTP")
            case "httpupgrade": parts.append("HTTPUpgrade")
            default: break
            }
            switch (stream["security"] as? String ?? "none").lowercased() {
            case "reality": parts.append("REALITY")
            case "tls" where !proto.hasPrefix("hysteria"): parts.append("TLS")
            default: break
            }
        }
        return Summary(
            text: parts.isEmpty ? "Xray" : parts.joined(separator: " · "),
            serverCount: servers.count,
            mainProtocol: main?["protocol"] as? String,
            host: endpoint?.host,
            port: endpoint?.port
        )
    }

    /// Название протокола для интерфейса (не переводится).
    static func protocolName(_ proto: String) -> String {
        switch proto {
        case "vless": "VLESS"
        case "vmess": "VMess"
        case "trojan": "Trojan"
        case "shadowsocks": "Shadowsocks"
        case "hysteria", "hysteria2": "Hysteria"
        case "wireguard": "WireGuard"
        case "socks": "SOCKS"
        case "http": "HTTP"
        default: proto.uppercased()
        }
    }

    /// Адрес и порт outbound: `settings.vnext[0]`, `settings.servers[0]` или плоский `settings`.
    static func endpoint(of outbound: [String: Any]) -> (host: String, port: Int?)? {
        guard let settings = outbound["settings"] as? [String: Any] else { return nil }
        for key in ["vnext", "servers", "peers"] {
            if let first = (settings[key] as? [[String: Any]])?.first {
                if let address = first["address"] as? String {
                    return (address, first["port"] as? Int)
                }
                if let endpoint = first["endpoint"] as? String {
                    return (endpoint, nil)
                }
            }
        }
        if let address = settings["address"] as? String {
            return (address, settings["port"] as? Int)
        }
        return nil
    }
}
