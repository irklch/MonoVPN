import Foundation
@testable import MonoVPN
import Testing

/// Тесты построения конфигурации sing-box из разобранных серверов.
struct VPNConfigurationBuilderTests {
    /// Декодирует JSON-конфигурацию в словарь для проверок.
    private func decode(_ json: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try #require(object as? [String: Any])
    }

    /// VLESS + REALITY: outbound, TLS/uTLS/REALITY и защита от утечек (IPv6 в TUN, перехват DNS).
    @Test func vlessRealityConfiguration() throws {
        let server = try ProxyLinkParser.parse(Fixture.vlessReality)
        let config = try decode(VPNConfigurationBuilder.build(for: server))

        let outbounds = try #require(config["outbounds"] as? [[String: Any]])
        let proxy = try #require(outbounds.first)
        #expect(proxy["type"] as? String == "vless")
        #expect(proxy["tag"] as? String == "proxy")
        #expect(proxy["server"] as? String == "203.0.113.10")
        #expect(proxy["server_port"] as? Int == 443)
        #expect(proxy["uuid"] as? String == Fixture.uuid)
        #expect(proxy["flow"] as? String == "xtls-rprx-vision")
        #expect(proxy["transport"] == nil)

        let tls = try #require(proxy["tls"] as? [String: Any])
        #expect(tls["server_name"] as? String == "www.example.com")
        let utls = try #require(tls["utls"] as? [String: Any])
        #expect(utls["fingerprint"] as? String == "chrome")
        let reality = try #require(tls["reality"] as? [String: Any])
        #expect(reality["public_key"] as? String == Fixture.realityKey)
        #expect(reality["short_id"] as? String == "6ba85179e30d4fc2")

        // Защита от утечек: TUN с IPv4 + IPv6 и auto route, DNS перехватывается.
        let inbounds = try #require(config["inbounds"] as? [[String: Any]])
        let tun = try #require(inbounds.first)
        #expect(tun["type"] as? String == "tun")
        #expect(tun["auto_route"] as? Bool == true)
        let addresses = try #require(tun["address"] as? [String])
        #expect(addresses.contains { $0.contains(":") }, "TUN must claim IPv6 too")

        let route = try #require(config["route"] as? [String: Any])
        #expect(route["final"] as? String == "proxy")
        let rules = try #require(route["rules"] as? [[String: Any]])
        #expect(rules.contains { $0["action"] as? String == "hijack-dns" })
    }

    /// WebSocket-транспорт: путь без `?ed=`, early data и заголовок Host.
    @Test func webSocketTransport() throws {
        let server = try ProxyLinkParser.parse(Fixture.vlessWebSocketTLS)
        let proxy = try VPNConfigurationBuilder.outbound(for: server)
        let transport = try #require(proxy["transport"] as? [String: Any])
        #expect(transport["type"] as? String == "ws")
        #expect(transport["path"] as? String == "/ws")
        #expect(transport["max_early_data"] as? Int == 2048)
        #expect((transport["headers"] as? [String: String])?["Host"] == "cdn.example.org")
    }

    /// Shadowsocks: тип, метод и отсутствие TLS.
    @Test func shadowsocksConfiguration() throws {
        let server = try ProxyLinkParser.parse(Fixture.shadowsocks)
        let proxy = try VPNConfigurationBuilder.outbound(for: server)
        #expect(proxy["type"] as? String == "shadowsocks")
        #expect(proxy["method"] as? String == "aes-256-gcm")
        #expect(proxy["tls"] == nil)
    }
}

/// Тесты форматирования длительности подключения.
struct ConnectionDurationFormatterTests {
    /// Форматирование от даты начала: ноль без даты, отбрасывание долей секунды, больше 24 часов, отрицательные значения.
    @Test func formatsFromStartDate() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(ConnectionDurationFormatter.string(from: nil, to: start) == "00:00:00")
        #expect(ConnectionDurationFormatter.string(from: start, to: start.addingTimeInterval(59.9)) == "00:00:59")
        #expect(ConnectionDurationFormatter.string(from: start, to: start.addingTimeInterval(3_725)) == "01:02:05")
        #expect(ConnectionDurationFormatter.string(from: start, to: start.addingTimeInterval(90_000)) == "25:00:00")
        // Расхождение часов не должно давать отрицательных значений.
        #expect(ConnectionDurationFormatter.string(from: start, to: start.addingTimeInterval(-5)) == "00:00:00")
    }
}
