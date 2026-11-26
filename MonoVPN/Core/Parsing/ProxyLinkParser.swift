import CryptoKit
import Foundation

/// Ошибки разбора одной прокси-ссылки. Описания показываются пользователю.
///
/// Делятся на два вида (`isCoreLimitation`): ссылка испорчена — запись пропускается и попадает
/// только в диагностику; ссылка корректна, но использует возможность, которой нет в подключённом
/// sing-box, — сервер показывается в списке как «Не поддерживается».
enum ProxyLinkError: LocalizedError, Codable, Hashable, Sendable {
    /// Схема ссылки не поддерживается (в значении — сама схема).
    case unsupportedScheme(String)
    /// Ссылка синтаксически испорчена.
    case malformed
    /// В ссылке нет адреса сервера.
    case missingHost
    /// Порт отсутствует или вне диапазона 1...65535.
    case invalidPort
    /// UUID пользователя некорректен.
    case invalidUUID
    /// Нет пароля (Trojan / Shadowsocks).
    case missingPassword
    /// Шифрование VLESS, отличное от `none`.
    case unsupportedEncryption(String)
    /// Неподдерживаемый режим security (не none / tls / reality).
    case unsupportedSecurity(String)
    /// Неподдерживаемый транспорт.
    case unsupportedTransport(String)
    /// Маскировка заголовков TCP (`headerType`), которую sing-box не поддерживает.
    case unsupportedHeaderType(String)
    /// Неподдерживаемый flow (поддерживается только `xtls-rprx-vision`).
    case unsupportedFlow(String)
    /// Flow указан без TLS/REALITY или не на TCP.
    case flowRequiresTLS
    /// Публичный ключ REALITY некорректен.
    case invalidRealityPublicKey
    /// Short ID REALITY некорректен.
    case invalidRealityShortID
    /// Шифр Shadowsocks, которого нет в sing-box.
    case unsupportedShadowsocksMethod(String)
    /// Плагин Shadowsocks, которого нет в sing-box (поддерживаются `obfs-local` и `v2ray-plugin` в режиме websocket).
    case unsupportedShadowsocksPlugin(String)
    /// gRPC `authority` отличается от SNI: в sing-box (gRPC lite) `:authority` всегда равен SNI или адресу сервера.
    case unsupportedGRPCAuthority(String)

    /// Ссылка корректна, но требует возможности, которой нет в подключённом ядре.
    var isCoreLimitation: Bool {
        switch self {
        case .unsupportedEncryption, .unsupportedSecurity, .unsupportedTransport, .unsupportedHeaderType,
             .unsupportedFlow, .flowRequiresTLS, .unsupportedShadowsocksMethod, .unsupportedShadowsocksPlugin,
             .unsupportedGRPCAuthority:
            true
        case .unsupportedScheme, .malformed, .missingHost, .invalidPort, .invalidUUID, .missingPassword,
             .invalidRealityPublicKey, .invalidRealityShortID:
            false
        }
    }

    /// Локализованный текст ошибки для интерфейса.
    var errorDescription: String? {
        switch self {
        case let .unsupportedScheme(scheme):
            String(localized: "error.link.unsupportedScheme \(scheme)")
        case .malformed:
            String(localized: "error.link.malformed")
        case .missingHost:
            String(localized: "error.link.missingHost")
        case .invalidPort:
            String(localized: "error.link.invalidPort")
        case .invalidUUID:
            String(localized: "error.link.invalidUUID")
        case .missingPassword:
            String(localized: "error.link.missingPassword")
        case let .unsupportedEncryption(value):
            String(localized: "error.link.unsupportedEncryption \(value)")
        case let .unsupportedSecurity(value):
            String(localized: "error.link.unsupportedSecurity \(value)")
        case let .unsupportedTransport(value):
            String(localized: "error.link.unsupportedTransport \(value)")
        case let .unsupportedHeaderType(value):
            String(localized: "error.link.unsupportedHeaderType \(value)")
        case let .unsupportedFlow(value):
            String(localized: "error.link.unsupportedFlow \(value)")
        case .flowRequiresTLS:
            String(localized: "error.link.flowRequiresTLS")
        case .invalidRealityPublicKey:
            String(localized: "error.link.invalidRealityPublicKey")
        case .invalidRealityShortID:
            String(localized: "error.link.invalidRealityShortID")
        case let .unsupportedShadowsocksMethod(value):
            String(localized: "error.link.unsupportedShadowsocksMethod \(value)")
        case let .unsupportedShadowsocksPlugin(value):
            String(localized: "error.link.unsupportedShadowsocksPlugin \(value)")
        case let .unsupportedGRPCAuthority(value):
            String(localized: "error.link.unsupportedGRPCAuthority \(value)")
        }
    }
}

/// Разбирает отдельные прокси-ссылки: `vless://`, `vmess://`, `trojan://`, `ss://`.
///
/// Применяются только параметры, которые подключённый sing-box (1.14.4, см. `Frameworks/LIBBOX_VERSION`)
/// может выполнить. Если игнорирование параметра привело бы к подключению не так, как задумал
/// провайдер (транспорт, маскировка, authority, ...), сервер помечается неподдерживаемым
/// (`ServerConfiguration.incompatibility`) — без подмены транспорта. Безвредные неприменённые
/// параметры попадают в `ServerConfiguration.ignoredParameters` (только имена ключей).
enum ProxyLinkParser {
    /// Схемы ссылок, которые умеет разбирать парсер.
    static let supportedSchemes: Set<String> = ["vless", "vmess", "trojan", "ss"]

    /// Отпечатки uTLS, которые принимает sing-box.
    static let supportedFingerprints: Set<String> = [
        "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized",
    ]

    /// Методы Shadowsocks, реализованные ядром текущей сборки (AEAD и 2022).
    static var supportedShadowsocksMethods: Set<String> { VPNCore.current.shadowsocksMethods }

    /// Плагины Shadowsocks (SIP003), встроенные в sing-box; ключ — имя из ссылки, значение — имя в sing-box.
    static let supportedShadowsocksPlugins: [String: String] = [
        "obfs-local": "obfs-local", "simple-obfs": "obfs-local", "v2ray-plugin": "v2ray-plugin",
    ]

    /// Ключи query, несущие только метаданные; их можно пропускать без предупреждения.
    private static let informationalKeys: Set<String> = ["remarks", "remark", "encryption"]

    /// Является ли строка ссылкой одной из поддерживаемых схем.
    static func isProxyLink(_ string: String) -> Bool {
        guard let scheme = scheme(of: string) else { return false }
        return supportedSchemes.contains(scheme)
    }

    /// Разбирает ссылку в проверенную конфигурацию сервера, выбирая парсер по схеме.
    static func parse(_ rawLink: String) throws -> ServerConfiguration {
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = scheme(of: link) else { throw ProxyLinkError.malformed }
        switch scheme {
        case "vless": return try parseVLESS(link)
        case "trojan": return try parseTrojan(link)
        case "vmess": return try parseVMess(link)
        case "ss": return try parseShadowsocks(link)
        default: throw ProxyLinkError.unsupportedScheme(scheme)
        }
    }

    /// Отображаемое имя из фрагмента ссылки (для VMess — поле `ps`), если есть. Используется в сообщениях об ошибках.
    static func displayName(of rawLink: String) -> String? {
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if scheme(of: link) == "vmess",
           let json = vmessJSON(link),
           let name = json["ps"] as? String, !name.isEmpty {
            return name
        }
        guard let hashIndex = link.lastIndex(of: "#") else { return nil }
        let fragment = String(link[link.index(after: hashIndex)...])
        let name = (fragment.removingPercentEncoding ?? fragment).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - VLESS

    /// Разбирает `vless://uuid@host:port?...#name`: UUID, транспорт, TLS/REALITY и flow.
    private static func parseVLESS(_ link: String) throws -> ServerConfiguration {
        let parts = try URLParts(link)
        guard let uuid = parts.user, isValidUUID(uuid) else { throw ProxyLinkError.invalidUUID }
        var query = parts.query

        var server = ServerConfiguration(
            id: stableID(for: link),
            name: parts.name ?? parts.host,
            proxyProtocol: .vless,
            host: parts.host,
            port: parts.port,
            uuid: uuid
        )
        try applyCoreFeatures(to: &server) { server in
            if let encryption = query.removeValue(forKey: "encryption"), !encryption.isEmpty, encryption != "none" {
                // Новое шифрование VLESS Xray содержит ключ: в сообщение идёт только имя алгоритма.
                throw ProxyLinkError.unsupportedEncryption(String(encryption.split(separator: ".").first ?? ""))
            }
            try applyTransport(from: &query, to: &server)
            server.tls = try tls(from: &query, defaultSecurity: "none", ignored: &server.ignoredParameters)
            try applyGRPCAuthority(from: &query, to: &server)

            if let flow = query.removeValue(forKey: "flow"), !flow.isEmpty {
                guard flow == "xtls-rprx-vision" else { throw ProxyLinkError.unsupportedFlow(flow) }
                if server.transport != .tcp, VPNCore.current.dropsFlowOnNonTCPTransport {
                    // Xray выполняет Vision только поверх TCP: на других транспортах flow не передаётся.
                    server.ignoredParameters.append("flow")
                } else {
                    guard server.tls != nil, server.transport == .tcp else { throw ProxyLinkError.flowRequiresTLS }
                    server.flow = flow
                }
            }
        }
        server.ignoredParameters += remainingParameters(query)
        return server
    }

    // MARK: - Trojan

    /// Разбирает `trojan://password@host:port?...#name`; TLS включён по умолчанию.
    private static func parseTrojan(_ link: String) throws -> ServerConfiguration {
        let parts = try URLParts(link)
        guard let password = parts.user, !password.isEmpty else { throw ProxyLinkError.missingPassword }
        var query = parts.query

        var server = ServerConfiguration(
            id: stableID(for: link),
            name: parts.name ?? parts.host,
            proxyProtocol: .trojan,
            host: parts.host,
            port: parts.port,
            password: password
        )
        try applyCoreFeatures(to: &server) { server in
            try applyTransport(from: &query, to: &server)
            // Trojan по определению работает через TLS, если это явно не отключено.
            server.tls = try tls(from: &query, defaultSecurity: "tls", ignored: &server.ignoredParameters)
            try applyGRPCAuthority(from: &query, to: &server)
            if let flow = query.removeValue(forKey: "flow"), !flow.isEmpty {
                throw ProxyLinkError.unsupportedFlow(flow)
            }
        }
        server.ignoredParameters += remainingParameters(query)
        return server
    }

    // MARK: - VMess (v2rayN, JSON в Base64)

    /// Разбирает `vmess://base64(JSON)` в формате v2rayN, сводя поля JSON к параметрам как у VLESS.
    private static func parseVMess(_ link: String) throws -> ServerConfiguration {
        guard let json = vmessJSON(link) else { throw ProxyLinkError.malformed }

        /// Читает поле JSON как непустую строку (числа тоже приводятся к строке).
        func string(_ key: String) -> String? {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let value = json[key] as? NSNumber { return value.stringValue }
            return nil
        }

        guard let host = string("add") else { throw ProxyLinkError.missingHost }
        guard let portString = string("port"), let port = Int(portString), (1...65535).contains(port) else {
            throw ProxyLinkError.invalidPort
        }
        guard let uuid = string("id"), isValidUUID(uuid) else { throw ProxyLinkError.invalidUUID }

        // Переносим JSON на тот же словарь параметров query, что и у ссылок VLESS.
        var query: [String: String] = [:]
        query["type"] = string("net") ?? "tcp"
        query["headerType"] = string("type")
        query["host"] = string("host")
        query["path"] = string("path")
        query["security"] = string("tls") ?? "none"
        query["sni"] = string("sni")
        query["alpn"] = string("alpn")
        query["fp"] = string("fp")
        if query["type"] == "grpc" {
            query["serviceName"] = string("path")
            query["authority"] = string("authority")
            query["path"] = nil
            if let mode = string("type"), mode != "gun", mode != "none" {
                query["mode"] = mode
            }
            query["headerType"] = nil
        }
        if query["type"] == "xhttp" || query["type"] == "splithttp" {
            // v2rayN хранит режим XHTTP в поле `type`.
            query["mode"] = string("type")
            query["headerType"] = nil
        }
        query = query.compactMapValues { $0 }

        var server = ServerConfiguration(
            id: stableID(for: link),
            name: string("ps") ?? host,
            proxyProtocol: .vmess,
            host: stripBrackets(host),
            port: port,
            uuid: uuid,
            vmessSecurity: string("scy") ?? "auto",
            vmessAlterID: string("aid").flatMap(Int.init) ?? 0
        )
        try applyCoreFeatures(to: &server) { server in
            try applyTransport(from: &query, to: &server)
            server.tls = try tls(from: &query, defaultSecurity: "none", ignored: &server.ignoredParameters)
            try applyGRPCAuthority(from: &query, to: &server)
        }
        server.ignoredParameters += remainingParameters(query)
        return server
    }

    /// Декодирует Base64-JSON из ссылки VMess (без фрагмента); `nil`, если это не JSON-объект.
    private static func vmessJSON(_ link: String) -> [String: Any]? {
        guard let range = link.range(of: "://") else { return nil }
        var payload = String(link[range.upperBound...])
        if let hash = payload.firstIndex(of: "#") { payload = String(payload[..<hash]) }
        guard let data = Base64.decode(payload),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Shadowsocks (SIP002 и старый формат)

    /// Разбирает `ss://` в формате SIP002 и в старом формате `ss://base64(method:password@host:port)`.
    ///
    /// Проверяет, что метод поддерживается sing-box; плагины отклоняются.
    private static func parseShadowsocks(_ link: String) throws -> ServerConfiguration {
        guard let range = link.range(of: "://") else { throw ProxyLinkError.malformed }
        var body = String(link[range.upperBound...])
        var name: String?
        if let hash = body.lastIndex(of: "#") {
            let fragment = String(body[body.index(after: hash)...])
            name = fragment.removingPercentEncoding ?? fragment
            body = String(body[..<hash])
        }

        // Старый формат: ss://base64(method:password@host:port)
        if !body.contains("@"), let decoded = Base64.decodeString(body.components(separatedBy: "?")[0]) {
            body = decoded
        }

        let normalized = "ss://" + body + (name.map { "#" + ($0.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") } ?? "")
        let parts = try URLParts(normalized)
        var query = parts.query

        // userinfo — это либо base64url(method:password) (SIP002), либо просто method:password.
        guard let rawUser = parts.rawUser, !rawUser.isEmpty else { throw ProxyLinkError.missingPassword }
        let userInfo: String
        if let password = parts.password {
            userInfo = (rawUser.removingPercentEncoding ?? rawUser) + ":" + password
        } else if let decoded = Base64.decodeString(rawUser), decoded.contains(":") {
            userInfo = decoded
        } else {
            userInfo = rawUser.removingPercentEncoding ?? rawUser
        }
        guard let separator = userInfo.firstIndex(of: ":") else { throw ProxyLinkError.missingPassword }
        let method = userInfo[..<separator].lowercased()
        let password = String(userInfo[userInfo.index(after: separator)...])
        guard !password.isEmpty else { throw ProxyLinkError.missingPassword }

        var server = ServerConfiguration(
            id: stableID(for: link),
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? parts.host,
            proxyProtocol: .shadowsocks,
            host: parts.host,
            port: parts.port,
            password: password,
            method: method
        )
        try applyCoreFeatures(to: &server) { server in
            guard VPNCore.current.shadowsocksMethods.contains(method) else {
                throw ProxyLinkError.unsupportedShadowsocksMethod(method)
            }
            if let plugin = query.removeValue(forKey: "plugin"), !plugin.isEmpty {
                try applyShadowsocksPlugin(plugin, to: &server)
            }
        }
        server.ignoredParameters += remainingParameters(query)
        return server
    }

    /// SIP002 `plugin=name;opts`: `obfs-local`/`simple-obfs` и `v2ray-plugin` (только websocket —
    /// режим QUIC в sing-box не реализован). Остальные плагины — ограничение ядра.
    private static func applyShadowsocksPlugin(_ plugin: String, to server: inout ServerConfiguration) throws {
        let name = plugin.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
        let options = plugin.dropFirst(name.count).drop { $0 == ";" }
        guard VPNCore.current.supportsShadowsocksPlugins, let coreName = supportedShadowsocksPlugins[name.lowercased()] else {
            throw ProxyLinkError.unsupportedShadowsocksPlugin(name)
        }
        if coreName == "v2ray-plugin", options.split(separator: ";").contains(where: { $0.lowercased() == "mode=quic" }) {
            throw ProxyLinkError.unsupportedShadowsocksPlugin("v2ray-plugin mode=quic")
        }
        server.shadowsocksPlugin = coreName
        server.shadowsocksPluginOptions = options.isEmpty ? nil : String(options)
    }

    // MARK: - Общие параметры в стиле V2Ray

    /// Применяет параметры, зависящие от возможностей ядра (транспорт, TLS, flow, плагины).
    ///
    /// Ограничение ядра не отбрасывает сервер: он остаётся в списке с `incompatibility`
    /// и базовыми полями, а частично применённые настройки не сохраняются. Ошибки самой
    /// ссылки (битый ключ REALITY и т. п.) пробрасываются дальше.
    private static func applyCoreFeatures(
        to server: inout ServerConfiguration,
        _ body: (inout ServerConfiguration) throws -> Void
    ) throws {
        var candidate = server
        do {
            try body(&candidate)
            server = candidate
        } catch let error as ProxyLinkError where error.isCoreLimitation {
            server.incompatibility = error
        }
    }

    /// Применяет gRPC `authority` (Xray).
    ///
    /// Xray-core передаёт `:authority` независимо от SNI (`transport/internet/grpc/dial.go`), поэтому
    /// для него значение сохраняется в `grpcAuthority`, если отличается от SNI. В sing-box 1.14.4
    /// без тега `with_grpc` используется gRPC lite, который всегда отправляет `:authority` = SNI
    /// (или адрес сервера без TLS) с портом; совпадающий authority применяется как есть,
    /// отличающийся — ограничение ядра.
    private static func applyGRPCAuthority(from query: inout [String: String], to server: inout ServerConfiguration) throws {
        guard let authority = query.removeValue(forKey: "authority")?.trimmingCharacters(in: .whitespaces),
              !authority.isEmpty else { return }
        guard case .grpc = server.transport else { return } // вне gRPC параметр ничего не значит
        let effective = (server.tls?.serverName ?? server.host).lowercased()
        let requested = stripPort(authority, port: server.port).lowercased()
        if requested == effective || requested == "[\(effective)]" {
            return
        }
        guard VPNCore.current.supportsIndependentGRPCAuthority else {
            throw ProxyLinkError.unsupportedGRPCAuthority(authority)
        }
        server.grpcAuthority = authority
    }

    /// Убирает из authority порт сервера (`host:443` → `host`).
    private static func stripPort(_ authority: String, port: Int) -> String {
        let suffix = ":\(port)"
        return authority.hasSuffix(suffix) ? String(authority.dropLast(suffix.count)) : authority
    }

    /// Извлекает из query параметры транспорта (`type`, `host`, `path`, `headerType`, ...) и удаляет их.
    ///
    /// Пустые значения необязательных параметров равны их отсутствию. Неподдерживаемые, но
    /// безвредные параметры дописываются в `ignored`; транспорт или маскировка заголовков,
    /// которых нет в ядре текущей сборки (XHTTP/SplitHTTP без Xray, QUIC, mKCP, TCP `headerType=http`), —
    /// ограничение ядра,
    /// другой транспорт вместо них не подставляется.
    private static func applyTransport(from query: inout [String: String], to server: inout ServerConfiguration) throws {
        server.transport = try transport(from: &query, ignored: &server.ignoredParameters, extra: &server.xhttpExtra)
    }

    /// Разбирает транспорт; для XHTTP дополнительно возвращает `extra` (JSON-объект) в `extra`.
    private static func transport(
        from query: inout [String: String],
        ignored: inout [String],
        extra: inout String?
    ) throws -> TransportSettings {
        let type = (query.removeValue(forKey: "type") ?? "tcp").lowercased()
        let host = query.removeValue(forKey: "host").flatMap { $0.isEmpty ? nil : $0 }
        let path = query.removeValue(forKey: "path").map { $0.isEmpty ? "/" : $0 }
        let headerType = query.removeValue(forKey: "headerType").flatMap { $0.isEmpty ? nil : $0.lowercased() }

        switch type {
        case "tcp", "raw", "":
            if let headerType, headerType != "none" {
                throw ProxyLinkError.unsupportedHeaderType(headerType)
            }
            return .tcp
        case "ws", "websocket":
            var resolvedPath = path ?? "/"
            var earlyData: Int?
            // Early data в стиле Xray: путь "/ws?ed=2048".
            if let questionMark = resolvedPath.firstIndex(of: "?"),
               let components = URLComponents(string: "http://x/?" + String(resolvedPath[resolvedPath.index(after: questionMark)...])),
               let ed = components.queryItems?.first(where: { $0.name == "ed" })?.value.flatMap(Int.init) {
                earlyData = ed
                resolvedPath = String(resolvedPath[..<questionMark])
            }
            return .webSocket(path: resolvedPath, host: host, maxEarlyData: earlyData)
        case "grpc", "gun":
            let serviceName = query.removeValue(forKey: "serviceName").flatMap { $0.isEmpty ? nil : $0 }
                ?? path.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
            // multi-сервер Xray принимает и обычный gun-поток, поэтому mode=multi безвреден.
            if let mode = query.removeValue(forKey: "mode"), !mode.isEmpty, mode != "gun" {
                ignored.append("mode")
            }
            // `authority` проверяется после TLS в `applyGRPCAuthority`.
            return .grpc(serviceName: serviceName)
        case "http", "h2":
            guard VPNCore.current.supportsHTTP2Transport else { throw ProxyLinkError.unsupportedTransport(type) }
            let hosts = host.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
            return .http(path: path ?? "/", hosts: hosts)
        case "httpupgrade":
            return .httpUpgrade(path: path ?? "/", host: host)
        case "xhttp", "splithttp":
            guard VPNCore.current.supportsXHTTP else { throw ProxyLinkError.unsupportedTransport(type) }
            let mode = query.removeValue(forKey: "mode").flatMap { $0.isEmpty ? nil : $0.lowercased() }
            if let rawExtra = query.removeValue(forKey: "extra"), !rawExtra.isEmpty {
                // `extra` — JSON-объект с дополнительными настройками XHTTP; иначе он не применяется.
                if let data = rawExtra.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
                    extra = rawExtra
                } else {
                    ignored.append("extra")
                }
            }
            return .xhttp(path: path ?? "/", host: host, mode: mode)
        default:
            throw ProxyLinkError.unsupportedTransport(type)
        }
    }

    /// Извлекает из query параметры TLS / REALITY (`security`, `sni`, `alpn`, `fp`, `pbk`, `sid`, ...) и удаляет их.
    ///
    /// Возвращает `nil` для соединения без TLS. Попытки отключить проверку сертификата
    /// и неизвестные отпечатки не применяются, а попадают в `ignored`.
    private static func tls(from query: inout [String: String], defaultSecurity: String, ignored: inout [String]) throws -> TLSSettings? {
        let security = (query.removeValue(forKey: "security") ?? defaultSecurity).lowercased()
        let sni = query.removeValue(forKey: "sni").flatMap { $0.isEmpty ? nil : $0 }
            ?? query.removeValue(forKey: "peer").flatMap { $0.isEmpty ? nil : $0 }
        query.removeValue(forKey: "peer")
        let alpn = query.removeValue(forKey: "alpn")
            .map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        var fingerprint = query.removeValue(forKey: "fp").flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let publicKey = query.removeValue(forKey: "pbk")
        let shortID = query.removeValue(forKey: "sid") ?? ""
        let spiderX = query.removeValue(forKey: "spx")

        // Проверка сертификата никогда не отключается: вместо этого сообщаем о параметре.
        for key in ["allowInsecure", "insecure", "allowinsecure"] {
            if let value = query.removeValue(forKey: key), value == "1" || value.lowercased() == "true" {
                ignored.append(key)
            }
        }

        if let fp = fingerprint, !supportedFingerprints.contains(fp) {
            ignored.append("fp")
            fingerprint = "chrome"
        }

        switch security {
        case "none", "":
            return nil
        case "tls", "xtls":
            return TLSSettings(serverName: sni, alpn: alpn, fingerprint: fingerprint)
        case "reality":
            guard let publicKey, isValidRealityPublicKey(publicKey) else { throw ProxyLinkError.invalidRealityPublicKey }
            guard isValidShortID(shortID) else { throw ProxyLinkError.invalidRealityShortID }
            if let spiderX, !spiderX.isEmpty, spiderX != "/" {
                ignored.append("spx")
            }
            // REALITY в sing-box требует uTLS; chrome совпадает со значением по умолчанию в Xray.
            return TLSSettings(
                serverName: sni,
                alpn: alpn,
                fingerprint: fingerprint ?? "chrome",
                reality: RealitySettings(publicKey: publicKey, shortID: shortID)
            )
        default:
            throw ProxyLinkError.unsupportedSecurity(security)
        }
    }

    /// Имена оставшихся (неприменённых) параметров, отсортированные, без чисто информационных
    /// ключей и пустых значений. Значения не сохраняются: в них могут быть токены.
    private static func remainingParameters(_ query: [String: String]) -> [String] {
        query
            .filter { !informationalKeys.contains($0.key) && !$0.value.isEmpty }
            .map(\.key)
            .sorted()
    }

    // MARK: - Проверки

    /// Проверяет, что строка — корректный UUID.
    static func isValidUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// Проверяет публичный ключ REALITY: после декодирования Base64 должно быть ровно 32 байта.
    static func isValidRealityPublicKey(_ value: String) -> Bool {
        // Публичный ключ X25519: 32 байта, base64url без паддинга (43 символа).
        guard let data = Base64.decode(value) else { return false }
        return data.count == 32
    }

    /// Проверяет short ID REALITY: до 16 шестнадцатеричных символов, чётная длина (может быть пустым).
    static func isValidShortID(_ value: String) -> Bool {
        value.count <= 16 && value.count % 2 == 0 && value.allSatisfy(\.isHexDigit)
    }

    /// Стабильный ID сервера: первые 12 байт SHA-256 от ссылки в hex.
    ///
    /// Одна и та же ссылка всегда даёт один ID, поэтому выбор сервера переживает обновление подписки.
    static func stableID(for link: String) -> String {
        let digest = SHA256.hash(data: Data(link.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Схема ссылки (часть до `://`) в нижнем регистре; `nil`, если её нет.
    private static func scheme(of link: String) -> String? {
        guard let range = link.range(of: "://") else { return nil }
        let scheme = link[..<range.lowerBound].lowercased()
        return scheme.isEmpty ? nil : scheme
    }

    /// Убирает квадратные скобки вокруг IPv6-адреса.
    private static func stripBrackets(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }
}

/// `scheme://user[:password]@host:port?query#name`, разобранная нестрого.
private struct URLParts {
    /// Пользовательская часть как есть (с percent-encoding); нужна для Base64 в Shadowsocks.
    let rawUser: String?
    /// Пользовательская часть после декодирования (UUID или пароль).
    let user: String?
    /// Пароль после `:` в userinfo, если есть.
    let password: String?
    /// Хост без квадратных скобок IPv6.
    let host: String
    /// Порт в диапазоне 1...65535.
    let port: Int
    /// Параметры query; при повторах берётся первое значение.
    let query: [String: String]
    /// Имя сервера из фрагмента; `nil`, если фрагмент пуст.
    let name: String?

    /// Разбирает ссылку; бросает ошибку, если нет хоста или порт некорректен.
    init(_ link: String) throws {
        guard let components = URLComponents(string: link) else { throw ProxyLinkError.malformed }
        guard var host = components.percentEncodedHost, !host.isEmpty else { throw ProxyLinkError.missingHost }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        self.host = host.removingPercentEncoding ?? host
        guard let port = components.port, (1...65535).contains(port) else { throw ProxyLinkError.invalidPort }
        self.port = port
        rawUser = components.percentEncodedUser
        user = components.user
        password = components.password

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // Побеждает первое вхождение; значения уже декодированы URLComponents.
            if query[item.name] == nil {
                query[item.name] = item.value ?? ""
            }
        }
        self.query = query

        let fragment = components.fragment?.trimmingCharacters(in: .whitespaces)
        name = (fragment?.isEmpty ?? true) ? nil : fragment
    }
}

/// Нестрогое декодирование Base64 для подписок и ссылок: принимает стандартный и
/// URL-safe алфавиты, отсутствующий паддинг и пробелы внутри.
enum Base64 {
    /// Декодирует строку в байты; `nil`, если это не Base64.
    static func decode(_ string: String) -> Data? {
        var normalized = string
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty else { return nil }
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    /// Декодирует строку Base64 в текст UTF-8.
    static func decodeString(_ string: String) -> String? {
        decode(string).flatMap { String(data: $0, encoding: .utf8) }
    }
}
