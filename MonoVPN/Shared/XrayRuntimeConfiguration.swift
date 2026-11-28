import Foundation

/// Подготовка конфигурации Xray к запуску внутри расширения Packet Tunnel.
///
/// Чистые функции над JSON (без LibXray), поэтому лежат в Shared и покрыты тестами приложения.
enum XrayRuntimeConfiguration {
    /// Ошибки подготовки конфигурации. Тексты не содержат значений из конфигурации.
    enum Failure: Error, Equatable {
        /// Конфигурация не является JSON-объектом.
        case notAnObject
    }

    /// Имена серверов (не IP) во всех outbound, без повторов, в порядке появления.
    ///
    /// У сервера из ссылки это одно имя; у конфига из JSON-подписки с балансировщиком —
    /// десятки. Расширение разрешает их до применения сетевых настроек туннеля.
    static func serverHosts(in json: String) throws -> [String] {
        let root = try object(json)
        var hosts: [String] = []
        for outbound in root["outbounds"] as? [[String: Any]] ?? [] {
            for host in addresses(of: outbound) where !isIPAddress(host) && !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts
    }

    /// Применяет `XrayConfigurationPolicy` (журналы выключены, Lua-скрипты запрещены),
    /// подставляет дескриптор TUN в `env["xray.tun.fd"]` и, для имён из `resolvedAddresses`,
    /// заранее разрешённые IP вместо имён серверов.
    ///
    /// Перед заменой адреса имя явно закрепляется там, где Xray взял бы его из адреса:
    /// SNI для TLS/REALITY, Host для WebSocket/HTTPUpgrade/XHTTP, `:authority` для gRPC без
    /// TLS. Поэтому замена на IP не меняет того, что видит сервер.
    ///
    /// Бросает `XrayConfigurationPolicy.Failure.luaScript`, если конфигурация содержит Lua-скрипт.
    static func prepare(
        _ json: String,
        tunFileDescriptor: Int32,
        resolvedAddresses: [String: String]
    ) throws -> String {
        var root = try XrayConfigurationPolicy.sanitize(object(json)).root
        var env = root["env"] as? [String: Any] ?? [:]
        env[XrayTunnelLayout.tunFdEnvKey] = String(tunFileDescriptor)
        root["env"] = env

        if !resolvedAddresses.isEmpty, let outbounds = root["outbounds"] as? [[String: Any]] {
            root["outbounds"] = outbounds.map { replacingAddresses(in: $0, with: resolvedAddresses) }
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let result = String(data: data, encoding: .utf8) else { throw Failure.notAnObject }
        return result
    }

    /// Адреса серверов outbound: `settings.vnext[].address`, `settings.servers[].address`
    /// или плоский `settings.address` (новый формат Xray).
    private static func addresses(of outbound: [String: Any]) -> [String] {
        guard let settings = outbound["settings"] as? [String: Any] else { return [] }
        var result: [String] = []
        for key in ["vnext", "servers"] {
            for entry in settings[key] as? [[String: Any]] ?? [] {
                if let address = entry["address"] as? String, !address.isEmpty {
                    result.append(address)
                }
            }
        }
        if let address = settings["address"] as? String, !address.isEmpty {
            result.append(address)
        }
        return result
    }

    /// Outbound с IP вместо имён и закреплёнными SNI/Host.
    private static func replacingAddresses(in original: [String: Any], with resolved: [String: String]) -> [String: Any] {
        var outbound = original
        guard var settings = outbound["settings"] as? [String: Any] else { return outbound }
        var replacedHost: String?

        func replace(_ entry: inout [String: Any]) {
            guard let address = entry["address"] as? String, let ip = resolved[address] else { return }
            entry["address"] = ip
            replacedHost = replacedHost ?? address
        }
        for key in ["vnext", "servers"] {
            if var entries = settings[key] as? [[String: Any]] {
                for index in entries.indices {
                    replace(&entries[index])
                }
                settings[key] = entries
            }
        }
        replace(&settings)
        guard let host = replacedHost else { return outbound }
        outbound["settings"] = settings
        outbound["streamSettings"] = pinningNames(in: outbound["streamSettings"] as? [String: Any] ?? [:], host: host)
        return outbound
    }

    /// Задаёт SNI/Host/authority именем сервера там, где они не заданы явно.
    private static func pinningNames(in original: [String: Any], host: String) -> [String: Any] {
        var stream = original
        let security = (stream["security"] as? String ?? "none").lowercased()
        var serverName: String?
        for key in ["tlsSettings", "realitySettings"] where security == (key == "tlsSettings" ? "tls" : "reality") {
            var settings = stream[key] as? [String: Any] ?? [:]
            if (settings["serverName"] as? String ?? "").isEmpty {
                settings["serverName"] = host
            }
            serverName = settings["serverName"] as? String
            stream[key] = settings
        }

        switch (stream["network"] as? String ?? "tcp").lowercased() {
        case "ws", "websocket":
            var ws = stream["wsSettings"] as? [String: Any] ?? [:]
            let headerHost = (ws["headers"] as? [String: Any])?.first { $0.key.lowercased() == "host" }?.value as? String
            if (ws["host"] as? String ?? "").isEmpty, (headerHost ?? "").isEmpty {
                ws["host"] = host
            }
            stream["wsSettings"] = ws
        case "httpupgrade":
            var upgrade = stream["httpupgradeSettings"] as? [String: Any] ?? [:]
            if (upgrade["host"] as? String ?? "").isEmpty {
                upgrade["host"] = host
            }
            stream["httpupgradeSettings"] = upgrade
        case "xhttp", "splithttp":
            // Xray берёт Host из SNI (TLS/REALITY), иначе из адреса.
            let key = stream["xhttpSettings"] != nil || stream["splithttpSettings"] == nil ? "xhttpSettings" : "splithttpSettings"
            var xhttp = stream[key] as? [String: Any] ?? [:]
            if (xhttp["host"] as? String ?? "").isEmpty {
                xhttp["host"] = serverName ?? host
            }
            stream[key] = xhttp
        case "grpc", "gun":
            if serverName == nil {
                var grpc = stream["grpcSettings"] as? [String: Any] ?? [:]
                if (grpc["authority"] as? String ?? "").isEmpty {
                    grpc["authority"] = host
                }
                stream["grpcSettings"] = grpc
            }
        default:
            break
        }
        return stream
    }

    /// Является ли строка IPv4- или IPv6-адресом.
    static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
    }

    /// Разбирает JSON-объект.
    private static func object(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.notAnObject
        }
        return root
    }
}

/// Убирает из текста ошибки ядра то, что может оказаться секретом или приватным адресом:
/// UUID, длинные токены (ключи, пароли в Base64), URL, IP-адреса. Текст показывается
/// пользователю в приложении и виджете (через общий Keychain) и больше никуда не попадает.
enum TunnelErrorSanitizer {
    /// Максимальная длина сохраняемого текста.
    static let maxLength = 300

    /// Очищенный и укороченный текст.
    static func sanitize(_ message: String) -> String {
        var text = message
        let patterns = [
            // URL целиком (могут содержать токены подписки).
            #"[A-Za-z][A-Za-z0-9+.-]*://\S+"#,
            // UUID.
            #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            // IPv6 (упрощённо: группы hex через двоеточия, минимум три группы).
            #"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{0,4}\b"#,
            // IPv4.
            #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#,
            // Длинные токены: ключи REALITY, пароли, Base64.
            #"[A-Za-z0-9+/_=-]{20,}"#,
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "•••", options: .regularExpression)
        }
        if text.count > maxLength {
            text = String(text.prefix(maxLength)) + "…"
        }
        return text
    }
}
