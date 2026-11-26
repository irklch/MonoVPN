import Foundation
@testable import MonoVPN
import Testing

/// Тесты диагностики последовательных обновлений подписки. Все данные вымышлены.
struct RefreshDiagnosticsTests {
    /// gRPC-сервер с authority; SNI подставляется параметром, как это делают панели с пулом SNI.
    private func grpcLink(sni: String) -> String {
        "vless://\(Fixture.uuid)@203.0.113.5:443?security=tls&sni=\(sni)&type=grpc&serviceName=svc&authority=front.example.com#G1"
    }

    /// Тело подписки в Base64 из ссылок.
    private func body(_ links: [String]) -> Data {
        Data(Data(links.joined(separator: "\n").utf8).base64EncodedString().utf8)
    }

    /// Один и тот же ответ: разбор детерминирован, статусы не меняются.
    @Test func identicalResponse() throws {
        let data = body([Fixture.vlessReality, grpcLink(sni: "front.example.com"), Fixture.trojan])
        let first = SubscriptionDiagnostics.snapshot(of: data)
        let second = SubscriptionDiagnostics.snapshot(of: data)
        let report = SubscriptionDiagnostics.report(previous: first, current: second)
        #expect(report.responseChange == .identical)
        #expect(report.statusChanges.isEmpty)
        #expect(report.changed == 0 && report.added == 0 && report.removed == 0)
        #expect(report.nondeterministicCount == 0)
        #expect(!report.indicatesAppBug)
        #expect(report.total == 3 && report.supported == 3)

        // Сам парсер тоже детерминирован.
        #expect(try SubscriptionParser.parse(data) == SubscriptionParser.parse(data))
    }

    /// Только другой порядок строк — это не изменение содержимого.
    @Test func reorderedResponse() {
        let a = SubscriptionDiagnostics.snapshot(of: body([Fixture.vlessReality, Fixture.trojan]))
        let b = SubscriptionDiagnostics.snapshot(of: body([Fixture.trojan, Fixture.vlessReality]))
        let report = SubscriptionDiagnostics.report(previous: a, current: b)
        #expect(report.responseChange == .reordered)
        #expect(report.changed == 0)
    }

    /// Два сервера с одним именем (TCP и XHTTP) поменялись местами: это перестановка,
    /// а не смена статуса, хотя «по имени» в списке кажется, что сервер стал (не)доступен.
    @Test func sameNameSwapIsNotStatusChange() {
        let tcp = "vless://\(Fixture.uuid)@203.0.113.7:443?security=tls&type=tcp#Netherlands%201"
        let xhttp = "vless://\(Fixture.uuid)@203.0.113.7:443?security=tls&type=xhttp&path=%2Fx#Netherlands%201"
        let a = SubscriptionDiagnostics.snapshot(of: body([tcp, xhttp]))
        let b = SubscriptionDiagnostics.snapshot(of: body([xhttp, tcp]))
        let report = SubscriptionDiagnostics.report(previous: a, current: b)
        #expect(report.responseChange == .reordered)
        #expect(report.statusChanges.isEmpty)
        #expect(report.changed == 0)
        #expect(report.duplicateNames == 1)
    }

    /// Провайдер сменил SNI: совместимость gRPC-сервера меняется, причина — параметр `sni`.
    @Test func sniRotationFlipsCompatibility() {
        let before = SubscriptionDiagnostics.snapshot(of: body([grpcLink(sni: "front.example.com"), Fixture.trojan]))
        let after = SubscriptionDiagnostics.snapshot(of: body([grpcLink(sni: "other.example.com"), Fixture.trojan]))
        let report = SubscriptionDiagnostics.report(previous: before, current: after)
        #expect(report.responseChange == .changed)
        #expect(report.changed == 1)
        #expect(report.added == 0 && report.removed == 0, "the server is matched by name, not by link hash")
        #expect(report.changedParameters == ["sni": 1])
        #expect(report.statusChanges.count == 1)
        let change = report.statusChanges.first
        #expect(change?.name == "G1")
        #expect(change?.from == SubscriptionDiagnostics.supportedStatus)
        #expect(change?.to == "grpcAuthorityMismatch")
        #expect(change?.changedParameters == ["sni"])
        #expect(!report.indicatesAppBug)
        #expect(report.reasons == ["grpcAuthorityMismatch": 1])
        #expect(report.transports["grpc"] == 1)
    }

    /// Распределения по протоколам, транспортам и причинам считаются по сырым ссылкам.
    @Test func distributions() {
        let xhttp = "vless://\(Fixture.uuid)@example.com:443?security=reality&pbk=\(Fixture.realityKey)&type=xhttp&path=%2Fx#X"
        let header = "vless://\(Fixture.uuid)@example.com:443?type=tcp&headerType=http#H"
        let broken = "vless://bad@example.com:443#B"
        let snapshot = SubscriptionDiagnostics.snapshot(of: body([xhttp, header, broken, "hysteria2://x@example.com:443#Y", Fixture.vlessReality, Fixture.vlessReality]))
        let report = SubscriptionDiagnostics.report(previous: nil, current: snapshot)
        #expect(report.responseChange == .first)
        #expect(report.total == 5)
        #expect(report.duplicates == 1)
        #expect(report.supported == 1 && report.unsupported == 2 && report.invalid == 2)
        #expect(report.protocols == ["vless": 4, "hysteria2": 1])
        #expect(report.transports["xhttp"] == 1)
        #expect(report.transports["tcp/http"] == 1)
        #expect(report.securities["reality"] == 2)
        #expect(report.reasons["transport:xhttp"] == 1)
        #expect(report.reasons["headerType:http"] == 1)
        #expect(report.reasons["invalid:invalidUUID"] == 1)
        #expect(report.reasons["scheme:hysteria2"] == 1)
    }

    /// Ни отчёт, ни текст для интерфейса не содержат секретов и значений параметров.
    @Test func reportHasNoSecrets() throws {
        let before = SubscriptionDiagnostics.snapshot(of: body([grpcLink(sni: "front.example.com"), Fixture.vlessReality]))
        let after = SubscriptionDiagnostics.snapshot(of: body([grpcLink(sni: "secret-sni.example.com"), Fixture.vlessReality]))
        let report = SubscriptionDiagnostics.report(previous: before, current: after)
        let text = RefreshReportText.lines(for: report).joined(separator: "\n")
            + String(data: try JSONEncoder().encode(report), encoding: .utf8)!
        for secret in [Fixture.uuid, Fixture.realityKey, "6ba85179e30d4fc2", "203.0.113", "secret-sni", "front.example.com", "svc"] {
            #expect(!text.contains(secret), "leaked: \(secret)")
        }
    }

    /// После смены SNI ID сервера (хеш ссылки) другой, но выбор пользователя сохраняется.
    @Test func selectionSurvivesLinkChange() throws {
        let a = try SubscriptionParser.parse(body([Fixture.trojan, Fixture.vlessReality]))
        let changedReality = Fixture.vlessReality.replacingOccurrences(of: "sni=www.example.com", with: "sni=cdn.example.com")
        let b = try SubscriptionParser.parse(body([Fixture.trojan, changedReality]))
        #expect(a.servers[1].id != b.servers[1].id)

        var state = AppState()
        state.replaceSubscription(with: Subscription(source: .link("x"), servers: a.servers, issues: [], lastUpdated: .now))
        state.selectedServerID = a.servers[1].id
        state.replaceSubscription(with: Subscription(source: .link("x"), servers: b.servers, issues: [], lastUpdated: .now))
        #expect(state.selectedServer?.name == "Test Reality")
        #expect(state.selectedServerID == b.servers[1].id)
    }

    /// Состояние, сохранённое до появления диагностики, по-прежнему загружается.
    @Test func decodesLegacyState() throws {
        var legacy = AppState()
        legacy.replaceSubscription(with: Subscription(
            source: .link(Fixture.trojan), servers: [try ProxyLinkParser.parse(Fixture.trojan)], issues: [], lastUpdated: .now
        ))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "refreshReports")
        var subscription = try #require(json["subscription"] as? [String: Any])
        subscription.removeValue(forKey: "snapshot")
        json["subscription"] = subscription
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.subscription?.servers.count == 1)
        #expect(decoded.refreshReports == nil)
        #expect(decoded.subscription?.snapshot == nil)
    }
}
