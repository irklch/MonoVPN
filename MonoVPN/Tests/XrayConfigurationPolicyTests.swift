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

    /// Пустое поле `script` и `null` Xray не использует: конфиг принимается без изменения поля.
    /// Строка из пробелов или значение другого типа — уже не «пусто»: конфиг отклоняется.
    @Test func emptyScriptValues() throws {
        let root = config(["routing": ["script": "", "rules": [] as [Any]]])
        #expect(!XrayConfigurationPolicy.containsLuaScript(root))
        let adapted = try decode(XrayPanelConfiguration.adapt(root).json)
        #expect((adapted["routing"] as? [String: Any])?["script"] as? String == "")

        #expect(!XrayConfigurationPolicy.containsLuaScript(config(["dns": ["script": NSNull()]])))
        #expect(XrayConfigurationPolicy.containsLuaScript(config(["dns": ["script": " "]])))
        #expect(XrayConfigurationPolicy.containsLuaScript(config(["dns": ["script": 1]])))
        #expect(XrayConfigurationPolicy.containsLuaScript(config(["dns": ["script": ["file": "a.lua"]]])))
    }

    /// Go сопоставляет имена полей без учёта регистра ASCII и считает `ſ` (U+017F) равной `s`,
    /// а `K` (U+212A) — `k`; проверки сравнивают так же. Турецкие `İ`/`ı` Go с `i` не путает.
    @Test func lookalikeKeysCannotBypassChecks() throws {
        for key in ["SCRIPT", "\u{017F}cript", "sCrIpT"] {
            #expect(XrayConfigurationPolicy.containsLuaScript(config(["routing": [key: "route.lua"]])), "\(key)")
        }
        for key in ["scr\u{0130}pt", "scr\u{0131}pt", "script_", "s-cript"] {
            #expect(!XrayConfigurationPolicy.containsLuaScript(config(["routing": [key: "route.lua"]])), "\(key)")
        }
        #expect(XrayConfigurationPolicy.goFoldedName("master\u{212A}eyLog") == "masterkeylog")

        let root = config(stream: [
            "tlsSettings": ["serverName": "sni.example.com", "MASTER\u{212A}EYLOG": "/tmp/keys.log"],
            "finalmask": ["QUICPARAM\u{017F}": ["DEBUG": true]],
        ])
        let adapted = try XrayPanelConfiguration.adapt(root)
        #expect(!adapted.json.contains("/tmp/keys.log"))
        #expect(!adapted.json.contains("DEBUG"))
        #expect(adapted.droppedGeoEntries.contains("masterKeyLog"))
        #expect(adapted.droppedGeoEntries.contains("quicParams.debug"))
    }

    /// Поле верхнего уровня в другом написании приводится к каноническому: вход `socks`
    /// провайдера под ключом `inboundſ` не переживает адаптацию рядом с нашим TUN.
    @Test func rootFieldsAreCanonicalized() throws {
        let socks: [[String: Any]] = [["tag": "socks", "port": 10808, "listen": "127.0.0.1", "protocol": "socks"]]
        let adapted = try decode(XrayPanelConfiguration.adapt(config(["Inbound\u{017F}": socks])).json)
        #expect(adapted["Inbound\u{017F}"] == nil)
        let inbounds = try #require(adapted["inbounds"] as? [[String: Any]])
        #expect(inbounds.map { $0["protocol"] as? String } == ["tun"])

        var upperCase = config()
        upperCase.removeValue(forKey: "routing")
        upperCase["ROUTING"] = ["domainStrategy": "AsIs"]
        let renamed = try XrayConfigurationPolicy.sanitize(upperCase)
        #expect(renamed.root["ROUTING"] == nil)
        #expect((renamed.root["routing"] as? [String: Any])?["domainStrategy"] as? String == "AsIs")
    }

    /// Одно поле в нескольких написаниях: порядок применения в Xray неизвестен — отказ.
    /// Исключения: `log` (заменяется целиком) и `env` без противоречащих значений (Go объединяет).
    @Test func duplicateRootFields() throws {
        #expect(throws: XrayConfigurationPolicy.Failure.ambiguousKeys) {
            try XrayConfigurationPolicy.sanitize(config(["Routing": ["domainStrategy": "IPOnDemand"]]))
        }
        #expect(throws: XrayConfigurationPolicy.Failure.ambiguousKeys) {
            try XrayConfigurationPolicy.sanitize(config(["env": ["xray.buf.readv": "enable"], "ENV": ["xray.buf.readv": "disable"]]))
        }
        let merged = try XrayConfigurationPolicy.sanitize(config([
            "env": ["xray.buf.readv": "enable"], "Env": ["xray.vmess.padding": "true"], "LOG": ["loglevel": "debug"],
        ]))
        #expect(merged.root["Env"] == nil)
        #expect(merged.root["LOG"] == nil)
        let env = try #require(merged.root["env"] as? [String: String])
        #expect(env == ["xray.buf.readv": "enable", "xray.vmess.padding": "true"])

        let payload = try JSONSerialization.data(withJSONObject: [
            config(["remarks": "Clean"]),
            config(["remarks": "Ambiguous", "DNS": ["servers": ["1.1.1.1"]], "dns": ["servers": ["8.8.8.8"]]]),
        ])
        let result = try XrayJSONSubscriptionParser.parse(payload)
        #expect(result.servers.map(\.name) == ["Clean"])
        #expect(result.issues.first?.reason == XrayConfigurationPolicy.Failure.ambiguousKeys.localizedDescription)
    }

    /// `debug` убирается только у параметров QUIC и только со значением `true`: в том числе
    /// внутри массива (`quicConfig` резолверов XDNS), но не во вложенных объектах и не вне QUIC.
    @Test func quicDebugKeepsContext() throws {
        let root = config(
            ["dns": ["servers": ["1.1.1.1"], "debug": true]],
            stream: ["finalmask": [
                "quicParams": ["debug": true, "congestion": "brutal", "nested": ["debug": true]],
                "udp": [["type": "xdns", "settings": ["resolvers": [["quicConfig": ["debug": true, "maxIdleTimeout": 30]]]]]],
            ]]
        )
        let sanitized = try XrayConfigurationPolicy.sanitize(root)
        let outbound = try #require((sanitized.root["outbounds"] as? [[String: Any]])?.first)
        let stream = try #require(outbound["streamSettings"] as? [String: Any])
        let finalmask = try #require(stream["finalmask"] as? [String: Any])
        let quic = try #require(finalmask["quicParams"] as? [String: Any])
        #expect(quic["debug"] == nil)
        #expect(quic["congestion"] as? String == "brutal")
        #expect((quic["nested"] as? [String: Any])?["debug"] as? Bool == true)
        let udp = try #require(finalmask["udp"] as? [[String: Any]])
        let resolvers = try #require((udp.first?["settings"] as? [String: Any])?["resolvers"] as? [[String: Any]])
        let quicConfig = try #require(resolvers.first?["quicConfig"] as? [String: Any])
        #expect(quicConfig["debug"] == nil)
        #expect(quicConfig["maxIdleTimeout"] as? Int == 30)
        #expect((sanitized.root["dns"] as? [String: Any])?["debug"] as? Bool == true)
        #expect(sanitized.droppedParameters == ["quicParams.debug"])

        let off = try XrayConfigurationPolicy.sanitize(config(stream: ["finalmask": ["quicParams": ["debug": false]]]))
        #expect(off.droppedParameters.isEmpty)
        let offOutbound = try #require((off.root["outbounds"] as? [[String: Any]])?.first)
        let offStream = try #require(offOutbound["streamSettings"] as? [String: Any])
        let offQUIC = (offStream["finalmask"] as? [String: Any])?["quicParams"] as? [String: Any]
        #expect(offQUIC?["debug"] as? Bool == false)
    }

    /// Выключенный журнал ключей TLS (пусто или `none`) не меняется; любое другое значение убирается.
    @Test func masterKeyLogValues() throws {
        for value in ["", "none"] {
            let sanitized = try XrayConfigurationPolicy.sanitize(config(stream: ["tlsSettings": ["serverName": "sni.example.com", "masterKeyLog": value]]))
            #expect(sanitized.droppedParameters.isEmpty, "\(value)")
        }
        for value in ["None", "keys.log", "/tmp/keys.log"] {
            let sanitized = try XrayConfigurationPolicy.sanitize(config(stream: ["realitySettings": ["masterKeyLog": value]]))
            #expect(sanitized.droppedParameters == ["masterKeyLog"], "\(value)")
        }
    }

    /// В `env` остаются только имена, которые Xray читает для разрешённых флагов (`xray.buf.readv`
    /// и `XRAY_BUF_READV`). Другое написание, пробелы и `xray.tun.fd` от провайдера убираются.
    @Test func environmentNameVariants() throws {
        let sanitized = try XrayConfigurationPolicy.sanitize(config(["env": [
            "xray.buf.readv": "enable",
            "XRAY_BUF_SPLICE": "enable",
            "Xray.Buf.Readv": "disable",
            " xray.vmess.padding": "true",
            "xray_buf_readv": "disable",
            "xray.tun.fd": "5",
            "XRAY_TUN_FD": "5",
        ]]))
        let env = try #require(sanitized.root["env"] as? [String: String])
        #expect(env == ["xray.buf.readv": "enable", "XRAY_BUF_SPLICE": "enable"])
        #expect(sanitized.droppedParameters.contains("env.XRAY_TUN_FD"))
        #expect(sanitized.droppedParameters.contains("env.xray.tun.fd"))

        let prepared = try decode(XrayRuntimeConfiguration.prepare(
            json(config(["env": ["XRAY_TUN_FD": "5"]])), tunFileDescriptor: 9, resolvedAddresses: [:]
        ))
        #expect((prepared["env"] as? [String: String]) == ["xray.tun.fd": "9"])
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

    /// Каталог с именем файла диагностики (не наш файл) не удаляется; отсутствующий каталог —
    /// не ошибка.
    @Test func keepsUnexpectedItems() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("Tunnel-\(UUID().uuidString)", isDirectory: true)
        #expect(LegacyDiagnosticsCleanup.removeFiles(in: directory))
        let lookalike = directory.appendingPathComponent("diagnostics.json", isDirectory: true)
        try manager.createDirectory(at: lookalike, withIntermediateDirectories: true)
        #expect(LegacyDiagnosticsCleanup.removeFiles(in: directory))
        #expect(manager.fileExists(atPath: lookalike.path))
        try manager.removeItem(at: directory)
    }

    /// Без контейнера App Group или его настроек очистка не считается выполненной
    /// и повторится при следующем запуске.
    @Test func unavailableContainerIsRetried() throws {
        let suite = "LegacyDiagnosticsCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LegacyDiagnosticsCleanup.runIfNeeded(defaults: defaults, groupDefaults: defaults, tunnelDirectory: nil)
        #expect(!defaults.bool(forKey: LegacyDiagnosticsCleanup.completedKey))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Tunnel-\(UUID().uuidString)")
        LegacyDiagnosticsCleanup.runIfNeeded(defaults: defaults, groupDefaults: nil, tunnelDirectory: directory)
        #expect(!defaults.bool(forKey: LegacyDiagnosticsCleanup.completedKey))
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
