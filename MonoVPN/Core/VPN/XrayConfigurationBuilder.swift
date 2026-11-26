import Foundation

/// Строит JSON-конфигурацию Xray-core (v26.11.9) для одного сервера.
///
/// Модель маршрутизации (та же, что у сборки с sing-box):
/// - Пакеты получает встроенный TUN inbound Xray (`protocol: "tun"`) по дескриптору, который
///   передаёт NetworkExtension (`env["xray.tun.fd"]`); tun2socks не нужен. Адреса, маршруты
///   IPv4 **и** IPv6 по умолчанию и DNS задаёт расширение (`XrayTunnelLayout`), поэтому трафик
///   IPv6 не обходит туннель, даже если у сервера нет IPv6.
/// - Все DNS-запросы на порт 53 из туннеля перехватываются (`dns-out`) и разрешаются через
///   DNS-over-HTTPS поверх прокси; к сторонним DNS-серверам напрямую ничего не уходит.
/// - Частные (LAN) адреса идут напрямую, всё остальное — через прокси (первый outbound).
/// - Сетевых циклов нет: собственные сокеты процесса Packet Tunnel iOS не направляет в туннель,
///   а адрес сервера расширение разрешает до применения сетевых настроек туннеля.
///
/// Имена полей сверены с `infra/conf` Xray-core v26.11.9.
enum XrayConfigurationBuilder {
    /// Теги объектов конфигурации.
    enum Tag {
        /// Прямое исходящее соединение (LAN).
        static let direct = "direct"
        /// Исходящее соединение, обрабатывающее перехваченные DNS-запросы.
        static let dns = "dns-out"
        /// Внутренний DNS-клиент Xray.
        static let internalDNS = "dns-internal"
    }

    /// DoH-сервер внутри туннеля (по IP: не требует разрешения имени).
    static let remoteDNSServer = "https://1.1.1.1/dns-query"

    /// Частные и служебные сети, которые идут напрямую.
    static let privateNetworks = [
        "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
        "::1/128", "fc00::/7", "fe80::/10",
    ]

    /// Возвращает полную конфигурацию Xray для сервера в виде JSON-строки.
    ///
    /// Вместо дескриптора TUN стоит `XrayTunnelLayout.tunFdPlaceholder`: его заменяет расширение.
    static func build(for server: ServerConfiguration) throws -> String {
        let config: [String: Any] = [
            "log": [
                // Только предупреждения и без журнала доступа: посещённые адреса не пишутся.
                "loglevel": "warning",
                "access": "none",
                "dnsLog": false,
            ],
            "env": [XrayTunnelLayout.tunFdEnvKey: XrayTunnelLayout.tunFdPlaceholder],
            "dns": [
                "servers": [remoteDNSServer],
                // Только A-записи: если у VPN-сервера нет IPv6, приложения не ждут таймаутов IPv6.
                // Пакеты IPv6 при этом всё равно попадают в туннель и не обходят VPN.
                "queryStrategy": "UseIPv4",
                "tag": Tag.internalDNS,
            ],
            "inbounds": [
                [
                    "tag": XrayTunnelLayout.tunInboundTag,
                    "protocol": "tun",
                    "port": 0,
                    "settings": [
                        "name": "utun",
                        "mtu": XrayTunnelLayout.mtu,
                    ],
                ],
            ],
            "outbounds": [
                try outbound(for: server),
                ["tag": Tag.direct, "protocol": "freedom"],
                ["tag": Tag.dns, "protocol": "dns"],
            ],
            "routing": [
                "domainStrategy": "AsIs",
                "rules": [
                    [
                        "type": "field",
                        "inboundTag": [XrayTunnelLayout.tunInboundTag],
                        "port": "53",
                        "outboundTag": Tag.dns,
                    ],
                    [
                        "type": "field",
                        "ip": privateNetworks,
                        "outboundTag": Tag.direct,
                    ],
                ],
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return json
    }

    /// Собирает outbound для протокола сервера.
    ///
    /// Бросает причину несовместимости, если сервер не поддерживается ядром, и
    /// `ProxyLinkError.malformed`, если не хватает UUID, пароля или шифра.
    static func outbound(for server: ServerConfiguration) throws -> [String: Any] {
        if let incompatibility = server.incompatibility {
            throw incompatibility
        }
        var outbound: [String: Any] = ["tag": XrayTunnelLayout.proxyOutboundTag]

        switch server.proxyProtocol {
        case .vless:
            var user: [String: Any] = ["id": try required(server.uuid), "encryption": "none"]
            if let flow = server.flow {
                user["flow"] = flow
            }
            outbound["protocol"] = "vless"
            outbound["settings"] = ["vnext": [["address": server.host, "port": server.port, "users": [user]]]]
        case .vmess:
            let user: [String: Any] = ["id": try required(server.uuid), "security": server.vmessSecurity ?? "auto"]
            outbound["protocol"] = "vmess"
            outbound["settings"] = ["vnext": [["address": server.host, "port": server.port, "users": [user]]]]
        case .trojan:
            outbound["protocol"] = "trojan"
            outbound["settings"] = ["servers": [[
                "address": server.host, "port": server.port, "password": try required(server.password),
            ]]]
        case .shadowsocks:
            if let plugin = server.shadowsocksPlugin {
                throw ProxyLinkError.unsupportedShadowsocksPlugin(plugin)
            }
            outbound["protocol"] = "shadowsocks"
            outbound["settings"] = ["servers": [[
                "address": server.host, "port": server.port,
                "method": try required(server.method), "password": try required(server.password),
            ]]]
        }
        outbound["streamSettings"] = try streamSettings(for: server)
        return outbound
    }

    /// `streamSettings`: транспорт и TLS/REALITY.
    ///
    /// SNI и заголовки Host задаются явно (по умолчанию — имя сервера из ссылки), потому что
    /// расширение может заменить адрес сервера на заранее разрешённый IP.
    static func streamSettings(for server: ServerConfiguration) throws -> [String: Any] {
        let domain = isIPAddress(server.host) ? nil : server.host
        var stream: [String: Any] = [:]

        switch server.transport {
        case .tcp:
            stream["network"] = "raw"
        case let .webSocket(path, host, maxEarlyData):
            stream["network"] = "ws"
            // Early data Xray задаётся в пути: `/path?ed=2048`.
            var fullPath = path
            if let maxEarlyData, maxEarlyData > 0 {
                fullPath += (path.contains("?") ? "&" : "?") + "ed=\(maxEarlyData)"
            }
            stream["wsSettings"] = compact(["path": fullPath, "host": host ?? domain])
        case let .grpc(serviceName):
            stream["network"] = "grpc"
            var grpc: [String: Any] = ["serviceName": serviceName, "multiMode": false]
            // Без TLS `:authority` по умолчанию — адрес; если его заменили на IP, отправляем имя.
            if let authority = server.grpcAuthority ?? (server.tls == nil ? domain : nil) {
                grpc["authority"] = authority
            }
            stream["grpcSettings"] = grpc
        case .http:
            // В Xray-core транспорт HTTP/2 удалён (заменён XHTTP).
            throw ProxyLinkError.unsupportedTransport("http")
        case let .httpUpgrade(path, host):
            stream["network"] = "httpupgrade"
            stream["httpupgradeSettings"] = compact(["path": path, "host": host ?? domain])
        case let .xhttp(path, host, mode):
            stream["network"] = "xhttp"
            var xhttp = compact(["path": path, "host": host ?? domain, "mode": mode ?? "auto"])
            if let extra = server.xhttpExtra,
               let data = extra.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                xhttp["extra"] = object
            }
            stream["xhttpSettings"] = xhttp
        }

        if let tls = server.tls {
            let serverName = tls.serverName ?? domain
            if let reality = tls.reality {
                stream["security"] = "reality"
                stream["realitySettings"] = compact([
                    "serverName": serverName,
                    // REALITY в Xray требует uTLS; chrome — значение по умолчанию Xray.
                    "fingerprint": tls.fingerprint ?? "chrome",
                    "publicKey": reality.publicKey,
                    "shortId": reality.shortID,
                ])
            } else {
                stream["security"] = "tls"
                var settings = compact(["serverName": serverName, "fingerprint": tls.fingerprint])
                if !tls.alpn.isEmpty {
                    settings["alpn"] = tls.alpn
                }
                stream["tlsSettings"] = settings
            }
        } else {
            stream["security"] = "none"
        }
        return stream
    }

    /// Убирает ключи со значением `nil`.
    private static func compact(_ values: [String: Any?]) -> [String: Any] {
        values.compactMapValues { $0 }
    }

    /// Является ли строка IPv4- или IPv6-адресом.
    static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
    }

    /// Возвращает непустое значение или бросает `ProxyLinkError.malformed`.
    private static func required(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw ProxyLinkError.malformed }
        return value
    }
}

/// Выбирает генератор конфигурации туннеля для ядра текущей сборки.
enum TunnelConfigurationBuilder {
    /// Конфигурация туннеля для сервера: JSON sing-box или Xray.
    static func build(for server: ServerConfiguration) throws -> String {
        switch VPNCore.current {
        case .singBox:
            return try VPNConfigurationBuilder.build(for: server)
        case .xray:
            return try XrayConfigurationBuilder.build(for: server)
        }
    }
}
