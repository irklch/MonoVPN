import Foundation
@testable import MonoVPN
import Testing

/// Тесты `XrayConfigurationPolicy`: Lua-скрипты из конфигураций провайдера не исполняются,
/// журналы Xray нельзя включить конфигурацией. Все данные вымышлены (example.*, TEST-NET).
struct XrayConfigurationPolicyTests {
    /// Минимальный конфиг панели с одним сервером VLESS + TLS.
    private func config(_ extra: [String: Any] = [:], stream: [String: Any] = [:]) -> [String: Any] {
        var streamSettings: [String: Any] = [
            "network": "tcp",
            "security": "tls",
            "tlsSettings": ["serverName": "sni.example.com"],
        ]
        streamSettings.merge(stream) { _, new in new }
        var root: [String: Any] = [
            "remarks": "Test",
            "outbounds": [
                ["tag": "proxy", "protocol": "vless",
                 "settings": ["address": "edge.example.com", "port": 443,
                              "users": [["id": "11111111-2222-4333-8444-555555555555", "encryption": "none"]]],
                 "streamSettings": streamSettings],
                ["tag": "direct", "protocol": "freedom"],
            ],
            "routing": ["rules": [["type": "field", "ip": ["198.51.100.1"], "outboundTag": "direct"]]],
        ]
        root.merge(extra) { _, new in new }
        return root
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    // MARK: - Lua

    /// Скрипт маршрутизации, DNS и маски noise (finalmask) — конфиг отклоняется целиком.
    @Test func rejectsLuaScripts() throws {
        let routing = config(["routing": ["script": "route.lua"]])
        let dns = config(["dns": ["servers": ["1.1.1.1"], "script": "dns.lua"]])
        let finalmask = config(stream: ["finalmask": ["udp": [["type": "noise", "settings": ["script": "noise.lua"]]]]])
        // Go сопоставляет имена полей без учёта регистра.
        let upperCase = config(["routing": ["Script": "route.lua"]])
        for root in [routing, dns, finalmask, upperCase] {
            #expect(XrayConfigurationPolicy.containsLuaScript(root))
            #expect(throws: XrayConfigurationPolicy.Failure.luaScript) {
                try XrayPanelConfiguration.adapt(root)
            }
            #expect(throws: XrayConfigurationPolicy.Failure.luaScript) {
                try XrayRuntimeConfiguration.prepare(json(root), tunFileDescriptor: 3, resolvedAddresses: [:])
            }
        }
    }

    /// Пустое поле `script` Xray не использует: оно убирается, конфиг принимается.
    @Test func acceptsEmptyScript() throws {
        let root = config(["routing": ["script": "", "rules": [] as [Any]]])
        #expect(!XrayConfigurationPolicy.containsLuaScript(root))
        let adapted = try decode(XrayPanelConfiguration.adapt(root).json)
        #expect((adapted["routing"] as? [String: Any])?["script"] == nil)
    }

    /// Конфиг со скриптом не попадает в список серверов: причина видна в диагностике импорта.
    @Test func subscriptionReportsScriptedConfig() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            config(["remarks": "Clean"]),
            config(["remarks": "Scripted", "routing": ["script": "route.lua"]]),
        ])
        let result = try XrayJSONSubscriptionParser.parse(payload)
        #expect(result.servers.map(\.name) == ["Clean"])
        #expect(result.issues.map(\.name) == ["Scripted"])
        #expect(result.issues.first?.reason == XrayConfigurationPolicy.Failure.luaScript.localizedDescription)
    }

    /// Конфиг со скриптом, сохранённый прежней версией, не собирается в конфигурацию туннеля.
    @Test func builderRejectsStoredScriptedConfig() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("panel-\(UUID().uuidString).json")
        let store = PanelConfigurationStore(url: url)
        defer { try? store.removeAll() }
        try store.save(["json-1": json(config(["routing": ["script": "route.lua"]]))])
        var server = ServerConfiguration(id: "json-1", name: "Scripted", proxyProtocol: .vless, host: "edge.example.com", port: 443)
        server.panel = PanelServerInfo(summary: "VLESS", serverCount: 1, configHash: "x")
        #expect(throws: XrayConfigurationPolicy.Failure.luaScript) {
            try TunnelConfigurationBuilder.build(for: server, panelStore: store)
        }
    }

    // MARK: - Журналы и отладка

    /// Журнал провайдера (в том числе под именем в другом регистре) заменяется выключенным,
    /// `masterKeyLog` и отладка QUIC убираются; убранное видно в диагностике по имени.
    @Test func disablesLoggingAndDebugOutput() throws {
        let root = config(
            ["log": ["access": "/tmp/a.log", "loglevel": "debug", "dnsLog": true], "Log": ["loglevel": "info"]],
            stream: [
                "tlsSettings": ["serverName": "sni.example.com", "masterKeyLog": "/tmp/keys.log"],
                "finalmask": ["quicParams": ["debug": true, "congestion": "bbr"]],
            ]
        )
        let adapted = try XrayPanelConfiguration.adapt(root)
        let result = try decode(adapted.json)
        #expect(result["Log"] == nil)
        let log = try #require(result["log"] as? [String: Any])
        #expect(NSDictionary(dictionary: log) == NSDictionary(dictionary: XrayConfigurationPolicy.disabledLog))
        #expect(!adapted.json.contains("masterKeyLog"))
        #expect(!adapted.json.contains("/tmp/keys.log"))
        #expect(adapted.json.contains("\"congestion\":\"bbr\""))
        #expect(!adapted.json.contains("\"debug\""))
        #expect(adapted.droppedGeoEntries.contains("masterKeyLog"))
        #expect(adapted.droppedGeoEntries.contains("quicParams.debug"))
    }

    /// В `env` остаются только настройки буферов и протоколов; `xray.xudp.show` и каталоги
    /// файлов (`xray.location.*`) убираются в любом написании имени.
    @Test func filtersEnvironment() throws {
        let root = config(["env": [
            "xray.buf.readv": "enable",
            "XRAY_XUDP_SHOW": "true",
            "xray.location.asset": "/tmp",
            "GODEBUG": "x=1",
        ]])
        let adapted = try XrayPanelConfiguration.adapt(root)
        let env = try #require(decode(adapted.json)["env"] as? [String: String])
        #expect(env["xray.buf.readv"] == "enable")
        #expect(env["xray.tun.fd"] == XrayTunnelLayout.tunFdPlaceholder)
        #expect(env["XRAY_XUDP_SHOW"] == nil)
        #expect(env["xray.location.asset"] == nil)
        #expect(env["GODEBUG"] == nil)
        #expect(adapted.droppedGeoEntries.contains("env.XRAY_XUDP_SHOW"))

        let prepared = try decode(XrayRuntimeConfiguration.prepare(json(root), tunFileDescriptor: 7, resolvedAddresses: [:]))
        let preparedEnv = try #require(prepared["env"] as? [String: String])
        #expect(preparedEnv["xray.tun.fd"] == "7")
        #expect(preparedEnv["XRAY_XUDP_SHOW"] == nil)
    }

    /// Прочие параметры конфигурации политика не меняет.
    @Test func keepsOtherParameters() throws {
        let root = config(["routing": ["domainStrategy": "IPIfNonMatch", "rules": [["type": "field", "domain": ["example.org"], "outboundTag": "direct"]]]])
        let sanitized = try XrayConfigurationPolicy.sanitize(root)
        #expect(sanitized.droppedParameters.isEmpty)
        let routing = try #require(sanitized.root["routing"] as? [String: Any])
        #expect(routing["domainStrategy"] as? String == "IPIfNonMatch")
        let outbound = try #require((sanitized.root["outbounds"] as? [[String: Any]])?.first)
        let tls = try #require((outbound["streamSettings"] as? [String: Any])?["tlsSettings"] as? [String: Any])
        #expect(tls["serverName"] as? String == "sni.example.com")
    }
}

/// Очистка данных диагностики, сохранённых прежними версиями.
struct LegacyDiagnosticsCleanupTests {
    /// Файлы диагностики удаляются, каталог `Tunnel` — только если он опустел.
    @Test func removesLegacyFiles() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("Tunnel-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in LegacyDiagnosticsCleanup.legacyFileNames {
            try Data("x".utf8).write(to: directory.appendingPathComponent(name))
        }
        #expect(LegacyDiagnosticsCleanup.removeFiles(in: directory))
        #expect(!manager.fileExists(atPath: directory.path))

        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("diagnostics.json"))
        try Data("keep".utf8).write(to: directory.appendingPathComponent("other"))
        #expect(LegacyDiagnosticsCleanup.removeFiles(in: directory))
        #expect(!manager.fileExists(atPath: directory.appendingPathComponent("diagnostics.json").path))
        #expect(manager.fileExists(atPath: directory.appendingPathComponent("other").path))
        try manager.removeItem(at: directory)
    }

    /// Поля `refreshReports` и `subscription.snapshot` убираются, остальное состояние сохраняется.
    @Test func stripsLegacyStateFields() throws {
        let legacy: [String: Any] = [
            "selectedServerID": "abc",
            "refreshReports": [["date": 0]],
            "subscription": [
                "source": ["link": ["_0": "vless://x"]],
                "servers": [] as [Any],
                "issues": [] as [Any],
                "lastUpdated": 0,
                "snapshot": ["responseHash": "00"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let cleaned = try #require(try AppStateStore.withoutLegacyDiagnosticFields(data))
        let text = String(decoding: cleaned, as: UTF8.self)
        #expect(!text.contains("refreshReports"))
        #expect(!text.contains("snapshot"))
        let state = try JSONDecoder().decode(AppState.self, from: cleaned)
        #expect(state.selectedServerID == "abc")
        #expect(state.subscription?.source == .link("vless://x"))

        // Без устаревших полей ничего не переписывается.
        #expect(try AppStateStore.withoutLegacyDiagnosticFields(cleaned) == nil)
    }
}
