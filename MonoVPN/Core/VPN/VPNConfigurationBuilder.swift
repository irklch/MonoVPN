import Foundation

/// Builds the sing-box (v1.14) JSON configuration for one server.
///
/// Routing model:
/// - TUN inbound with IPv4 **and** IPv6 addresses and `auto_route`, so the Packet
///   Tunnel claims both default routes. IPv6 traffic is never left outside the
///   tunnel, even when the VPN server itself has no IPv6.
/// - All DNS queries sent to the tunnel are hijacked and resolved over DNS-over-HTTPS
///   through the proxy; the system resolver is used only to resolve the VPN server's
///   own hostname (`default_domain_resolver`).
/// - Private (LAN) addresses go direct, everything else goes through the proxy.
enum VPNConfigurationBuilder {
    enum Tag {
        static let proxy = "proxy"
        static let direct = "direct"
        static let tun = "tun-in"
        static let remoteDNS = "dns-remote"
        static let localDNS = "dns-local"
    }

    /// Remote DNS used inside the tunnel (DoH over the proxy).
    static let remoteDNSServer = "1.1.1.1"

    static func build(for server: ServerConfiguration) throws -> String {
        let config: [String: Any] = [
            "log": [
                // Warnings only: sing-box never logs credentials, and keeping the level
                // low avoids recording visited domains.
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

    private static func required(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw ProxyLinkError.malformed }
        return value
    }
}
