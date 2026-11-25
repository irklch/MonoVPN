import CryptoKit
import Foundation

/// Errors for a single proxy link. Descriptions are user facing.
enum ProxyLinkError: LocalizedError, Equatable {
    case unsupportedScheme(String)
    case malformed
    case missingHost
    case invalidPort
    case invalidUUID
    case missingPassword
    case unsupportedEncryption(String)
    case unsupportedSecurity(String)
    case unsupportedTransport(String)
    case unsupportedHeaderType(String)
    case unsupportedFlow(String)
    case flowRequiresTLS
    case invalidRealityPublicKey
    case invalidRealityShortID
    case unsupportedShadowsocksMethod(String)
    case unsupportedShadowsocksPlugin(String)

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
        }
    }
}

/// Parses individual proxy links: `vless://`, `vmess://`, `trojan://`, `ss://`.
///
/// Only parameters sing-box can honour are applied. Parameters that change behaviour
/// but are not supported either fail the link (when ignoring them would connect
/// differently than the provider intends) or are reported in
/// `ServerConfiguration.ignoredParameters`.
enum ProxyLinkParser {
    static let supportedSchemes: Set<String> = ["vless", "vmess", "trojan", "ss"]

    /// uTLS fingerprints accepted by sing-box.
    static let supportedFingerprints: Set<String> = [
        "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized",
    ]

    /// Shadowsocks methods implemented by sing-box (AEAD and 2022).
    static let supportedShadowsocksMethods: Set<String> = [
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm",
        "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
    ]

    /// Query keys that only carry metadata and are safe to skip without a warning.
    private static let informationalKeys: Set<String> = ["remarks", "remark", "encryption"]

    static func isProxyLink(_ string: String) -> Bool {
        guard let scheme = scheme(of: string) else { return false }
        return supportedSchemes.contains(scheme)
    }

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

    /// Display name stored in the link fragment, if any. Used for error reporting.
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

    private static func parseVLESS(_ link: String) throws -> ServerConfiguration {
        let parts = try URLParts(link)
        guard let uuid = parts.user, isValidUUID(uuid) else { throw ProxyLinkError.invalidUUID }
        var query = parts.query

        if let encryption = query.removeValue(forKey: "encryption"), !encryption.isEmpty, encryption != "none" {
            throw ProxyLinkError.unsupportedEncryption(encryption)
        }

        var server = ServerConfiguration(
            id: stableID(for: link),
            name: parts.name ?? parts.host,
            proxyProtocol: .vless,
            host: parts.host,
            port: parts.port,
            uuid: uuid
        )
        server.transport = try transport(from: &query, ignored: &server.ignoredParameters)
        server.tls = try tls(from: &query, defaultSecurity: "none", ignored: &server.ignoredParameters)

        if let flow = query.removeValue(forKey: "flow"), !flow.isEmpty {
            guard flow == "xtls-rprx-vision" else { throw ProxyLinkError.unsupportedFlow(flow) }
            guard server.tls != nil, server.transport == .tcp else { throw ProxyLinkError.flowRequiresTLS }
            server.flow = flow
        }
        server.ignoredParameters += remainingParameters(query)
        return server
    }

    // MARK: - Trojan

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
        server.transport = try transport(from: &query, ignored: &server.ignoredParameters)
        // Trojan is TLS by definition unless explicitly disabled.
        server.tls = try tls(from: &query, defaultSecurity: "tls", ignored: &server.ignoredParameters)
        if let flow = query.removeValue(forKey: "flow"), !flow.isEmpty {
            throw ProxyLinkError.unsupportedFlow(flow)
        }
        server.ignoredParameters += remainingParameters(query)
        return server
    }

    // MARK: - VMess (v2rayN base64 JSON)

    private static func parseVMess(_ link: String) throws -> ServerConfiguration {
        guard let json = vmessJSON(link) else { throw ProxyLinkError.malformed }

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

        // Map the JSON onto the same query vocabulary as VLESS links.
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
            query["path"] = nil
            if let mode = string("type"), mode != "gun", mode != "none" {
                query["mode"] = mode
            }
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
        server.transport = try transport(from: &query, ignored: &server.ignoredParameters)
        server.tls = try tls(from: &query, defaultSecurity: "none", ignored: &server.ignoredParameters)
        server.ignoredParameters += remainingParameters(query)
        return server
    }

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

    // MARK: - Shadowsocks (SIP002 and legacy)

    private static func parseShadowsocks(_ link: String) throws -> ServerConfiguration {
        guard let range = link.range(of: "://") else { throw ProxyLinkError.malformed }
        var body = String(link[range.upperBound...])
        var name: String?
        if let hash = body.lastIndex(of: "#") {
            let fragment = String(body[body.index(after: hash)...])
            name = fragment.removingPercentEncoding ?? fragment
            body = String(body[..<hash])
        }

        // Legacy form: ss://base64(method:password@host:port)
        if !body.contains("@"), let decoded = Base64.decodeString(body.components(separatedBy: "?")[0]) {
            body = decoded
        }

        let normalized = "ss://" + body + (name.map { "#" + ($0.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") } ?? "")
        let parts = try URLParts(normalized)
        var query = parts.query

        // userinfo is either base64url(method:password) (SIP002) or plain method:password.
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
        guard supportedShadowsocksMethods.contains(method) else {
            throw ProxyLinkError.unsupportedShadowsocksMethod(method)
        }
        if let plugin = query.removeValue(forKey: "plugin"), !plugin.isEmpty {
            throw ProxyLinkError.unsupportedShadowsocksPlugin(plugin.components(separatedBy: ";")[0])
        }

        var server = ServerConfiguration(
            id: stableID(for: link),
            name: name.flatMap { $0.isEmpty ? nil : $0 } ?? parts.host,
            proxyProtocol: .shadowsocks,
            host: parts.host,
            port: parts.port,
            password: password,
            method: method
        )
        server.ignoredParameters += remainingParameters(query)
        return server
    }

    // MARK: - Shared V2Ray-style parameters

    private static func transport(from query: inout [String: String], ignored: inout [String]) throws -> TransportSettings {
        let type = (query.removeValue(forKey: "type") ?? "tcp").lowercased()
        let host = query.removeValue(forKey: "host").flatMap { $0.isEmpty ? nil : $0 }
        let path = query.removeValue(forKey: "path").map { $0.isEmpty ? "/" : $0 }
        let headerType = query.removeValue(forKey: "headerType")?.lowercased()

        switch type {
        case "tcp", "raw", "":
            if let headerType, headerType != "none" {
                throw ProxyLinkError.unsupportedHeaderType(headerType)
            }
            return .tcp
        case "ws", "websocket":
            var resolvedPath = path ?? "/"
            var earlyData: Int?
            // Xray style early data: path "/ws?ed=2048".
            if let questionMark = resolvedPath.firstIndex(of: "?"),
               let components = URLComponents(string: "http://x/?" + String(resolvedPath[resolvedPath.index(after: questionMark)...])),
               let ed = components.queryItems?.first(where: { $0.name == "ed" })?.value.flatMap(Int.init) {
                earlyData = ed
                resolvedPath = String(resolvedPath[..<questionMark])
            }
            return .webSocket(path: resolvedPath, host: host, maxEarlyData: earlyData)
        case "grpc", "gun":
            let serviceName = query.removeValue(forKey: "serviceName") ?? path.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
            if let mode = query.removeValue(forKey: "mode"), mode != "gun" {
                ignored.append("mode=\(mode)")
            }
            query.removeValue(forKey: "authority").map { ignored.append("authority=\($0)") }
            return .grpc(serviceName: serviceName)
        case "http", "h2":
            let hosts = host.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []
            return .http(path: path ?? "/", hosts: hosts)
        case "httpupgrade":
            return .httpUpgrade(path: path ?? "/", host: host)
        default:
            throw ProxyLinkError.unsupportedTransport(type)
        }
    }

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

        // Certificate verification is never disabled: report the parameter instead.
        for key in ["allowInsecure", "insecure", "allowinsecure"] {
            if let value = query.removeValue(forKey: key), value == "1" || value.lowercased() == "true" {
                ignored.append("\(key)=\(value)")
            }
        }

        if let fp = fingerprint, !supportedFingerprints.contains(fp) {
            ignored.append("fp=\(fp)")
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
                ignored.append("spx=\(spiderX)")
            }
            // REALITY in sing-box requires uTLS; chrome matches Xray's default.
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

    private static func remainingParameters(_ query: [String: String]) -> [String] {
        query
            .filter { !informationalKeys.contains($0.key) && !$0.value.isEmpty }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    }

    // MARK: - Validation helpers

    static func isValidUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    static func isValidRealityPublicKey(_ value: String) -> Bool {
        // X25519 public key, 32 bytes, base64url without padding (43 chars).
        guard let data = Base64.decode(value) else { return false }
        return data.count == 32
    }

    static func isValidShortID(_ value: String) -> Bool {
        value.count <= 16 && value.count % 2 == 0 && value.allSatisfy(\.isHexDigit)
    }

    static func stableID(for link: String) -> String {
        let digest = SHA256.hash(data: Data(link.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func scheme(of link: String) -> String? {
        guard let range = link.range(of: "://") else { return nil }
        let scheme = link[..<range.lowerBound].lowercased()
        return scheme.isEmpty ? nil : scheme
    }

    private static func stripBrackets(_ host: String) -> String {
        host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    }
}

/// `scheme://user[:password]@host:port?query#name`, parsed leniently.
private struct URLParts {
    let rawUser: String?
    let user: String?
    let password: String?
    let host: String
    let port: Int
    let query: [String: String]
    let name: String?

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
            // First occurrence wins; values are already percent-decoded by URLComponents.
            if query[item.name] == nil {
                query[item.name] = item.value ?? ""
            }
        }
        self.query = query

        let fragment = components.fragment?.trimmingCharacters(in: .whitespaces)
        name = (fragment?.isEmpty ?? true) ? nil : fragment
    }
}

/// Lenient Base64 decoding used by subscriptions and links: accepts standard and
/// URL-safe alphabets, missing padding and embedded whitespace.
enum Base64 {
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

    static func decodeString(_ string: String) -> String? {
        decode(string).flatMap { String(data: $0, encoding: .utf8) }
    }
}
