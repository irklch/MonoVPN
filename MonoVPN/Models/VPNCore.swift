import Foundation

/// VPN-ядро, с которым собрано приложение, и его возможности.
///
/// Ядро выбирается при сборке флагом `MONO_CORE_XRAY` (`Config/Identifiers.xcconfig`):
/// в один процесс Packet Tunnel можно слинковать только одну Go-библиотеку, поэтому
/// переключения во время работы нет. От ядра зависят формат конфигурации туннеля и то,
/// какие серверы подписки помечаются «Не поддерживается».
enum VPNCore: String, Codable, Sendable {
    /// sing-box (Libbox).
    case singBox = "sing-box"
    /// Xray-core (LibXray).
    case xray = "xray"

    /// Ядро текущей сборки.
    static var current: VPNCore {
        #if MONO_CORE_XRAY
        return .xray
        #else
        return .singBox
        #endif
    }

    /// Есть ли транспорт XHTTP (SplitHTTP).
    var supportsXHTTP: Bool { self == .xray }

    /// Можно ли задать gRPC `:authority` независимо от SNI.
    var supportsIndependentGRPCAuthority: Bool { self == .xray }

    /// Есть ли транспорт HTTP/2 (`type=http`/`h2`); в Xray-core он удалён.
    var supportsHTTP2Transport: Bool { self == .singBox }

    /// Есть ли SIP003-плагины Shadowsocks (`obfs-local`, `v2ray-plugin`); в Xray-core их нет.
    var supportsShadowsocksPlugins: Bool { self == .singBox }

    /// Шифры Shadowsocks, которые реализует ядро (`infra/conf/shadowsocks.go` для Xray).
    var shadowsocksMethods: Set<String> {
        var methods: Set<String> = [
            "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
            "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        ]
        if self == .singBox {
            methods.insert("aes-192-gcm")
        }
        return methods
    }

    /// Vision (`xtls-rprx-vision`) на транспорте, отличном от TCP, отбрасывается, а не делает
    /// сервер неподдерживаемым. Xray-core выполняет Vision только поверх прямого TLS/REALITY
    /// (`proxy/vless/outbound`: «XTLS only supports TLS and REALITY directly»), и эталонные
    /// клиенты Xray не передают `flow` для gRPC/XHTTP/WS.
    var dropsFlowOnNonTCPTransport: Bool { self == .xray }
}
