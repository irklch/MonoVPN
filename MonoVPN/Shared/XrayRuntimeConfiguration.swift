import Foundation

/// Подготовка конфигурации Xray к запуску внутри расширения Packet Tunnel.
///
/// Чистые функции над JSON (без LibXray), поэтому лежат в Shared и покрыты тестами приложения.
enum XrayRuntimeConfiguration {
    /// Ошибки подготовки конфигурации. Тексты не содержат значений из конфигурации.
    enum Failure: Error, Equatable {
        /// Конфигурация не является JSON-объектом.
        case notAnObject
        /// В конфигурации нет outbound прокси с адресом сервера.
        case missingServer
    }

    /// Адрес сервера из первого outbound (`settings.vnext[0]` для VLESS/VMess,
    /// `settings.servers[0]` для Trojan/Shadowsocks).
    static func serverAddress(in json: String) throws -> String {
        let root = try object(json)
        guard let address = serverEntry(in: root)?["address"] as? String, !address.isEmpty else {
            throw Failure.missingServer
        }
        return address
    }

    /// Подставляет дескриптор TUN в `env["xray.tun.fd"]` и, если передан, IP сервера вместо имени.
    ///
    /// SNI и заголовки Host генератор уже задал явно, поэтому замена адреса на IP не меняет
    /// того, что видит сервер.
    ///
    /// `errorLogPath` — файл журнала ошибок (`log.error`, см. `XrayErrorLog`); `nil` — не менять.
    static func prepare(
        _ json: String,
        tunFileDescriptor: Int32,
        resolvedServerAddress: String?,
        errorLogPath: String? = nil
    ) throws -> String {
        var root = try object(json)
        var env = root["env"] as? [String: Any] ?? [:]
        env[XrayTunnelLayout.tunFdEnvKey] = String(tunFileDescriptor)
        root["env"] = env

        if let errorLogPath {
            var log = root["log"] as? [String: Any] ?? [:]
            log["error"] = errorLogPath
            root["log"] = log
        }

        if let resolvedServerAddress,
           var outbounds = root["outbounds"] as? [[String: Any]], !outbounds.isEmpty,
           var settings = outbounds[0]["settings"] as? [String: Any] {
            for key in ["vnext", "servers"] {
                if var entries = settings[key] as? [[String: Any]], !entries.isEmpty {
                    entries[0]["address"] = resolvedServerAddress
                    settings[key] = entries
                }
            }
            outbounds[0]["settings"] = settings
            root["outbounds"] = outbounds
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let result = String(data: data, encoding: .utf8) else { throw Failure.notAnObject }
        return result
    }

    /// Разбирает JSON-объект.
    private static func object(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.notAnObject
        }
        return root
    }

    /// Первая запись сервера в первом outbound.
    private static func serverEntry(in root: [String: Any]) -> [String: Any]? {
        guard let outbounds = root["outbounds"] as? [[String: Any]],
              let settings = outbounds.first?["settings"] as? [String: Any] else { return nil }
        for key in ["vnext", "servers"] {
            if let entries = settings[key] as? [[String: Any]], let first = entries.first {
                return first
            }
        }
        return nil
    }
}

/// Убирает из текста ошибки ядра то, что может оказаться секретом или приватным адресом:
/// UUID, длинные токены (ключи, пароли в Base64), URL, IP-адреса. Текст показывается
/// в приложении и сохраняется в диагностике.
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
