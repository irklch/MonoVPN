import Foundation

/// Строит JSON-конфигурацию sing-box (v1.14) для одного сервера.
///
/// Модель маршрутизации:
/// - Вход TUN с адресами IPv4 **и** IPv6 и `auto_route`, поэтому Packet Tunnel
///   забирает оба маршрута по умолчанию. Трафик IPv6 никогда не идёт мимо
///   туннеля, даже если у самого VPN-сервера нет IPv6.
/// - Все DNS-запросы, попавшие в туннель, перехватываются и разрешаются через DNS-over-HTTPS
///   поверх прокси; системный резолвер используется только для разрешения имени
///   самого VPN-сервера (`default_domain_resolver`).
/// - Частные (LAN) адреса идут напрямую, всё остальное — через прокси.
enum VPNConfigurationBuilder {
    /// Теги объектов конфигурации, по которым они ссылаются друг на друга.
    enum Tag {
        /// Исходящее соединение через прокси-сервер.
        static let proxy = "proxy"
        /// Прямое исходящее соединение (для LAN).
        static let direct = "direct"
        /// Входящий TUN-интерфейс.
        static let tun = "tun-in"
        /// Удалённый DNS (DoH через прокси).
        static let remoteDNS = "dns-remote"
        /// Локальный системный DNS (только для имени VPN-сервера).
        static let localDNS = "dns-local"
    }

    /// Удалённый DNS внутри туннеля (DoH через прокси).
    static let remoteDNSServer = "1.1.1.1"

    /// Возвращает полную конфигурацию sing-box для сервера в виде JSON-строки.
    ///
    /// Бросает ошибку, если у сервера нет обязательных полей для его протокола.
    static func build(for server: ServerConfiguration) throws -> String {
        let config: [String: Any] = [
            "log": [
                // Только предупреждения: sing-box никогда не логирует учётные данные, а низкий
                // уровень не даёт записывать посещённые домены.
                "level": "warn",
            ],
            "dns": [
                "servers": [
                    [
                        "type": "https",
                        "tag": Tag.remoteDNS,
                        "server": remoteDNSServer,
                        "detour": Tag.proxy,
                    ],
                    [
                        "type": "local",
                        "tag": Tag.localDNS,
                    ],
                ],
                "final": Tag.remoteDNS,
                "strategy": "prefer_ipv4",
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": Tag.tun,
                    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                    "mtu": 9000,
                    "auto_route": true,
                    "strict_route": true,
                ],
            ],
            "outbounds": [
                try outbound(for: server),
                ["type": "direct", "tag": Tag.direct],
            ],
            "route": [
                "rules": [
                    ["action": "sniff"],
                    ["protocol": "dns", "action": "hijack-dns"],
                    ["ip_is_private": true, "outbound": Tag.direct],
                ],
                "final": Tag.proxy,
                "auto_detect_interface": true,
                "default_domain_resolver": Tag.localDNS,
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return json
    }

    /// Собирает объект outbound (исходящее соединение через прокси) для протокола сервера.
    ///
    /// Бросает `ProxyLinkError.malformed`, если не хватает UUID, пароля или шифра.
    static func outbound(for server: ServerConfiguration) throws -> [String: Any] {
        var outbound: [String: Any] = [
            "tag": Tag.proxy,
            "server": server.host,
            "server_port": server.port,
        ]

        switch server.proxyProtocol {
        case .vless:
            outbound["type"] = "vless"
            outbound["uuid"] = try required(server.uuid)
            if let flow = server.flow {
                outbound["flow"] = flow
            }
            outbound["packet_encoding"] = "xudp"
        case .vmess:
            outbound["type"] = "vmess"
            outbound["uuid"] = try required(server.uuid)
            outbound["security"] = server.vmessSecurity ?? "auto"
            outbound["alter_id"] = server.vmessAlterID ?? 0
            outbound["packet_encoding"] = "xudp"
        case .trojan:
            outbound["type"] = "trojan"
            outbound["password"] = try required(server.password)
        case .shadowsocks:
            outbound["type"] = "shadowsocks"
            outbound["method"] = try required(server.method)
            outbound["password"] = try required(server.password)
        }

        if let tls = server.tls {
            outbound["tls"] = tlsObject(tls)
        }
        if let transport = transportObject(server.transport) {
            outbound["transport"] = transport
        }
        return outbound
    }

    /// Преобразует настройки TLS (SNI, ALPN, uTLS, REALITY) в объект `tls` sing-box.
    private static func tlsObject(_ tls: TLSSettings) -> [String: Any] {
        var object: [String: Any] = ["enabled": true]
        if let serverName = tls.serverName {
            object["server_name"] = serverName
        }
        if !tls.alpn.isEmpty {
            object["alpn"] = tls.alpn
        }
        if let fingerprint = tls.fingerprint {
            object["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
        if let reality = tls.reality {
            object["reality"] = [
                "enabled": true,
                "public_key": reality.publicKey,
                "short_id": reality.shortID,
            ]
        }
        return object
    }

    /// Преобразует транспорт в объект `transport` sing-box; для TCP возвращает `nil` (транспорт не нужен).
    private static func transportObject(_ transport: TransportSettings) -> [String: Any]? {
        switch transport {
        case .tcp:
            return nil
        case let .webSocket(path, host, maxEarlyData):
            var object: [String: Any] = ["type": "ws", "path": path]
            if let host {
                object["headers"] = ["Host": host]
            }
            if let maxEarlyData, maxEarlyData > 0 {
                object["max_early_data"] = maxEarlyData
                object["early_data_header_name"] = "Sec-WebSocket-Protocol"
            }
            return object
        case let .grpc(serviceName):
            return ["type": "grpc", "service_name": serviceName]
        case let .http(path, hosts):
            var object: [String: Any] = ["type": "http", "path": path]
            if !hosts.isEmpty {
                object["host"] = hosts
            }
            return object
        case let .httpUpgrade(path, host):
            var object: [String: Any] = ["type": "httpupgrade", "path": path]
            if let host {
                object["host"] = host
            }
            return object
        }
    }

    /// Возвращает непустое значение или бросает `ProxyLinkError.malformed`.
    private static func required(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw ProxyLinkError.malformed }
        return value
    }
}
